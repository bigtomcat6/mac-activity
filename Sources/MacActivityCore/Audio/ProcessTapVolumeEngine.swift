import CoreAudio
import Darwin
import Dispatch
import Foundation

public enum ProcessTapSessionState: Equatable, Sendable {
    case idle
    case preparing
    case running
    case rebuilding
    case stopping
    case failed
}

public enum ProcessTapEngineError: Error, Equatable, Sendable {
    case processTapsUnavailable
    case permissionDenied(OSStatus)
    case unsupportedFormat
    case routeSuperseded
    case aggregateNotReady
    case cleanupBacklogFull
    case operationFailed(operation: AudioHALOperation, status: OSStatus)
}

public struct ProcessTapSessionSnapshot: Equatable, Sendable {
    public let processObjectID: AudioObjectID
    public let generation: UInt64
    public let state: ProcessTapSessionState
    public let error: ProcessTapEngineError?

    public init(
        processObjectID: AudioObjectID,
        generation: UInt64,
        state: ProcessTapSessionState,
        error: ProcessTapEngineError?
    ) {
        self.processObjectID = processObjectID
        self.generation = generation
        self.state = state
        self.error = error
    }
}

public struct AudioTeardownFailure: Equatable, Sendable {
    public let processObjectID: AudioObjectID?
    public let operation: AudioHALOperation
    public let objectID: AudioObjectID
    public let status: OSStatus

    public init(
        processObjectID: AudioObjectID?,
        operation: AudioHALOperation,
        objectID: AudioObjectID,
        status: OSStatus
    ) {
        self.processObjectID = processObjectID
        self.operation = operation
        self.objectID = objectID
        self.status = status
    }
}

public protocol ProcessTapVolumeControlling: AnyObject, Sendable {
    func apply(
        plan: AudioRoutePlan,
        gain: ProcessGainState
    ) async -> ProcessTapSessionSnapshot

    func updateGain(
        _ gain: ProcessGainState,
        for processObjectID: AudioObjectID
    ) async

    func stop(
        processObjectID: AudioObjectID,
        generation: UInt64
    ) async -> ProcessTapSessionSnapshot

    func stopAll() async
    func cleanupOrphans() async -> [AudioTeardownFailure]
}

public final class ProcessTapVolumeEngine: ProcessTapVolumeControlling, @unchecked Sendable {
    private static let preparationTimeout: DispatchTimeInterval = .seconds(2)
    private static let callbackObservationInterval: DispatchTimeInterval = .milliseconds(10)

    private let hardware: (any AudioTapHardware)?
    private let availability: AudioFeatureAvailability
    private let queue: DispatchQueue
    private let retryLedgerLimit: Int
    private let onSessionSnapshot: @Sendable (ProcessTapSessionSnapshot) -> Void
    private let generations = ProcessTapGenerationRegistry()

    // Queue confined.
    private var sessions: [AudioObjectID: ProcessTapSession] = [:]
    private var bundles: [UUID: AudioAcquisitionBundle] = [:]
    private var successfullyDestroyedOwnedIdentities: Set<AudioOwnedObjectInstanceIdentity> = []
    private var lifetimeLease: ProcessTapVolumeEngine?

    public convenience init(availability: AudioFeatureAvailability = .current) {
        self.init(
            hardware: CoreAudioTapHardware(hal: .system),
            availability: availability
        )
    }

    convenience init(
        hardware: any AudioTapHardware,
        availability: AudioFeatureAvailability = .current,
        queue: DispatchQueue = DispatchQueue(
            label: "com.how.macactivity.audio.process-tap",
            qos: .userInitiated
        ),
        retryLedgerLimit: Int = 32,
        onSessionSnapshot: @escaping @Sendable (ProcessTapSessionSnapshot) -> Void = { _ in }
    ) {
        self.init(
            optionalHardware: hardware,
            availability: availability,
            queue: queue,
            retryLedgerLimit: retryLedgerLimit,
            onSessionSnapshot: onSessionSnapshot
        )
    }

    private init(
        optionalHardware: (any AudioTapHardware)?,
        availability: AudioFeatureAvailability,
        queue: DispatchQueue,
        retryLedgerLimit: Int,
        onSessionSnapshot: @escaping @Sendable (ProcessTapSessionSnapshot) -> Void
    ) {
        hardware = optionalHardware
        self.availability = availability
        self.queue = queue
        self.retryLedgerLimit = max(1, retryLedgerLimit)
        self.onSessionSnapshot = onSessionSnapshot
    }

    public func apply(
        plan: AudioRoutePlan,
        gain: ProcessGainState
    ) async -> ProcessTapSessionSnapshot {
        let token = generations.register(
            processObjectID: plan.processObjectID,
            generation: plan.generation
        )
        return await withTaskCancellationHandler {
            await enqueue { [self] in
                applyOnQueue(plan: plan, gain: gain, token: token)
            }
        } onCancel: { [generations] in
            generations.cancel(token)
        }
    }

