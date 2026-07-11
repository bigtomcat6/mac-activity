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

    private let hardware: (any AudioTapHardware)?
    private let availability: AudioFeatureAvailability
    private let queue: DispatchQueue
    private let retryLedgerLimit: Int
    private let onSessionSnapshot: @Sendable (ProcessTapSessionSnapshot) -> Void
    private let generations = ProcessTapGenerationRegistry()

    // Queue confined.
    private var sessions: [AudioObjectID: ProcessTapSession] = [:]
    private var retryLedger: [AudioTeardownRetryKey: AudioTeardownRetryEntry] = [:]
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
            retryOrphans(using: hardware)
            sessions[processObjectID]?.context.setTargetGain(gain.targetGain)
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
                retryLedger.removeAll()
                successfullyDestroyedOwnedIdentities.removeAll()
                lifetimeLease = nil
                return
            }
            retryOrphans(using: hardware)
            let activeSessions = sessions.values.sorted {
                $0.processObjectID < $1.processObjectID
            }
            sessions.removeAll()
            for session in activeSessions {
                _ = teardown(session.resources, using: hardware)
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
            retryOrphans(using: hardware)
            let discoveryFailures = cleanupOwnedObjects(using: hardware)
            return discoveryFailures + retryFailures()
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

        retryOrphans(using: hardware)
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
            current.context.setTargetGain(gain.targetGain)
            let running = snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .running,
                error: nil
            )
            _ = publish(running, token: token)
            return running
        }

        guard retryLedger.count < retryLedgerLimit else {
            return publishFailure(
                .cleanupBacklogFull,
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                token: token
            )
        }

        if let current = sessions.removeValue(forKey: plan.processObjectID) {
            let rebuilding = snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .rebuilding,
                error: nil
            )
            _ = publish(rebuilding, token: token)
            let failures = teardown(current.resources, using: hardware)
            guard generations.isCurrent(token) else {
                return snapshot(
                    processObjectID: plan.processObjectID,
                    generation: plan.generation,
                    state: .failed,
                    error: .routeSuperseded
                )
            }
            if let failure = failures.first {
                return publishFailure(
                    map(operation: failure.operation, status: failure.status),
                    processObjectID: plan.processObjectID,
                    generation: plan.generation,
                    token: token
                )
            }
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
        var resources = ProcessTapSessionResources(
            processObjectID: plan.processObjectID,
            generation: plan.generation
        )

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
                resources.taps.append(tap)
                try ensureCurrent(token)
            }

            for (index, tap) in resources.taps.enumerated() {
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
                taps: resources.taps
            )
            resources.aggregate = aggregate
            resources.aggregateAcquisitionID = UUID()
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
                tap: resources.taps[0],
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
            resources.context = context
            let ioProc = try hardware.createIOProc(
                aggregate: aggregate,
                context: context
            )
            resources.ioProc = ioProc
            resources.ioProcAcquisitionID = UUID()
            try ensureCurrent(token)

            let verifiedUsage = try hardware.configureInputStreamUsage(
                layout.inputStreamUsage,
                for: ioProc
            )
            guard verifiedUsage == layout.inputStreamUsage else {
                throw ProcessTapPreparationAbort(.unsupportedFormat)
            }
            try ensureCurrent(token)

            try hardware.start(ioProc)
            try ensureCurrent(token)
            try waitForFirstCallback(context, token: token)

            for tap in resources.taps {
                try hardware.setMuteState(.mutedWhenTapped, for: tap)
                resources.mutedTaps.append(tap)
                try ensureCurrent(token)
            }

            context.setOutputGateOpen(true)
            try ensureCurrent(token)

            let session = ProcessTapSession(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                resources: resources,
                context: context
            )
            let running = snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .running,
                error: nil
            )
            let installed = generations.performIfCurrent(token) { [self] in
                sessions[plan.processObjectID] = session
                lifetimeLease = self
            }
            guard installed else {
                throw ProcessTapPreparationAbort(.routeSuperseded)
            }
            onSessionSnapshot(running)
            return running
        } catch {
            resources.context?.setOutputGateOpen(false)
            _ = teardown(resources, using: hardware)
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

        retryOrphans(using: hardware)
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
        let failures = teardown(session.resources, using: hardware)
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

    func waitForFirstCallback(
        _ context: ProcessTapDSPContext,
        token: ProcessTapGenerationRegistry.Token
    ) throws {
        let deadline = DispatchTime.now() + Self.preparationTimeout
        while context.hasObservedCallback == false {
            try ensureCurrent(token)
            guard DispatchTime.now() < deadline else {
                throw ProcessTapPreparationAbort(.aggregateNotReady)
            }
            usleep(1_000)
        }
        try ensureCurrent(token)
    }

    func teardown(
        _ resources: ProcessTapSessionResources,
        using hardware: any AudioTapHardware
    ) -> [AudioTeardownFailure] {
        defer { refreshLifetimeLease() }
        resources.context?.setOutputGateOpen(false)
        var failures: [AudioTeardownFailure] = []

        for tap in resources.mutedTaps.reversed() {
            let status = hardware.restoreOriginalAudio(for: tap)
            if status != noErr {
                let failure = AudioTeardownFailure(
                    processObjectID: resources.processObjectID,
                    operation: .setData,
                    objectID: tap.objectID,
                    status: status
                )
                failures.append(failure)
                addRetry(
                    failure: failure,
                    ownership: .tap(tap.uuid),
                    payload: .setTapUnmuted(tap)
                )
            }
        }

        if let ioProc = resources.ioProc,
           let context = resources.context {
            guard let ioProcAcquisitionID = resources.ioProcAcquisitionID else {
                preconditionFailure("IOProc ownership identity must accompany the resource")
            }
            recordTeardownStatus(
                hardware.stop(ioProc),
                operation: .stopDevice,
                objectID: ioProc.aggregateDeviceID,
                ownership: .ioProc(ioProcAcquisitionID),
                processObjectID: resources.processObjectID,
                payload: .stop(ioProc, context),
                failures: &failures
            )
            recordTeardownStatus(
                hardware.destroyIOProc(ioProc),
                operation: .destroyIOProc,
                objectID: ioProc.aggregateDeviceID,
                ownership: .ioProc(ioProcAcquisitionID),
                processObjectID: resources.processObjectID,
                payload: .destroyIOProc(ioProc, context),
                failures: &failures
            )
        }

        if let aggregate = resources.aggregate {
            guard let aggregateAcquisitionID = resources.aggregateAcquisitionID else {
                preconditionFailure("aggregate ownership identity must accompany the resource")
            }
            let status = hardware.destroyAggregate(aggregate)
            recordTeardownStatus(
                status,
                operation: .destroyAggregate,
                objectID: aggregate.objectID,
                ownership: .aggregate(aggregateAcquisitionID),
                processObjectID: resources.processObjectID,
                payload: .destroyAggregate(aggregate),
                failures: &failures
            )
            if status == noErr {
                successfullyDestroyedOwnedIdentities.insert(
                    AudioOwnedObjectInstanceIdentity(
                        objectID: aggregate.objectID,
                        classID: kAudioAggregateDeviceClassID,
                        uid: aggregate.uid
                    )
                )
            }
        }

        for tap in resources.taps.reversed() {
            let status = hardware.destroyTap(tap)
            recordTeardownStatus(
                status,
                operation: .destroyTap,
                objectID: tap.objectID,
                ownership: .tap(tap.uuid),
                processObjectID: resources.processObjectID,
                payload: .destroyTap(tap),
                failures: &failures
            )
            if status == noErr {
                if #available(macOS 14.2, *) {
                    successfullyDestroyedOwnedIdentities.insert(
                        AudioOwnedObjectInstanceIdentity(
                            objectID: tap.objectID,
                            classID: kAudioTapClassID,
                            uid: tap.uuid.uuidString
                        )
                    )
                }
                retryLedger.removeValue(forKey: AudioTeardownRetryKey(
                    operation: .setData,
                    objectID: tap.objectID,
                    ownership: .tap(tap.uuid)
                ))
            }
        }
        return failures
    }

    func recordTeardownStatus(
        _ status: OSStatus,
        operation: AudioHALOperation,
        objectID: AudioObjectID,
        ownership: AudioTeardownOwnershipIdentity,
        processObjectID: AudioObjectID?,
        payload: AudioTeardownRetryPayload,
        failures: inout [AudioTeardownFailure]
    ) {
        let key = AudioTeardownRetryKey(
            operation: operation,
            objectID: objectID,
            ownership: ownership
        )
        guard status != noErr else {
            retryLedger.removeValue(forKey: key)
            return
        }
        let failure = AudioTeardownFailure(
            processObjectID: processObjectID,
            operation: operation,
            objectID: objectID,
            status: status
        )
        failures.append(failure)
        addRetry(
            failure: failure,
            ownership: ownership,
            payload: payload
        )
    }

    func addRetry(
        failure: AudioTeardownFailure,
        ownership: AudioTeardownOwnershipIdentity,
        payload: AudioTeardownRetryPayload
    ) {
        let key = AudioTeardownRetryKey(
            operation: failure.operation,
            objectID: failure.objectID,
            ownership: ownership
        )
        retryLedger[key] = AudioTeardownRetryEntry(
            key: key,
            processObjectID: failure.processObjectID,
            status: failure.status,
            payload: payload
        )
    }

    func retryOrphans(using hardware: any AudioTapHardware) {
        defer { refreshLifetimeLease() }
        let activeObjectIDs = activeOwnedObjectIDs()
        let entries = retryLedger.values.sorted {
            if $0.key.priority == $1.key.priority {
                if $0.key.objectID == $1.key.objectID {
                    return $0.key.ownership.sortKey < $1.key.ownership.sortKey
                }
                return $0.key.objectID < $1.key.objectID
            }
            return $0.key.priority < $1.key.priority
        }
        for entry in entries {
            if activeObjectIDs.contains(entry.key.objectID) {
                retryLedger.removeValue(forKey: entry.key)
                continue
            }
            if case .destroyOwned = entry.payload {
                continue
            }
            let retryStatus: OSStatus
            switch entry.payload {
            case .setTapUnmuted(let tap):
                retryStatus = hardware.restoreOriginalAudio(for: tap)
            case .stop(let ioProc, _):
                retryStatus = hardware.stop(ioProc)
            case .destroyIOProc(let ioProc, _):
                retryStatus = hardware.destroyIOProc(ioProc)
            case .destroyAggregate(let aggregate):
                retryStatus = hardware.destroyAggregate(aggregate)
            case .destroyTap(let tap):
                retryStatus = hardware.destroyTap(tap)
            case .destroyOwned(let object):
                retryStatus = hardware.destroyOwnedObject(object)
            }

            if retryStatus == noErr {
                retryLedger.removeValue(forKey: entry.key)
                if #available(macOS 14.2, *) {
                    switch entry.payload {
                    case .destroyAggregate(let aggregate):
                        successfullyDestroyedOwnedIdentities.insert(
                            AudioOwnedObjectInstanceIdentity(
                                objectID: aggregate.objectID,
                                classID: kAudioAggregateDeviceClassID,
                                uid: aggregate.uid
                            )
                        )
                    case .destroyTap(let tap):
                        successfullyDestroyedOwnedIdentities.insert(
                            AudioOwnedObjectInstanceIdentity(
                                objectID: tap.objectID,
                                classID: kAudioTapClassID,
                                uid: tap.uuid.uuidString
                            )
                        )
                    default:
                        break
                    }
                }
                if entry.key.operation == .destroyTap {
                    retryLedger.removeValue(forKey: AudioTeardownRetryKey(
                        operation: .setData,
                        objectID: entry.key.objectID,
                        ownership: entry.key.ownership
                    ))
                }
            } else {
                var updated = entry
                updated.status = retryStatus
                retryLedger[entry.key] = updated
            }
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
        let currentOwnedRetryKeys = Set(ownedObjects.map { object in
            AudioTeardownRetryKey(
                operation: Self.destroyOperation(for: object),
                objectID: object.id,
                ownership: Self.ownedIdentity(object)
            )
        })
        for key in Array(retryLedger.keys) {
            guard case .owned = key.ownership,
                  currentOwnedRetryKeys.contains(key) == false
                    || activeObjectIDs.contains(key.objectID)
            else {
                continue
            }
            retryLedger.removeValue(forKey: key)
        }

        let candidates = ownedObjects
            .filter { activeObjectIDs.contains($0.id) == false }
            .filter {
                return successfullyDestroyedOwnedIdentities.contains(
                    Self.ownedInstanceIdentity($0)
                ) == false
                    && normalDestroyRetryRepresents($0) == false
            }
            .sorted(by: Self.ownedObjectComesBefore)

        for object in candidates {
            let ownership = Self.ownedIdentity(object)
            let operation = Self.destroyOperation(for: object)
            let retryKey = AudioTeardownRetryKey(
                operation: operation,
                objectID: object.id,
                ownership: ownership
            )
            let status = hardware.destroyOwnedObject(object)
            if status == noErr {
                retryLedger.removeValue(forKey: retryKey)
                successfullyDestroyedOwnedIdentities.insert(
                    Self.ownedInstanceIdentity(object)
                )
                continue
            }

            let failure = AudioTeardownFailure(
                processObjectID: nil,
                operation: operation,
                objectID: object.id,
                status: status
            )
            if var retry = retryLedger[retryKey] {
                retry.status = status
                retryLedger[retryKey] = retry
            } else {
                addRetry(
                    failure: failure,
                    ownership: ownership,
                    payload: .destroyOwned(object)
                )
            }
        }
        return discovery.failures
    }

    @available(macOS 14.2, *)
    func normalDestroyRetryRepresents(_ object: AudioOwnedObject) -> Bool {
        retryLedger.values.contains { entry in
            switch entry.payload {
            case .destroyAggregate(let aggregate):
                object.classID == kAudioAggregateDeviceClassID
                    && object.id == aggregate.objectID
                    && object.uid == aggregate.uid
            case .destroyTap(let tap):
                object.classID == kAudioTapClassID
                    && object.id == tap.objectID
                    && object.uid == tap.uuid.uuidString
            default:
                false
            }
        }
    }

    func retryFailures() -> [AudioTeardownFailure] {
        retryLedger.values.sorted {
            if $0.key.operation.rawValue == $1.key.operation.rawValue {
                if $0.key.objectID == $1.key.objectID {
                    return $0.key.ownership.sortKey < $1.key.ownership.sortKey
                }
                return $0.key.objectID < $1.key.objectID
            }
            return $0.key.operation.rawValue < $1.key.operation.rawValue
        }.map { entry in
            AudioTeardownFailure(
                processObjectID: entry.processObjectID,
                operation: entry.key.operation,
                objectID: entry.key.objectID,
                status: entry.status
            )
        }
    }

    func refreshLifetimeLease() {
        let ledgerRetainsDSPContext = retryLedger.values.contains {
            $0.payload.retainsDSPContext
        }
        if sessions.isEmpty && ledgerRetainsDSPContext == false {
            lifetimeLease = nil
        } else {
            lifetimeLease = self
        }
    }

    func activeOwnedObjectIDs() -> Set<AudioObjectID> {
        Set(sessions.values.flatMap { session in
            session.resources.taps.map(\.objectID)
                + [session.resources.aggregate?.objectID].compactMap { $0 }
        })
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
    static func ownedIdentity(
        _ object: AudioOwnedObject
    ) -> AudioTeardownOwnershipIdentity {
        .owned(classID: object.classID, uid: object.uid)
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
    let resources: ProcessTapSessionResources
    let context: ProcessTapDSPContext
}

private struct ProcessTapSessionResources {
    let processObjectID: AudioObjectID
    let generation: UInt64
    var taps: [AudioTapResource] = []
    var mutedTaps: [AudioTapResource] = []
    var aggregate: AudioAggregateResource?
    var aggregateAcquisitionID: UUID?
    var ioProc: AudioIOProcResource?
    var ioProcAcquisitionID: UUID?
    var context: ProcessTapDSPContext?
}

private struct ProcessTapPreparationAbort: Swift.Error {
    let error: ProcessTapEngineError

    init(_ error: ProcessTapEngineError) {
        self.error = error
    }
}

private struct AudioTeardownRetryKey: Hashable {
    let operationName: String
    let objectID: AudioObjectID
    let ownership: AudioTeardownOwnershipIdentity

    init(
        operation: AudioHALOperation,
        objectID: AudioObjectID,
        ownership: AudioTeardownOwnershipIdentity
    ) {
        operationName = operation.rawValue
        self.objectID = objectID
        self.ownership = ownership
    }

    var operation: AudioHALOperation {
        guard let operation = AudioHALOperation(rawValue: operationName) else {
            preconditionFailure("Unknown HAL operation in teardown ledger")
        }
        return operation
    }

    var priority: Int {
        switch operation {
        case .setData:
            -1
        case .stopDevice:
            0
        case .destroyIOProc:
            1
        case .destroyAggregate:
            2
        case .destroyTap:
            3
        default:
            4
        }
    }
}

private enum AudioTeardownOwnershipIdentity: Hashable {
    case ioProc(UUID)
    case aggregate(UUID)
    case tap(UUID)
    case owned(classID: AudioClassID, uid: String)

    var sortKey: String {
        switch self {
        case .ioProc(let id):
            "0-\(id.uuidString)"
        case .aggregate(let id):
            "1-\(id.uuidString)"
        case .tap(let id):
            "2-\(id.uuidString)"
        case .owned(let classID, let uid):
            "3-\(classID)-\(uid)"
        }
    }
}

private struct AudioOwnedObjectInstanceIdentity: Hashable {
    let objectID: AudioObjectID
    let classID: AudioClassID
    let uid: String
}

private struct AudioTeardownRetryEntry {
    let key: AudioTeardownRetryKey
    let processObjectID: AudioObjectID?
    var status: OSStatus
    let payload: AudioTeardownRetryPayload
}

private enum AudioTeardownRetryPayload {
    case setTapUnmuted(AudioTapResource)
    case stop(AudioIOProcResource, ProcessTapDSPContext)
    case destroyIOProc(AudioIOProcResource, ProcessTapDSPContext)
    case destroyAggregate(AudioAggregateResource)
    case destroyTap(AudioTapResource)
    case destroyOwned(AudioOwnedObject)

    var retainsDSPContext: Bool {
        switch self {
        case .stop, .destroyIOProc:
            true
        case .setTapUnmuted, .destroyAggregate, .destroyTap, .destroyOwned:
            false
        }
    }
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
