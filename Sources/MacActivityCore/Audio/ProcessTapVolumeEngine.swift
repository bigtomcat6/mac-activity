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
    case leaseUnavailable
    case leaseFailed
    case permissionDenied(OSStatus)
    case unsupportedFormat
    case routeSuperseded
    case aggregateNotReady
    case cleanupBacklogFull
    case operationFailed(operation: AudioHALOperation, status: OSStatus)
}

public struct ProcessTapSnapshotOrder: Equatable, Comparable, Sendable {
    public let commandSequence: UInt64
    public let emissionOrdinal: UInt64

    public init(commandSequence: UInt64, emissionOrdinal: UInt64) {
        self.commandSequence = commandSequence
        self.emissionOrdinal = emissionOrdinal
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.commandSequence == rhs.commandSequence
            ? lhs.emissionOrdinal < rhs.emissionOrdinal
            : lhs.commandSequence < rhs.commandSequence
    }
}

public struct ProcessTapSessionSnapshot: Equatable, Sendable {
    public let processObjectID: AudioObjectID
    public let generation: UInt64
    public let state: ProcessTapSessionState
    public let error: ProcessTapEngineError?
    public let commandSequence: UInt64
    public let emissionOrdinal: UInt64

    public var order: ProcessTapSnapshotOrder {
        ProcessTapSnapshotOrder(
            commandSequence: commandSequence,
            emissionOrdinal: emissionOrdinal
        )
    }

    public init(
        processObjectID: AudioObjectID,
        generation: UInt64,
        state: ProcessTapSessionState,
        error: ProcessTapEngineError?,
        commandSequence: UInt64,
        emissionOrdinal: UInt64
    ) {
        self.processObjectID = processObjectID
        self.generation = generation
        self.state = state
        self.error = error
        self.commandSequence = commandSequence
        self.emissionOrdinal = emissionOrdinal
    }