    public func updateGain(
        _ gain: ProcessGainState,
        for processObjectID: AudioObjectID
    ) async {
        await enqueue { [self] in
            guard availability.supportsProcessControls,
                  #available(macOS 14.2, *),
                  let hardware
            else {
                return
            }
            advanceRetainedBundles(using: hardware)
            guard let session = sessions[processObjectID],
                  let context = bundles[session.acquisitionID]?.resources.context
            else { return }
            context.setTargetGain(gain.targetGain)
        }
    }

    public func stop(
        processObjectID: AudioObjectID,
        generation: UInt64
    ) async -> ProcessTapSessionSnapshot {
        let token = generations.register(
            processObjectID: processObjectID,
            generation: generation
        )
        return await enqueue { [self] in
            stopOnQueue(
                processObjectID: processObjectID,
                generation: generation,
                token: token
            )
        }
    }

    public func stopAll() async {
        generations.cancelAll()
        await enqueue { [self] in
            guard availability.supportsProcessControls,
                  #available(macOS 14.2, *),
                  let hardware
            else {
                sessions.removeAll()
                bundles.removeAll()
                successfullyDestroyedOwnedIdentities.removeAll()
                lifetimeLease = nil
                return
            }
            advanceRetainedBundles(using: hardware)
            let activeSessions = sessions.values.sorted {
                $0.processObjectID < $1.processObjectID
            }
            sessions.removeAll()
            for session in activeSessions {
                _ = teardown(session.acquisitionID, using: hardware)
            }
        }
    }

    public func cleanupOrphans() async -> [AudioTeardownFailure] {
        await enqueue { [self] in
            guard availability.supportsProcessControls,
                  #available(macOS 14.2, *),
                  let hardware
            else {
                return []
            }
            advanceRetainedBundles(using: hardware)
            let discoveryFailures = cleanupOwnedObjects(using: hardware)
            return discoveryFailures + bundleFailures()
        }
    }

    public enum Error: Swift.Error, Equatable {
        case processTapsUnavailable
    }

    @available(*, deprecated, message: "Use the async route-plan API")
    @MainActor public func start(entry: AudioProcessEntry) throws {
        throw Error.processTapsUnavailable
    }

    @available(*, deprecated, message: "Use stop(processObjectID:generation:)")
    @MainActor public func stop(processIdentifier: pid_t) {}

    @available(*, deprecated, message: "Use updateGain(_:for:)")
    @MainActor public func setVolume(_ volume: Double, processIdentifier: pid_t) {}

    @available(*, deprecated, message: "Use updateGain(_:for:)")
    @MainActor public func setMuted(_ isMuted: Bool, processIdentifier: pid_t) {}

    static func callbackProgressIsReady(
        now: DispatchTime,
        deadline: DispatchTime,
        countBeforeObservation: Int32,
        currentCount: Int32
    ) -> Bool {
        now < deadline && currentCount != countBeforeObservation
    }
}

private extension ProcessTapVolumeEngine {
    func applyOnQueue(
        plan: AudioRoutePlan,
        gain: ProcessGainState,
        token: ProcessTapGenerationRegistry.Token
    ) -> ProcessTapSessionSnapshot {
        guard generations.isCurrent(token) else {
            return snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .failed,
                error: .routeSuperseded
            )
        }
        guard availability.supportsProcessControls,
              #available(macOS 14.2, *),
              let hardware
        else {
            return publishFailure(
                .processTapsUnavailable,
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                token: token
            )
        }

