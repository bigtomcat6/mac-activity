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
    private var lifetimeLease: ProcessTapVolumeEngine?

    public convenience init(availability: AudioFeatureAvailability = .current) {
        self.init(
            optionalHardware: nil,
            availability: availability,
            queue: DispatchQueue(
                label: "com.how.macactivity.audio.process-tap",
                qos: .userInitiated
            ),
            retryLedgerLimit: 32,
            onSessionSnapshot: { _ in }
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
                  let hardware
            else {
                sessions.removeAll()
                retryLedger.removeAll()
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
                  let hardware
            else {
                return []
            }
            retryOrphans(using: hardware)
            return retryFailures()
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
            try ensureCurrent(token)

            try hardware.waitUntilReady(
                aggregate,
                deadline: .now() + Self.preparationTimeout,
                isCancelled: { [generations] in
                    generations.isCurrent(token) == false
                }
            )
            try ensureCurrent(token)

            let layout = try hardware.readAggregateLayout(
                aggregate,
                plan: plan,
                taps: resources.taps
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
                onSessionSnapshot(running)
            }
            guard installed else {
                throw ProcessTapPreparationAbort(.routeSuperseded)
            }
            return running
        } catch {
            resources.context?.setOutputGateOpen(false)
            let preparationError = map(error)
            _ = teardown(resources, using: hardware)
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
        guard session.generation == generation else {
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
            do {
                try hardware.setMuteState(.unmuted, for: tap)
            } catch {
                let failure = teardownFailure(
                    from: error,
                    fallbackOperation: .setData,
                    objectID: tap.objectID,
                    processObjectID: resources.processObjectID
                )
                failures.append(failure)
                addRetry(
                    failure: failure,
                    payload: .setTapUnmuted(tap)
                )
            }
        }

        if let ioProc = resources.ioProc,
           let context = resources.context {
            recordTeardownStatus(
                hardware.stop(ioProc),
                operation: .stopDevice,
                objectID: ioProc.aggregateDeviceID,
                processObjectID: resources.processObjectID,
                payload: .stop(ioProc, context),
                failures: &failures
            )
            recordTeardownStatus(
                hardware.destroyIOProc(ioProc),
                operation: .destroyIOProc,
                objectID: ioProc.aggregateDeviceID,
                processObjectID: resources.processObjectID,
                payload: .destroyIOProc(ioProc, context),
                failures: &failures
            )
        }

        if let aggregate = resources.aggregate {
            recordTeardownStatus(
                hardware.destroyAggregate(aggregate),
                operation: .destroyAggregate,
                objectID: aggregate.objectID,
                processObjectID: resources.processObjectID,
                payload: .destroyAggregate(aggregate),
                failures: &failures
            )
        }

        for tap in resources.taps.reversed() {
            let status = hardware.destroyTap(tap)
            recordTeardownStatus(
                status,
                operation: .destroyTap,
                objectID: tap.objectID,
                processObjectID: resources.processObjectID,
                payload: .destroyTap(tap),
                failures: &failures
            )
            if status == noErr {
                retryLedger.removeValue(forKey: AudioTeardownRetryKey(
                    operation: .setData,
                    objectID: tap.objectID
                ))
            }
        }
        return failures
    }

    func recordTeardownStatus(
        _ status: OSStatus,
        operation: AudioHALOperation,
        objectID: AudioObjectID,
        processObjectID: AudioObjectID?,
        payload: AudioTeardownRetryPayload,
        failures: inout [AudioTeardownFailure]
    ) {
        let key = AudioTeardownRetryKey(
            operation: operation,
            objectID: objectID
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
        addRetry(failure: failure, payload: payload)
    }

    func addRetry(
        failure: AudioTeardownFailure,
        payload: AudioTeardownRetryPayload
    ) {
        let key = AudioTeardownRetryKey(
            operation: failure.operation,
            objectID: failure.objectID
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
        let entries = retryLedger.values.sorted {
            if $0.key.priority == $1.key.priority {
                return $0.key.objectID < $1.key.objectID
            }
            return $0.key.priority < $1.key.priority
        }
        for entry in entries {
            let retryStatus: OSStatus
            switch entry.payload {
            case .setTapUnmuted(let tap):
                do {
                    try hardware.setMuteState(.unmuted, for: tap)
                    retryStatus = noErr
                } catch {
                    retryStatus = status(from: error)
                }
            case .stop(let ioProc, _):
                retryStatus = hardware.stop(ioProc)
            case .destroyIOProc(let ioProc, _):
                retryStatus = hardware.destroyIOProc(ioProc)
            case .destroyAggregate(let aggregate):
                retryStatus = hardware.destroyAggregate(aggregate)
            case .destroyTap(let tap):
                retryStatus = hardware.destroyTap(tap)
            }

            if retryStatus == noErr {
                retryLedger.removeValue(forKey: entry.key)
                if entry.key.operation == .destroyTap {
                    retryLedger.removeValue(forKey: AudioTeardownRetryKey(
                        operation: .setData,
                        objectID: entry.key.objectID
                    ))
                }
            } else {
                var updated = entry
                updated.status = retryStatus
                retryLedger[entry.key] = updated
            }
        }
    }

    func retryFailures() -> [AudioTeardownFailure] {
        retryLedger.values.map { entry in
            AudioTeardownFailure(
                processObjectID: entry.processObjectID,
                operation: entry.key.operation,
                objectID: entry.key.objectID,
                status: entry.status
            )
        }.sorted {
            if $0.operation.rawValue == $1.operation.rawValue {
                return $0.objectID < $1.objectID
            }
            return $0.operation.rawValue < $1.operation.rawValue
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
        generations.performIfCurrent(token) { [onSessionSnapshot] in
            onSessionSnapshot(snapshot)
        }
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
            }
        }
        if let halError = error as? AudioHALError {
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
    var ioProc: AudioIOProcResource?
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

    init(operation: AudioHALOperation, objectID: AudioObjectID) {
        operationName = operation.rawValue
        self.objectID = objectID
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

    var retainsDSPContext: Bool {
        switch self {
        case .stop, .destroyIOProc:
            true
        case .setTapUnmuted, .destroyAggregate, .destroyTap:
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