    public init(
        processObjectID: AudioObjectID,
        generation: UInt64,
        state: ProcessTapSessionState,
        error: ProcessTapEngineError?
    ) {
        self.init(
            processObjectID: processObjectID,
            generation: generation,
            state: state,
            error: error,
            commandSequence: 0,
            emissionOrdinal: 0
        )
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

public enum ProcessTapRuntimePreparation: Equatable, Sendable {
    case ready(cleanupFailures: [AudioTeardownFailure])
    case unavailable(ProcessTapEngineError)
}

public protocol ProcessTapVolumeControlling: AnyObject, Sendable {
    var sessionSnapshots: AsyncStream<ProcessTapSessionSnapshot> { get }

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
    func prepareRuntime() async -> ProcessTapRuntimePreparation
    func cleanupOrphans() async -> [AudioTeardownFailure]
    func shutdown() async
}

public final class ProcessTapVolumeEngine: ProcessTapVolumeControlling, @unchecked Sendable {
    public let sessionSnapshots: AsyncStream<ProcessTapSessionSnapshot>

    private static let preparationTimeout: DispatchTimeInterval = .seconds(2)
    private static let callbackObservationInterval: DispatchTimeInterval = .milliseconds(10)

    private let hardware: (any AudioTapHardware)?
    private let availability: AudioFeatureAvailability
    private let ownershipLeaseAcquirer: any AudioProcessOwnershipLeaseAcquiring
    private let queue: DispatchQueue
    private let retryLedgerLimit: Int
    private let retryScheduler: any ProcessTapRetryScheduling
    private let onSessionSnapshot: @Sendable (ProcessTapSessionSnapshot) -> Void
    private let sessionSnapshotContinuation: AsyncStream<ProcessTapSessionSnapshot>.Continuation
    private let generations = ProcessTapGenerationRegistry()

    // Queue confined.
    private var sessions: [AudioObjectID: ProcessTapSession] = [:]
    private var bundles: [UUID: AudioAcquisitionBundle] = [:]
    private var successfullyDestroyedOwnedIdentities: Set<AudioOwnedObjectInstanceIdentity> = []
    private var retryBackoff = ProcessTapRetryBackoff()
    private var runtimeRejections: ProcessTapRuntimeRejectionCache
    private var nextRetryScheduleID: UInt64 = 0
    private var pendingRetryScheduleID: UInt64?
    private var pendingRetryDelay: DispatchTimeInterval?
    private var pendingRetryCancellation: (any ProcessTapRetryCancellation)?
    private var isRetryPassRunning = false
    #if DEBUG
    private var concurrentRetryPasses = 0
    private var retryPassCount = 0
    private var maximumConcurrentRetryPasses = 0
    #endif
    private var orphanCleanupPending = false
    private var ownershipLease: (any AudioProcessOwnershipLease)?
    private var cleanupRetention: ProcessTapVolumeEngine?
    private var isDraining = false
    #if DEBUG
    private var activeMutationSupersessionForTesting: (
        processObjectID: AudioObjectID,
        generation: UInt64
    )?
    private var snapshotPublishSupersessionForTesting: (
        processObjectID: AudioObjectID,
        generation: UInt64
    )?
    #endif

    public convenience init(availability: AudioFeatureAvailability = .current) {
        self.init(
            hardware: CoreAudioTapHardware(hal: .system),
            leaseAcquirer: DarwinAudioProcessOwnershipLeaseAcquirer(),
            availability: availability
        )
    }

    convenience init(
        hardware: any AudioTapHardware,
        leaseAcquirer: any AudioProcessOwnershipLeaseAcquiring =
            DarwinAudioProcessOwnershipLeaseAcquirer(),
        availability: AudioFeatureAvailability = .current,
        queue: DispatchQueue = DispatchQueue(
            label: "com.how.macactivity.audio.process-tap",
            qos: .userInitiated
        ),
        retryLedgerLimit: Int = 32,
        retryScheduler: (any ProcessTapRetryScheduling)? = nil,
        onSessionSnapshot: @escaping @Sendable (ProcessTapSessionSnapshot) -> Void = { _ in }
    ) {
        self.init(
            optionalHardware: hardware,
            leaseAcquirer: leaseAcquirer,
            availability: availability,
            queue: queue,
            retryLedgerLimit: retryLedgerLimit,
            retryScheduler: retryScheduler,
            onSessionSnapshot: onSessionSnapshot
        )
    }

    private init(
        optionalHardware: (any AudioTapHardware)?,
        leaseAcquirer: any AudioProcessOwnershipLeaseAcquiring,
        availability: AudioFeatureAvailability,
        queue: DispatchQueue,
        retryLedgerLimit: Int,
        retryScheduler: (any ProcessTapRetryScheduling)?,
        onSessionSnapshot: @escaping @Sendable (ProcessTapSessionSnapshot) -> Void
    ) {
        let snapshotStream = AsyncStream<ProcessTapSessionSnapshot>.makeStream()
        sessionSnapshots = snapshotStream.stream
        sessionSnapshotContinuation = snapshotStream.continuation
        hardware = optionalHardware
        ownershipLeaseAcquirer = leaseAcquirer
        self.availability = availability
        self.queue = queue
        self.retryLedgerLimit = max(1, retryLedgerLimit)
        self.retryScheduler = retryScheduler
            ?? DispatchProcessTapRetryScheduler(queue: queue)
        self.runtimeRejections = ProcessTapRuntimeRejectionCache(
            capacity: max(1, retryLedgerLimit)
        )
        self.onSessionSnapshot = onSessionSnapshot
    }

    deinit {
        sessionSnapshotContinuation.finish()
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
                orphanCleanupPending = false
                cancelPendingRetry()
                cleanupRetention = nil
                return
            }
            stopAllOnQueue(using: hardware)
        }
    }

    public func prepareRuntime() async -> ProcessTapRuntimePreparation {
        await enqueue { [self] in prepareRuntimeOnQueue() }
    }

    public func cleanupOrphans() async -> [AudioTeardownFailure] {
        switch await prepareRuntime() {
        case .ready(let cleanupFailures):
            cleanupFailures
        case .unavailable:
            []
        }
    }

    public func shutdown() async {
        generations.cancelAll()
        await enqueue { [self] in
            isDraining = true
            guard availability.supportsProcessControls,
                  #available(macOS 14.2, *),
                  let hardware
            else {
                sessions.removeAll()
                bundles.removeAll()
                successfullyDestroyedOwnedIdentities.removeAll()
                orphanCleanupPending = false
                cancelPendingRetry()
                cleanupRetention = nil
                releaseOwnershipIfTerminal()
                return
            }
            stopAllOnQueue(using: hardware)
            releaseOwnershipIfTerminal()
        }
    }