        advanceRetainedBundles(using: hardware)
        guard generations.isCurrent(token) else {
            return snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .failed,
                error: .routeSuperseded
            )
        }

        if let current = sessions[plan.processObjectID],
           current.generation == plan.generation {
            bundles[current.acquisitionID]?.resources.context?.setTargetGain(
                gain.targetGain
            )
            let running = snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .running,
                error: nil
            )
            _ = publish(running, token: token)
            return running
        }

        if let current = sessions.removeValue(forKey: plan.processObjectID) {
            let rebuilding = snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .rebuilding,
                error: nil
            )
            _ = publish(rebuilding, token: token)
            _ = teardown(current.acquisitionID, using: hardware)
            guard generations.isCurrent(token) else {
                return snapshot(
                    processObjectID: plan.processObjectID,
                    generation: plan.generation,
                    state: .failed,
                    error: .routeSuperseded
                )
            }
            if bundles[current.acquisitionID] != nil {
                return publishFailure(
                    .cleanupBacklogFull,
                    processObjectID: plan.processObjectID,
                    generation: plan.generation,
                    token: token
                )
            }
        }

        guard bundles.values.contains(where: {
            $0.resources.processObjectID == plan.processObjectID
                && $0.state != .released
        }) == false else {
            return publishFailure(
                .cleanupBacklogFull,
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                token: token
            )
        }

        guard nonReleasedBundleCount < retryLedgerLimit else {
            return publishFailure(
                .cleanupBacklogFull,
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                token: token
            )
        }

        let preparing = snapshot(
            processObjectID: plan.processObjectID,
            generation: plan.generation,
            state: .preparing,
            error: nil
        )
        _ = publish(preparing, token: token)
        return prepare(
            plan: plan,
            gain: gain,
            token: token,
            hardware: hardware
        )
    }

    func prepare(
        plan: AudioRoutePlan,
        gain: ProcessGainState,
        token: ProcessTapGenerationRegistry.Token,
        hardware: any AudioTapHardware
    ) -> ProcessTapSessionSnapshot {
        let acquisitionID = UUID()
        bundles[acquisitionID] = AudioAcquisitionBundle(
            acquisitionID: acquisitionID,
            resources: ProcessTapSessionResources(
                processObjectID: plan.processObjectID,
                generation: plan.generation
            ),
            state: .preparing,
            stage: .restoreOriginalAudio,
            didStartIOProc: false,
            failures: []
        )
        checkCapacityInvariant()

        do {
            guard plan.tapSources.isEmpty == false else {
                throw ProcessTapPreparationAbort(.unsupportedFormat)
            }

            for source in plan.tapSources {
                let tap = try hardware.createTap(
                    processObjectID: plan.processObjectID,
                    source: source,
                    uuid: UUID()
                )
                bundles[acquisitionID]?.resources.taps.append(tap)
                try ensureCurrent(token)
            }

            let taps = bundles[acquisitionID]?.resources.taps ?? []
            for (index, tap) in taps.enumerated() {
                let format = try hardware.readTapFormat(tap)
                try ensureCurrent(token)
                guard index < plan.tapSources.count,
                      format == plan.tapSources[index].expectedFormat,
                      Self.isSupportedTapFormat(format)
                else {
                    throw ProcessTapPreparationAbort(.unsupportedFormat)
                }
            }

            let aggregate = try hardware.createAggregate(
                plan: plan,
                taps: taps
            )
            bundles[acquisitionID]?.resources.aggregate = aggregate
            try ensureCurrent(token)

            let topology = try hardware.waitForStableTopology(
                aggregate,
                deadline: .now() + Self.preparationTimeout,
                isCancelled: { [generations] in
                    generations.isCurrent(token) == false
                }
            )
            try ensureCurrent(token)

            let layout = try AudioAggregateTopologyResolver.resolve(
                plan: plan,
                tap: taps[0],
                snapshot: topology
            )
            try ensureCurrent(token)
            guard let sampleRate = layout.inputFormats.first?.sampleRate else {
                throw ProcessTapPreparationAbort(.unsupportedFormat)
            }

            let configuration: ProcessTapDSPConfiguration
            do {
                configuration = try ProcessTapDSPConfiguration.validated(
                    sampleRate: sampleRate,
                    inputFormats: layout.inputFormats,
                    outputFormats: layout.outputFormats,
                    channelMaps: layout.channelMaps
                )
            } catch {
                throw ProcessTapPreparationAbort(.unsupportedFormat)
            }

            let context = ProcessTapDSPContext(
                configuration: configuration,
                initialGain: gain.targetGain
            )
            bundles[acquisitionID]?.resources.context = context
            let ioProc = try hardware.createIOProc(
                aggregate: aggregate,
                context: context
            )
            bundles[acquisitionID]?.resources.ioProc = ioProc
            try ensureCurrent(token)

            let verifiedUsage = try hardware.configureInputStreamUsage(
                layout.inputStreamUsage,
                for: ioProc
            )
            guard verifiedUsage == layout.inputStreamUsage else {
                throw ProcessTapPreparationAbort(.unsupportedFormat)
            }
            try ensureCurrent(token)

            let callbackCountBeforeStart = context.callbackCount
            try hardware.start(ioProc)
            bundles[acquisitionID]?.didStartIOProc = true
            try ensureCurrent(token)
            try waitForSustainedCallbacks(
                context,
                startingAt: callbackCountBeforeStart,
                token: token
            )

            for tap in taps {
                try hardware.setMuteState(.mutedWhenTapped, for: tap)
                bundles[acquisitionID]?.resources.mutedTaps.append(tap)
                try ensureCurrent(token)
            }

            context.setOutputGateOpen(true)
            try ensureCurrent(token)

            let session = ProcessTapSession(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                acquisitionID: acquisitionID
            )
            let running = snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .running,
                error: nil
            )
            let installed = generations.performIfCurrent(token) { [self] in
                transitionBundle(acquisitionID, to: .active)
                sessions[plan.processObjectID] = session
                lifetimeLease = self
            }
            guard installed else {
                throw ProcessTapPreparationAbort(.routeSuperseded)
            }
            onSessionSnapshot(running)
            return running
        } catch {
            bundles[acquisitionID]?.resources.context?.setOutputGateOpen(false)
            _ = teardown(acquisitionID, using: hardware)
            let preparationError = generations.isCurrent(token)
                ? map(error)
                : .routeSuperseded
            return publishFailure(
                preparationError,
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                token: token
            )
        }
    }

    func stopOnQueue(
        processObjectID: AudioObjectID,
        generation: UInt64,
        token: ProcessTapGenerationRegistry.Token
    ) -> ProcessTapSessionSnapshot {
        guard generations.isCurrent(token) else {
            return snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: .routeSuperseded
            )
        }
        guard availability.supportsProcessControls,
              #available(macOS 14.2, *),
              let hardware
        else {
            return publishFailure(
                .processTapsUnavailable,
                processObjectID: processObjectID,
                generation: generation,
                token: token
            )
        }

        advanceRetainedBundles(using: hardware)
        guard generations.isCurrent(token) else {
            return snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: .routeSuperseded
            )
        }
        guard let session = sessions[processObjectID] else {
            let idle = snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .idle,
                error: nil
            )
            _ = publish(idle, token: token)
            return idle
        }
        guard session.generation <= generation else {
            return snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: .routeSuperseded
            )
        }

        let stopping = snapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: .stopping,
            error: nil
        )
        _ = publish(stopping, token: token)
        sessions.removeValue(forKey: processObjectID)
        let failures = teardown(session.acquisitionID, using: hardware)
        guard generations.isCurrent(token) else {
            return snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: .routeSuperseded
            )
        }

        let result: ProcessTapSessionSnapshot
        if let failure = failures.first {
            result = snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: map(operation: failure.operation, status: failure.status)
            )
        } else {
            result = snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .idle,
                error: nil
            )
        }
        _ = publish(result, token: token)
        return result
    }

    func waitForSustainedCallbacks(
        _ context: ProcessTapDSPContext,
        startingAt initialCount: Int32,
        token: ProcessTapGenerationRegistry.Token
    ) throws {
        let deadline = DispatchTime.now() + Self.preparationTimeout
        var countBeforeObservation: Int32?
        var observationDeadline: DispatchTime?
        while true {
            try ensureCurrent(token)
            let now = DispatchTime.now()
            let currentCount = context.callbackCount
            guard now < deadline else {
                throw ProcessTapPreparationAbort(.aggregateNotReady)
            }
            if let baseline = countBeforeObservation,
               let intervalEnd = observationDeadline,
               now >= intervalEnd {
                if Self.callbackProgressIsReady(
                    now: now,
                    deadline: deadline,
                    countBeforeObservation: baseline,
                    currentCount: currentCount
                ) { return }
                countBeforeObservation = currentCount
                observationDeadline = now + Self.callbackObservationInterval
            } else if countBeforeObservation == nil, currentCount != initialCount {
                countBeforeObservation = currentCount
                observationDeadline = now + Self.callbackObservationInterval
            }
            usleep(1_000)
        }
    }

    func teardown(
        _ acquisitionID: UUID,
        using hardware: any AudioTapHardware
    ) -> [AudioTeardownFailure] {
        guard bundles[acquisitionID] != nil else { return [] }
        bundles[acquisitionID]?.resources.context?.setOutputGateOpen(false)
        restoreMutedTaps(in: acquisitionID, using: hardware)

        while let stage = bundles[acquisitionID]?.stage {
            switch stage {
            case .restoreOriginalAudio:
                bundles[acquisitionID]?.stage = .stopIOProc
            case .stopIOProc:
                if let bundle = bundles[acquisitionID],
                   bundle.didStartIOProc,
                   let ioProc = bundle.resources.ioProc {
                    let status = hardware.stop(ioProc)
                    recordBundleStatus(
                        status == kAudioHardwareBadObjectError ? noErr : status,
                        operation: .stopDevice,
                        objectID: ioProc.aggregateDeviceID,
                        acquisitionID: acquisitionID
                    )
                }
                bundles[acquisitionID]?.stage = .destroyIOProc
            case .destroyIOProc:
                if let ioProc = bundles[acquisitionID]?.resources.ioProc {
                    let rawStatus = hardware.destroyIOProc(ioProc)
                    let status = rawStatus == kAudioHardwareBadObjectError
                        ? noErr
                        : rawStatus
                    recordBundleStatus(
                        status,
                        operation: .destroyIOProc,
                        objectID: ioProc.aggregateDeviceID,
                        acquisitionID: acquisitionID
                    )
                    guard status == noErr else {
                        retainBundle(acquisitionID)
                        return bundles[acquisitionID]?.failures ?? []
                    }
                    removeBundleFailures(
                        acquisitionID,
                        operations: [.stopDevice, .destroyIOProc],
                        objectID: ioProc.aggregateDeviceID
                    )
                }
                bundles[acquisitionID]?.stage = .destroyAggregate
            case .destroyAggregate:
                if let aggregate = bundles[acquisitionID]?.resources.aggregate {
                    let status = hardware.destroyAggregate(aggregate)
                    recordBundleStatus(
                        status,
                        operation: .destroyAggregate,
                        objectID: aggregate.objectID,
                        acquisitionID: acquisitionID
                    )
                    guard status == noErr else {
                        retainBundle(acquisitionID)
                        return bundles[acquisitionID]?.failures ?? []
                    }
                    successfullyDestroyedOwnedIdentities.insert(
                        AudioOwnedObjectInstanceIdentity(
                            objectID: aggregate.objectID,
                            classID: kAudioAggregateDeviceClassID,
                            uid: aggregate.uid
                        )
                    )
                }
                bundles[acquisitionID]?.stage = .waitForAggregateDisappearance
            case .waitForAggregateDisappearance:
                if let aggregate = bundles[acquisitionID]?.resources.aggregate {
                    let discovery: AudioOwnedObjectDiscovery
                    do {
                        discovery = try hardware.ownedObjects()
                    } catch {
                        let failure = teardownFailure(
                            from: error,
                            fallbackOperation: .getData,
                            objectID: aggregate.objectID,
                            processObjectID: bundles[acquisitionID]?.resources.processObjectID
                        )
                        setBundleFailure(failure, acquisitionID: acquisitionID)
                        retainBundle(acquisitionID)
                        return bundles[acquisitionID]?.failures ?? []
                    }
                    if let identityFailure = discovery.failures.first(where: {
                        $0.objectID == aggregate.objectID
                    }) {
                        setBundleFailure(
                            AudioTeardownFailure(
                                processObjectID: bundles[acquisitionID]?.resources.processObjectID,
                                operation: identityFailure.operation,
                                objectID: identityFailure.objectID,
                                status: identityFailure.status
                            ),
                            acquisitionID: acquisitionID
                        )
                        retainBundle(acquisitionID)
                        return bundles[acquisitionID]?.failures ?? []
                    }
                    removeBundleFailures(
                        acquisitionID,
                        operations: [.getData],
                        objectID: aggregate.objectID
                    )
                    let stillExists = discovery.objects.contains {
                        $0.id == aggregate.objectID
                            && $0.classID == kAudioAggregateDeviceClassID
                            && $0.uid == aggregate.uid
                    }
                    guard stillExists == false else {
                        retainBundle(acquisitionID)
                        return bundles[acquisitionID]?.failures ?? []
                    }
                    bundles[acquisitionID]?.resources.aggregate = nil
                }
                bundles[acquisitionID]?.stage = .destroyTaps
            case .destroyTaps:
                let taps = bundles[acquisitionID]?.resources.taps ?? []
                for tap in taps.reversed() {
                    let status = hardware.destroyTap(tap)
                    recordBundleStatus(
                        status,
                        operation: .destroyTap,
                        objectID: tap.objectID,
                        acquisitionID: acquisitionID
                    )
                    guard status == noErr else { continue }
                    successfullyDestroyedOwnedIdentities.insert(
                        AudioOwnedObjectInstanceIdentity(
                            objectID: tap.objectID,
                            classID: kAudioTapClassID,
                            uid: tap.uuid.uuidString
                        )
                    )
                    bundles[acquisitionID]?.resources.taps.removeAll {
                        $0.objectID == tap.objectID && $0.uuid == tap.uuid
                    }
                    bundles[acquisitionID]?.resources.mutedTaps.removeAll {
                        $0.objectID == tap.objectID && $0.uuid == tap.uuid
                    }
                    removeBundleFailures(
                        acquisitionID,
                        operations: [.setData, .destroyTap],
                        objectID: tap.objectID
                    )
                }
                guard bundles[acquisitionID]?.resources.taps.isEmpty == true else {
                    retainBundle(acquisitionID)
                    return bundles[acquisitionID]?.failures ?? []
                }
                bundles[acquisitionID]?.stage = .released
            case .released:
                transitionBundle(acquisitionID, to: .released)
                bundles.removeValue(forKey: acquisitionID)
                refreshLifetimeLease()
                return []
            }
        }
        return []
    }

    func restoreMutedTaps(
        in acquisitionID: UUID,
        using hardware: any AudioTapHardware
    ) {
        let taps = bundles[acquisitionID]?.resources.mutedTaps ?? []
        for tap in taps.reversed() {
            let status = hardware.restoreOriginalAudio(for: tap)
            recordBundleStatus(
                status,
                operation: .setData,
                objectID: tap.objectID,
                acquisitionID: acquisitionID
            )
            guard status == noErr else { continue }
            bundles[acquisitionID]?.resources.mutedTaps.removeAll {
                $0.objectID == tap.objectID && $0.uuid == tap.uuid
            }
        }
    }

    func recordBundleStatus(
        _ status: OSStatus,
        operation: AudioHALOperation,
        objectID: AudioObjectID,
        acquisitionID: UUID
    ) {
        guard status != noErr else {
            removeBundleFailures(
                acquisitionID,
                operations: [operation],
                objectID: objectID
            )
            return
        }
        setBundleFailure(
            AudioTeardownFailure(
                processObjectID: bundles[acquisitionID]?.resources.processObjectID,
                operation: operation,
                objectID: objectID,
                status: status
            ),
            acquisitionID: acquisitionID
        )
    }

    func setBundleFailure(
        _ failure: AudioTeardownFailure,
        acquisitionID: UUID
    ) {
        bundles[acquisitionID]?.failures.removeAll {
            $0.operation == failure.operation && $0.objectID == failure.objectID
        }
        bundles[acquisitionID]?.failures.append(failure)
    }

    func removeBundleFailures(
        _ acquisitionID: UUID,
        operations: Set<AudioHALOperation>,
        objectID: AudioObjectID
    ) {
        bundles[acquisitionID]?.failures.removeAll {
            operations.contains($0.operation) && $0.objectID == objectID
        }
    }

    func retainBundle(_ acquisitionID: UUID) {
        guard let state = bundles[acquisitionID]?.state,
              state != .retainedBundle
        else { return }
        transitionBundle(acquisitionID, to: .retainedBundle)
        refreshLifetimeLease()
    }

    func advanceRetainedBundles(using hardware: any AudioTapHardware) {
        let acquisitionIDs = bundles.values
            .filter { $0.state == .retainedBundle }
            .map(\.acquisitionID)
            .sorted { $0.uuidString < $1.uuidString }
        for acquisitionID in acquisitionIDs {
            _ = teardown(acquisitionID, using: hardware)
        }
    }

    @available(macOS 14.2, *)
    func cleanupOwnedObjects(
        using hardware: any AudioTapHardware
    ) -> [AudioTeardownFailure] {
        let discovery: AudioOwnedObjectDiscovery
        do {
            discovery = try hardware.ownedObjects()
        } catch {
            return [teardownFailure(
                from: error,
                fallbackOperation: .getData,
                objectID: AudioObjectID(kAudioObjectSystemObject),
                processObjectID: nil
            )]
        }

        let ownedObjects = CoreAudioTapHardware.ownedOrphans(in: discovery.objects)
        let enumeratedIdentities = Set(ownedObjects.map(Self.ownedInstanceIdentity))
        successfullyDestroyedOwnedIdentities.formIntersection(enumeratedIdentities)

        let activeObjectIDs = activeOwnedObjectIDs()
        let candidates = ownedObjects
            .filter { activeObjectIDs.contains($0.id) == false }
            .filter {
                return successfullyDestroyedOwnedIdentities.contains(
                    Self.ownedInstanceIdentity($0)
                ) == false
                    && bundleRepresents($0) == false
            }
            .sorted(by: Self.ownedObjectComesBefore)

        var failures = discovery.failures
        for object in candidates {
            let operation = Self.destroyOperation(for: object)
            let status = hardware.destroyOwnedObject(object)
            if status == noErr {
                successfullyDestroyedOwnedIdentities.insert(
                    Self.ownedInstanceIdentity(object)
                )
                continue
            }

            failures.append(AudioTeardownFailure(
                processObjectID: nil,
                operation: operation,
                objectID: object.id,
                status: status
            ))
        }
        return failures
    }

    @available(macOS 14.2, *)
    func bundleRepresents(_ object: AudioOwnedObject) -> Bool {
        bundles.values.contains { bundle in
            if let aggregate = bundle.resources.aggregate,
               object.classID == kAudioAggregateDeviceClassID,
               object.id == aggregate.objectID,
               object.uid == aggregate.uid {
                return true
            }
            return bundle.resources.taps.contains { tap in
                object.classID == kAudioTapClassID
                    && object.id == tap.objectID
                    && object.uid == tap.uuid.uuidString
            }
        }
    }

    func bundleFailures() -> [AudioTeardownFailure] {
        bundles.values
            .sorted { $0.acquisitionID.uuidString < $1.acquisitionID.uuidString }
            .flatMap { bundle in
                bundle.failures.sorted {
                    if $0.operation.rawValue == $1.operation.rawValue {
                        return $0.objectID < $1.objectID
                    }
                    return $0.operation.rawValue < $1.operation.rawValue
                }
            }
    }

    func refreshLifetimeLease() {
        if bundles.isEmpty {
            lifetimeLease = nil
        } else {
            lifetimeLease = self
        }
    }

    func activeOwnedObjectIDs() -> Set<AudioObjectID> {
        Set(bundles.values.flatMap { bundle in
            bundle.resources.taps.map(\.objectID)
                + [bundle.resources.aggregate?.objectID].compactMap { $0 }
        })
    }

    var nonReleasedBundleCount: Int {
        bundles.values.filter { $0.state != .released }.count
    }

    func transitionBundle(
        _ acquisitionID: UUID,
        to newState: AudioAcquisitionBundle.State
    ) {
        guard let oldState = bundles[acquisitionID]?.state else { return }
        let isLegal = switch (oldState, newState) {
        case (.preparing, .active),
             (.preparing, .retainedBundle),
             (.preparing, .released),
             (.active, .retainedBundle),
             (.active, .released),
             (.retainedBundle, .released):
            true
        default:
            oldState == newState
        }
        precondition(isLegal, "Illegal audio acquisition state transition")
        bundles[acquisitionID]?.state = newState
        checkCapacityInvariant()
    }

    func checkCapacityInvariant() {
        precondition(
            nonReleasedBundleCount <= retryLedgerLimit,
            "Audio acquisition capacity exceeded"
        )
    }

    func ensureCurrent(
        _ token: ProcessTapGenerationRegistry.Token
    ) throws {
        guard generations.isCurrent(token) else {
            throw ProcessTapPreparationAbort(.routeSuperseded)
        }
    }

    func publishFailure(
        _ error: ProcessTapEngineError,
        processObjectID: AudioObjectID,
        generation: UInt64,
        token: ProcessTapGenerationRegistry.Token
    ) -> ProcessTapSessionSnapshot {
        let failed = snapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: .failed,
            error: error
        )
        _ = publish(failed, token: token)
        return failed
    }

    func publish(
        _ snapshot: ProcessTapSessionSnapshot,
        token: ProcessTapGenerationRegistry.Token
    ) -> Bool {
        guard generations.isCurrent(token) else { return false }
        onSessionSnapshot(snapshot)
        return true
    }

    func snapshot(
        processObjectID: AudioObjectID,
        generation: UInt64,
        state: ProcessTapSessionState,
        error: ProcessTapEngineError?
    ) -> ProcessTapSessionSnapshot {
        ProcessTapSessionSnapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: state,
            error: error
        )
    }

    func map(_ error: Swift.Error) -> ProcessTapEngineError {
        if let abort = error as? ProcessTapPreparationAbort {
            return abort.error
        }
        if let hardwareError = error as? AudioTapHardwareError {
            switch hardwareError {
            case .aggregateNotReady:
                return .aggregateNotReady
            case .cancelled:
                return .routeSuperseded
            }
        }
        if error is CoreAudioTapHardware.ValidationError
            || error is AudioAggregateTopologyError {
            return .unsupportedFormat
        }
        if let halError = error as? AudioHALError {
            if halError.reason == .processTapsUnavailable {
                return .processTapsUnavailable
            }
            return map(
                operation: halError.operation,
                status: halError.status ?? kAudioHardwareUnspecifiedError
            )
        }
        return .operationFailed(
            operation: .getData,
            status: kAudioHardwareUnspecifiedError
        )
    }

    func map(
        operation: AudioHALOperation,
        status: OSStatus
    ) -> ProcessTapEngineError {
        if status == kAudioDevicePermissionsError {
            return .permissionDenied(status)
        }
        return .operationFailed(operation: operation, status: status)
    }

    func teardownFailure(
        from error: Swift.Error,
        fallbackOperation: AudioHALOperation,
        objectID: AudioObjectID,
        processObjectID: AudioObjectID?
    ) -> AudioTeardownFailure {
        if let halError = error as? AudioHALError {
            return AudioTeardownFailure(
                processObjectID: processObjectID,
                operation: halError.operation,
                objectID: halError.objectID,
                status: halError.status ?? kAudioHardwareUnspecifiedError
            )
        }
        return AudioTeardownFailure(
            processObjectID: processObjectID,
            operation: fallbackOperation,
            objectID: objectID,
            status: kAudioHardwareUnspecifiedError
        )
    }

    func status(from error: Swift.Error) -> OSStatus {
        (error as? AudioHALError)?.status ?? kAudioHardwareUnspecifiedError
    }

    static func isSupportedTapFormat(_ format: ProcessTapAudioFormat) -> Bool {
        let supportedFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved
        let isNonInterleaved = format.formatFlags
            & kAudioFormatFlagIsNonInterleaved != 0
        let layoutMatches = isNonInterleaved
            == (format.interleaving == .nonInterleaved)
        return format.isSupportedFloat32LinearPCM
            && format.formatFlags & ~supportedFlags == 0
            && format.formatFlags & kAudioFormatFlagIsPacked != 0
            && layoutMatches
    }

    @available(macOS 14.2, *)
    static func ownedInstanceIdentity(
        _ object: AudioOwnedObject
    ) -> AudioOwnedObjectInstanceIdentity {
        AudioOwnedObjectInstanceIdentity(
            objectID: object.id,
            classID: object.classID,
            uid: object.uid
        )
    }

    @available(macOS 14.2, *)
    static func destroyOperation(
        for object: AudioOwnedObject
    ) -> AudioHALOperation {
        object.classID == kAudioAggregateDeviceClassID
            ? .destroyAggregate
            : .destroyTap
    }

    @available(macOS 14.2, *)
    static func ownedObjectComesBefore(
        _ lhs: AudioOwnedObject,
        _ rhs: AudioOwnedObject
    ) -> Bool {
        let lhsPriority = lhs.classID == kAudioAggregateDeviceClassID ? 0 : 1
        let rhsPriority = rhs.classID == kAudioAggregateDeviceClassID ? 0 : 1
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.id != rhs.id {
            return lhs.id < rhs.id
        }
        return lhs.uid < rhs.uid
    }

    func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}