    static func callbackProgressIsReady(
        now: DispatchTime,
        deadline: DispatchTime,
        countBeforeObservation: Int32,
        currentCount: Int32
    ) -> Bool {
        now < deadline && currentCount != countBeforeObservation
    }

    #if DEBUG
    enum ActiveSessionCorruptionForTesting {
        case missingBundle
        case releasedBundle
        case mismatchedAcquisitionID
        case mismatchedProcessObjectID
        case missingContext
    }

    func waitUntilIdleForTesting() async {
        await enqueue {}
    }

    func maximumConcurrentRetryPassesForTesting() async -> Int {
        await enqueue { [self] in maximumConcurrentRetryPasses }
    }

    func retryPassCountForTesting() async -> Int {
        await enqueue { [self] in retryPassCount }
    }

    func corruptActiveSessionForTesting(
        processObjectID: AudioObjectID,
        corruption: ActiveSessionCorruptionForTesting
    ) async {
        await enqueue { [self] in
            guard let session = sessions[processObjectID],
                  var bundle = bundles[session.acquisitionID]
            else {
                return
            }
            switch corruption {
            case .missingBundle:
                bundles.removeValue(forKey: session.acquisitionID)
                return
            case .releasedBundle:
                bundle.state = .released
            case .mismatchedAcquisitionID:
                bundle = AudioAcquisitionBundle(
                    acquisitionID: UUID(),
                    resources: bundle.resources,
                    state: bundle.state,
                    stage: bundle.stage,
                    didStartIOProc: bundle.didStartIOProc,
                    failures: bundle.failures
                )
            case .mismatchedProcessObjectID:
                let resources = bundle.resources
                bundle.resources = ProcessTapSessionResources(
                    processObjectID: resources.processObjectID &+ 1,
                    generation: resources.generation,
                    taps: resources.taps,
                    mutedTaps: resources.mutedTaps,
                    aggregate: resources.aggregate,
                    ioProc: resources.ioProc,
                    context: resources.context
                )
            case .missingContext:
                bundle.resources.context = nil
            }
            bundles[session.acquisitionID] = bundle
        }
    }

    func supersedeNextActiveSessionMutationForTesting(
        processObjectID: AudioObjectID,
        generation: UInt64
    ) async {
        await enqueue { [self] in
            activeMutationSupersessionForTesting = (
                processObjectID,
                generation
            )
        }
    }

    func supersedeNextSnapshotPublishForTesting(
        processObjectID: AudioObjectID,
        generation: UInt64
    ) async {
        await enqueue { [self] in
            snapshotPublishSupersessionForTesting = (
                processObjectID,
                generation
            )
        }
    }
    #endif
}

private extension ProcessTapVolumeEngine {
    func prepareRuntimeOnQueue() -> ProcessTapRuntimePreparation {
        guard availability.supportsProcessControls,
              #available(macOS 14.2, *),
              let hardware else {
            return .unavailable(.processTapsUnavailable)
        }
        if let leaseError = acquireOwnershipIfNeeded() {
            return .unavailable(leaseError)
        }
        advanceRetainedBundles(using: hardware)
        let cleanup = cleanupOwnedObjects(using: hardware)
        orphanCleanupPending = cleanup.shouldRetry
        if cleanup.didProgress {
            recordRetryProgress()
        }
        scheduleRetryIfNeeded()
        return .ready(cleanupFailures: cleanup.failures + bundleFailures())
    }

    func acquireOwnershipIfNeeded() -> ProcessTapEngineError? {
        guard isDraining == false else { return .leaseUnavailable }
        guard ownershipLease == nil else { return nil }
        do {
            ownershipLease = try ownershipLeaseAcquirer.acquire()
            return nil
        } catch AudioProcessOwnershipLeaseError.busy {
            return .leaseUnavailable
        } catch {
            return .leaseFailed
        }
    }

    func stopAllOnQueue(using hardware: any AudioTapHardware) {
        advanceRetainedBundles(using: hardware)
        let activeSessions = sessions.values.sorted {
            $0.processObjectID < $1.processObjectID
        }
        sessions.removeAll()
        for session in activeSessions {
            _ = teardownRecordingProgress(
                session.acquisitionID,
                using: hardware
            )
        }
        scheduleRetryIfNeeded()
    }

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
                error: .routeSuperseded,
                token: token
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
        if let leaseError = acquireOwnershipIfNeeded() {
            return publishFailure(
                leaseError,
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                token: token
            )
        }