private struct ProcessTapSession {
    let processObjectID: AudioObjectID
    let generation: UInt64
    let acquisitionID: UUID
}

private struct ProcessTapSessionResources {
    let processObjectID: AudioObjectID
    let generation: UInt64
    var taps: [AudioTapResource] = []
    var mutedTaps: [AudioTapResource] = []
    var aggregate: AudioAggregateResource?
    var ioProc: AudioIOProcResource?
    var context: ProcessTapDSPContext?
}

private struct AudioAcquisitionBundle {
    enum State {
        case preparing
        case active
        case retainedBundle
        case released
    }

    enum Stage {
        case restoreOriginalAudio
        case stopIOProc
        case destroyIOProc
        case destroyAggregate
        case waitForAggregateDisappearance
        case destroyTaps
        case released
    }

    let acquisitionID: UUID
    var resources: ProcessTapSessionResources
    var state: State
    var stage: Stage
    var didStartIOProc: Bool
    var failures: [AudioTeardownFailure]
}

private struct ProcessTapPreparationAbort: Swift.Error {
    let error: ProcessTapEngineError

    init(_ error: ProcessTapEngineError) {
        self.error = error
    }
}

private struct AudioOwnedObjectInstanceIdentity: Hashable {
    let objectID: AudioObjectID
    let classID: AudioClassID
    let uid: String
}

private final class ProcessTapGenerationRegistry: @unchecked Sendable {
    struct Token: Equatable, Sendable {
        let processObjectID: AudioObjectID
        let generation: UInt64
        let sequence: UInt64
        let allEpoch: UInt64
    }

    private struct Record {
        let token: Token
        var isCancelled: Bool
    }

    private let lock = NSLock()
    private var records: [AudioObjectID: Record] = [:]
    private var nextSequence: UInt64 = 0
    private var allEpoch: UInt64 = 0

    func register(
        processObjectID: AudioObjectID,
        generation: UInt64
    ) -> Token {
        lock.lock()
        defer { lock.unlock() }
        nextSequence &+= 1
        let token = Token(
            processObjectID: processObjectID,
            generation: generation,
            sequence: nextSequence,
            allEpoch: allEpoch
        )
        if let current = records[processObjectID],
           generation < current.token.generation {
            return token
        }
        records[processObjectID] = Record(
            token: token,
            isCancelled: false
        )
        return token
    }

    func cancel(_ token: Token) {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[token.processObjectID],
              record.token == token
        else {
            return
        }
        record.isCancelled = true
        records[token.processObjectID] = record
    }

    func cancelAll() {
        lock.lock()
        allEpoch &+= 1
        records.removeAll()
        lock.unlock()
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrentWhileLocked(token)
    }

    func performIfCurrent(
        _ token: Token,
        _ operation: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentWhileLocked(token) else { return false }
        operation()
        return true
    }

    private func isCurrentWhileLocked(_ token: Token) -> Bool {
        guard token.allEpoch == allEpoch,
              let record = records[token.processObjectID]
        else {
            return false
        }
        return record.token == token && record.isCancelled == false
    }
}