        if sessions[plan.processObjectID]?.generation == plan.generation {
            #if DEBUG
            if let supersession = activeMutationSupersessionForTesting {
                activeMutationSupersessionForTesting = nil
                _ = generations.register(
                    processObjectID: supersession.processObjectID,
                    generation: supersession.generation
                )
            }
            #endif
            var didUpdateActiveSession = false
            guard generations.performIfCurrent(token, { [self] in
                guard let current = sessions[plan.processObjectID],
                      current.processObjectID == plan.processObjectID,
                      current.generation == plan.generation,
                      let bundle = bundles[current.acquisitionID],
                      bundle.acquisitionID == current.acquisitionID,
                      bundle.state == .active,
                      bundle.resources.processObjectID == current.processObjectID,
                      bundle.resources.generation == current.generation,
                      let context = bundle.resources.context
                else {
                    return
                }
                context.setTargetGain(gain.targetGain)
                didUpdateActiveSession = true
            }) else {
                return snapshot(
                    processObjectID: plan.processObjectID,
                    generation: plan.generation,
                    state: .failed,
                    error: .routeSuperseded,
                    token: token
                )
            }
            if didUpdateActiveSession {
                guard let running = publishSnapshot(
                    processObjectID: plan.processObjectID,
                    generation: plan.generation,
                    state: .running,
                    error: nil,
                    token: token
                ) else {
                    return snapshot(
                        processObjectID: plan.processObjectID,
                        generation: plan.generation,
                        state: .failed,
                        error: .routeSuperseded,
                        token: token
                    )
                }
                return running
            }
        }

        guard runtimeRejections.contains(plan.topologyFingerprint) == false else {
            return publishFailure(
                .unsupportedFormat,
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
                error: .routeSuperseded,
                token: token
            )
        }

        if let current = sessions[plan.processObjectID] {
            guard publishSnapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .rebuilding,
                error: nil,
                token: token
            ) != nil else {
                return snapshot(
                    processObjectID: plan.processObjectID,
                    generation: plan.generation,
                    state: .failed,
                    error: .routeSuperseded,
                    token: token
                )
            }
            sessions.removeValue(forKey: plan.processObjectID)
            _ = teardownRecordingProgress(
                current.acquisitionID,
                using: hardware
            )
            guard generations.isCurrent(token) else {
                return snapshot(
                    processObjectID: plan.processObjectID,
                    generation: plan.generation,
                    state: .failed,
                    error: .routeSuperseded,
                    token: token
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

        guard publishSnapshot(
            processObjectID: plan.processObjectID,
            generation: plan.generation,
            state: .preparing,
            error: nil,
            token: token
        ) != nil else {
            return snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .failed,
                error: .routeSuperseded,
                token: token
            )
        }
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
                try verifyMuteState(.unmuted, for: tap, using: hardware)
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
                throw AudioIOProcStreamUsageError.flagsMismatch
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
                try verifyMuteState(.mutedWhenTapped, for: tap, using: hardware)
                try ensureCurrent(token)
            }

            context.setOutputGateOpen(true)
            try ensureCurrent(token)

            let session = ProcessTapSession(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                acquisitionID: acquisitionID
            )
            let installed = generations.performIfCurrent(token) { [self] in
                transitionBundle(acquisitionID, to: .active)
                sessions[plan.processObjectID] = session
                cleanupRetention = self
            }
            guard installed else {
                throw ProcessTapPreparationAbort(.routeSuperseded)
            }
            let running = snapshot(
                processObjectID: plan.processObjectID,
                generation: plan.generation,
                state: .running,
                error: nil,
                token: token
            )
            onSessionSnapshot(running)
            return running
        } catch {
            if Self.isCacheableRuntimeRejection(error) {
                runtimeRejections.insert(plan.topologyFingerprint)
            }
            bundles[acquisitionID]?.resources.context?.setOutputGateOpen(false)
            _ = teardownRecordingProgress(acquisitionID, using: hardware)
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
                error: .routeSuperseded,
                token: token
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
                error: .routeSuperseded,
                token: token
            )
        }
        guard let session = sessions[processObjectID] else {
            guard let idle = publishSnapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .idle,
                error: nil,
                token: token
            ) else {
                return snapshot(
                    processObjectID: processObjectID,
                    generation: generation,
                    state: .failed,
                    error: .routeSuperseded,
                    token: token
                )
            }
            return idle
        }
        guard session.generation <= generation else {
            return snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: .routeSuperseded,
                token: token
            )
        }

        guard publishSnapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: .stopping,
            error: nil,
            token: token
        ) != nil else {
            return snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: .routeSuperseded,
                token: token
            )
        }
        sessions.removeValue(forKey: processObjectID)
        let failures = teardownRecordingProgress(
            session.acquisitionID,
            using: hardware
        ).failures
        guard generations.isCurrent(token) else {
            return snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: .routeSuperseded,
                token: token
            )
        }

        let resultState: ProcessTapSessionState
        let resultError: ProcessTapEngineError?
        if let failure = failures.first {
            resultState = .failed
            resultError = map(
                operation: failure.operation,
                status: failure.status
            )
        } else {
            resultState = .idle
            resultError = nil
        }
        guard let result = publishSnapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: resultState,
            error: resultError,
            token: token
        ) else {
            return snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: .routeSuperseded,
                token: token
            )
        }
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
        guard bundles[acquisitionID]?.resources.mutedTaps.isEmpty == true else {
            retainBundle(acquisitionID)
            return bundles[acquisitionID]?.failures ?? []
        }

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
                refreshCleanupRetention()
                return []
            }
        }
        return []
    }

    func teardownRecordingProgress(
        _ acquisitionID: UUID,
        using hardware: any AudioTapHardware
    ) -> (failures: [AudioTeardownFailure], didProgress: Bool) {
        let before = bundleProgress(for: acquisitionID)
        let failures = teardown(acquisitionID, using: hardware)
        let didProgress = before != bundleProgress(for: acquisitionID)
        if didProgress {
            recordRetryProgress()
        }
        return (failures, didProgress)
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
        else {
            scheduleRetryIfNeeded()
            return
        }
        transitionBundle(acquisitionID, to: .retainedBundle)
        scheduleRetryIfNeeded()
    }

    @discardableResult
    func advanceRetainedBundles(using hardware: any AudioTapHardware) -> Bool {
        let acquisitionIDs = bundles.values
            .filter { $0.state == .retainedBundle }
            .map(\.acquisitionID)
            .sorted { $0.uuidString < $1.uuidString }
        var didProgress = false
        for acquisitionID in acquisitionIDs {
            didProgress = teardownRecordingProgress(
                acquisitionID,
                using: hardware
            ).didProgress || didProgress
        }
        scheduleRetryIfNeeded()
        return didProgress
    }

    func recordRetryProgress() {
        guard pendingRetryDelay != .milliseconds(50) else { return }
        retryBackoff.recordProgress()
        guard pendingRetryScheduleID != nil else { return }
        cancelPendingRetry()
        scheduleRetryIfNeeded()
    }

    func scheduleRetryIfNeeded() {
        let hasRetainedBundle = bundles.values.contains {
            $0.state == .retainedBundle
        }
        guard hasRetainedBundle || orphanCleanupPending else {
            retryBackoff.recordProgress()
            cancelPendingRetry()
            refreshCleanupRetention()
            releaseOwnershipIfTerminal()
            return
        }
        refreshCleanupRetention()
        guard pendingRetryScheduleID == nil, isRetryPassRunning == false else {
            return
        }

        precondition(nextRetryScheduleID < UInt64.max)
        nextRetryScheduleID += 1
        let scheduleID = nextRetryScheduleID
        pendingRetryScheduleID = scheduleID
        let delay = retryBackoff.nextDelay()
        pendingRetryDelay = delay
        pendingRetryCancellation = retryScheduler.schedule(
            after: delay
        ) { [weak self] in
            self?.queue.async { [weak self] in
                self?.retryPassOnQueue(ifCurrent: scheduleID)
            }
        }
    }

    func cancelPendingRetry() {
        pendingRetryCancellation?.cancel()
        pendingRetryCancellation = nil
        pendingRetryScheduleID = nil
        pendingRetryDelay = nil
    }

    func retryPassOnQueue(ifCurrent scheduleID: UInt64) {
        guard pendingRetryScheduleID == scheduleID else { return }
        pendingRetryScheduleID = nil
        pendingRetryDelay = nil
        pendingRetryCancellation = nil
        guard isRetryPassRunning == false, ownershipLease != nil else { return }

        isRetryPassRunning = true
        #if DEBUG
        concurrentRetryPasses += 1
        retryPassCount += 1
        maximumConcurrentRetryPasses = max(
            maximumConcurrentRetryPasses,
            concurrentRetryPasses
        )
        #endif
        if availability.supportsProcessControls,
           #available(macOS 14.2, *),
           let hardware {
            advanceRetainedBundles(using: hardware)
            if orphanCleanupPending {
                let cleanup = cleanupOwnedObjects(using: hardware)
                orphanCleanupPending = cleanup.shouldRetry
                if cleanup.didProgress {
                    recordRetryProgress()
                }
            }
        }
        #if DEBUG
        concurrentRetryPasses -= 1
        #endif
        isRetryPassRunning = false
        scheduleRetryIfNeeded()
    }

    func bundleProgress(for acquisitionID: UUID) -> AudioAcquisitionProgress? {
        guard let bundle = bundles[acquisitionID] else { return nil }
        return AudioAcquisitionProgress(
            state: bundle.state,
            stage: bundle.stage,
            tapCount: bundle.resources.taps.count,
            mutedTapCount: bundle.resources.mutedTaps.count,
            hasAggregate: bundle.resources.aggregate != nil,
            hasIOProc: bundle.resources.ioProc != nil
        )
    }

    @available(macOS 14.2, *)
    func cleanupOwnedObjects(
        using hardware: any AudioTapHardware
    ) -> AudioOwnedObjectCleanupResult {
        let discovery: AudioOwnedObjectDiscovery
        do {
            discovery = try hardware.ownedObjects()
        } catch {
            return AudioOwnedObjectCleanupResult(
                failures: [teardownFailure(
                    from: error,
                    fallbackOperation: .getData,
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    processObjectID: nil
                )],
                hasVerifiedOrphans: false,
                didProgress: false
            )
        }

        let ownedObjects = CoreAudioTapHardware.ownedOrphans(in: discovery.objects)
        let enumeratedIdentities = Set(ownedObjects.map(Self.ownedInstanceIdentity))
        successfullyDestroyedOwnedIdentities.formIntersection(enumeratedIdentities)

        let activeObjectIDs = activeOwnedObjectIDs()
        let verifiedOrphans = ownedObjects
            .filter { activeObjectIDs.contains($0.id) == false }
            .filter { bundleRepresents($0) == false }
        let candidates = verifiedOrphans.filter {
            successfullyDestroyedOwnedIdentities.contains(
                Self.ownedInstanceIdentity($0)
            ) == false
        }
            .sorted(by: Self.ownedObjectComesBefore)

        var failures = discovery.failures
        var didProgress = false
        for object in candidates {
            let operation = Self.destroyOperation(for: object)
            let status = hardware.destroyOwnedObject(object)
            if status == noErr {
                successfullyDestroyedOwnedIdentities.insert(
                    Self.ownedInstanceIdentity(object)
                )
                didProgress = true
                continue
            }

            failures.append(AudioTeardownFailure(
                processObjectID: nil,
                operation: operation,
                objectID: object.id,
                status: status
            ))
        }
        return AudioOwnedObjectCleanupResult(
            failures: failures,
            hasVerifiedOrphans: verifiedOrphans.isEmpty == false,
            didProgress: didProgress
        )
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

    func refreshCleanupRetention() {
        if bundles.isEmpty == false || orphanCleanupPending {
            cleanupRetention = self
        } else {
            cleanupRetention = nil
        }
    }

    func releaseOwnershipIfTerminal() {
        guard isDraining,
              sessions.isEmpty,
              bundles.isEmpty,
              orphanCleanupPending == false,
              pendingRetryScheduleID == nil,
              isRetryPassRunning == false else { return }
        ownershipLease = nil
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
        guard let failed = publishSnapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: .failed,
            error: error,
            token: token
        ) else {
            return snapshot(
                processObjectID: processObjectID,
                generation: generation,
                state: .failed,
                error: .routeSuperseded,
                token: token
            )
        }
        return failed
    }

    func publishSnapshot(
        processObjectID: AudioObjectID,
        generation: UInt64,
        state: ProcessTapSessionState,
        error: ProcessTapEngineError?,
        token: ProcessTapGenerationRegistry.Token
    ) -> ProcessTapSessionSnapshot? {
        #if DEBUG
        if let supersession = snapshotPublishSupersessionForTesting {
            snapshotPublishSupersessionForTesting = nil
            _ = generations.register(
                processObjectID: supersession.processObjectID,
                generation: supersession.generation
            )
        }
        #endif
        guard generations.isCurrent(token) else { return nil }
        let snapshot = snapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: state,
            error: error,
            token: token
        )
        onSessionSnapshot(snapshot)
        sessionSnapshotContinuation.yield(snapshot)
        return snapshot
    }

    func snapshot(
        processObjectID: AudioObjectID,
        generation: UInt64,
        state: ProcessTapSessionState,
        error: ProcessTapEngineError?,
        token: ProcessTapGenerationRegistry.Token
    ) -> ProcessTapSessionSnapshot {
        token.commandContext.snapshot(
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
        if case .readFailed(let status) = error as? AudioIOProcStreamUsageError {
            return map(operation: .getData, status: status)
        }
        if error is CoreAudioTapHardware.ValidationError
            || error is AudioAggregateTopologyError
            || error is AudioIOProcStreamUsageError {
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

    func verifyMuteState(
        _ expected: AudioTapMuteState,
        for tap: AudioTapResource,
        using hardware: any AudioTapHardware
    ) throws {
        guard try hardware.readMuteState(for: tap) == expected else {
            throw AudioHALError(
                operation: .getData,
                objectID: tap.objectID,
                address: AudioHALPropertyAddress(
                    selector: kAudioTapPropertyDescription
                ),
                reason: .missingValue
            )
        }
    }

    static func isCacheableRuntimeRejection(_ error: Swift.Error) -> Bool {
        if error is AudioAggregateTopologyError {
            return true
        }
        guard let usageError = error as? AudioIOProcStreamUsageError else {
            return false
        }
        switch usageError {
        case .propertyMissing,
             .propertyNotSettable,
             .writeFailed,
             .byteCountMismatch,
             .ioProcMismatch,
             .streamCountMismatch,
             .flagsMismatch:
            return true
        case .readFailed:
            return false
        }
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
    enum State: Equatable {
        case preparing
        case active
        case retainedBundle
        case released
    }

    enum Stage: Equatable {
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

private struct AudioAcquisitionProgress: Equatable {
    let state: AudioAcquisitionBundle.State
    let stage: AudioAcquisitionBundle.Stage
    let tapCount: Int
    let mutedTapCount: Int
    let hasAggregate: Bool
    let hasIOProc: Bool
}

private struct AudioOwnedObjectCleanupResult {
    let failures: [AudioTeardownFailure]
    let hasVerifiedOrphans: Bool
    let didProgress: Bool

    var shouldRetry: Bool {
        failures.isEmpty == false || hasVerifiedOrphans
    }
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

private final class ProcessTapCommandContext: @unchecked Sendable {
    let commandSequence: UInt64
    private var nextEmissionOrdinal: UInt64 = 0

    init(commandSequence: UInt64) {
        self.commandSequence = commandSequence
    }

    func snapshot(
        processObjectID: AudioObjectID,
        generation: UInt64,
        state: ProcessTapSessionState,
        error: ProcessTapEngineError?
    ) -> ProcessTapSessionSnapshot {
        precondition(
            nextEmissionOrdinal < UInt64.max,
            "Process tap snapshot ordinal exhausted"
        )
        let snapshot = ProcessTapSessionSnapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: state,
            error: error,
            commandSequence: commandSequence,
            emissionOrdinal: nextEmissionOrdinal
        )
        nextEmissionOrdinal += 1
        return snapshot
    }
}

private final class ProcessTapGenerationRegistry: @unchecked Sendable {
    struct Token: Equatable, Sendable {
        let processObjectID: AudioObjectID
        let generation: UInt64
        let sequence: UInt64
        let allEpoch: UInt64
        let commandContext: ProcessTapCommandContext

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.processObjectID == rhs.processObjectID
                && lhs.generation == rhs.generation
                && lhs.sequence == rhs.sequence
                && lhs.allEpoch == rhs.allEpoch
        }
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
        precondition(
            nextSequence < UInt64.max,
            "Process tap command sequence exhausted"
        )
        nextSequence += 1
        let token = Token(
            processObjectID: processObjectID,
            generation: generation,
            sequence: nextSequence,
            allEpoch: allEpoch,
            commandContext: ProcessTapCommandContext(
                commandSequence: nextSequence
            )
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
