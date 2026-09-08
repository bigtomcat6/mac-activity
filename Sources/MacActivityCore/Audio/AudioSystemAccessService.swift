import CoreAudio
import Foundation

public protocol AudioSystemAccessChecking: AnyObject, Sendable {
    func checkAccess() async -> AudioSystemAccessResult
    func drainRetainedResources() async
    func shutdown() async
}

public enum AudioSystemAccessResult: Equatable, Sendable {
    case available
    case permissionRequired(OSStatus)
    case otherFailure(AudioSystemAccessFailure)
    // A terminal service never starts another Core Audio access probe.
    case shutdown
}

public enum AudioSystemAccessFailure: Equatable, Sendable {
    case unsupported
    case operationFailed(AudioHALError)
    case inputTopologyUnavailable(AudioHALError?)
    case cleanupFailed([AudioTeardownFailure])
}

protocol AudioSystemAccessRetryCancellation: AnyObject, Sendable {
    func cancel()
}

protocol AudioSystemAccessRetryScheduling: Sendable {
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any AudioSystemAccessRetryCancellation
}

private final class TaskAudioSystemAccessRetryScheduler: AudioSystemAccessRetryScheduling,
    @unchecked Sendable {
    private final class Cancellation: AudioSystemAccessRetryCancellation, @unchecked Sendable {
        private let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }

        func cancel() {
            task.cancel()
        }
    }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any AudioSystemAccessRetryCancellation {
        let delay = max(0, delay.isFinite ? delay : 1)
        let task = Task.detached(priority: .utility) {
            let nanoseconds = UInt64(delay * 1_000_000_000)
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            } else {
                await Task.yield()
            }
            guard Task.isCancelled == false else { return }
            action()
        }
        return Cancellation(task: task)
    }
}

public actor AudioSystemAccessService: AudioSystemAccessChecking {
    private struct Configuration: @unchecked Sendable {
        let hal: AudioHALClient
        let isSupported: Bool
        let uuid: UUID
        let topologyPollCount: Int
        let cleanupPollCount: Int
        let pollInterval: TimeInterval
    }

    private struct Tap: Sendable {
        let objectID: AudioObjectID
        let uuid: UUID
    }

    private struct Aggregate: Sendable {
        let objectID: AudioDeviceID
        let uid: String
    }

    private enum CleanupStage: Sendable {
        case stopIOProc
        case destroyIOProc
        case destroyAggregate
        case waitForAggregateDisappearance
        case destroyTap
        case released
    }

    private struct Resources: @unchecked Sendable {
        var tap: Tap?
        var aggregate: Aggregate?
        var ioProcID: AudioDeviceIOProcID?
        var didStartIOProc = false
        var cleanupStage: CleanupStage = .stopIOProc
    }

    private struct Outcome: @unchecked Sendable {
        let result: AudioSystemAccessResult
        let retainedResources: Resources?
    }

    private enum InputTopologyReadiness {
        case ready
        case unavailable(AudioHALError?)
    }

    private enum ResourceIdentity {
        case owned
        case absentOrReplaced
        case uncertain(AudioTeardownFailure)
    }

    private let hal: AudioHALClient
    private let isSupported: Bool
    private let uuidProvider: @Sendable () -> UUID
    private let topologyPollCount: Int
    private let cleanupPollCount: Int
    private let pollInterval: TimeInterval
    private let cleanupRetryDelay: TimeInterval
    private let cleanupRetryScheduler: any AudioSystemAccessRetryScheduling
    private var retainedResources: Resources?
    private var currentCheck: (id: UUID, task: Task<Outcome, Never>)?
    private var currentCleanup: (id: UUID, task: Task<Resources?, Never>)?
    private var cleanupRetry: (id: UUID, cancellation: any AudioSystemAccessRetryCancellation)?
    private var cleanupRetention: AudioSystemAccessService?
    private var isShuttingDown = false
    #if DEBUG
    private var shutdownEntryObserver: (@Sendable () -> Void)?
    private var didCompleteShutdownForTesting = false
    #endif

    public init(availability: AudioFeatureAvailability = .current) {
        self.init(
            hal: .system,
            isSupported: availability.supportsProcessControls,
            uuidProvider: { UUID() },
            cleanupRetryDelay: 1,
            cleanupRetryScheduler: nil
        )
    }

    init(
        hal: AudioHALClient,
        isSupported: Bool,
        uuidProvider: @escaping @Sendable () -> UUID,
        topologyPollCount: Int = 200,
        cleanupPollCount: Int = 200,
        pollInterval: TimeInterval = 0.01,
        cleanupRetryDelay: TimeInterval = 1,
        cleanupRetryScheduler: (any AudioSystemAccessRetryScheduling)? = nil
    ) {
        self.hal = hal
        self.isSupported = isSupported
        self.uuidProvider = uuidProvider
        self.topologyPollCount = topologyPollCount
        self.cleanupPollCount = cleanupPollCount
        self.pollInterval = pollInterval
        self.cleanupRetryDelay = max(0, cleanupRetryDelay.isFinite ? cleanupRetryDelay : 1)
        self.cleanupRetryScheduler = cleanupRetryScheduler ?? TaskAudioSystemAccessRetryScheduler()
    }

    deinit {
        cleanupRetry?.cancellation.cancel()
    }

    public func checkAccess() async -> AudioSystemAccessResult {
        while true {
            guard isShuttingDown == false else { return .shutdown }
            if let currentCheck {
                return await finish(currentCheck.task, id: currentCheck.id)
            }
            if let currentCleanup {
                await finishCleanup(currentCleanup.task, id: currentCleanup.id)
                continue
            }

            let id = UUID()
            let configuration = Configuration(
                hal: hal,
                isSupported: isSupported,
                uuid: uuidProvider(),
                topologyPollCount: topologyPollCount,
                cleanupPollCount: cleanupPollCount,
                pollInterval: pollInterval
            )
            let retainedResources = retainedResources
            let task = Task.detached(priority: .userInitiated) {
                Self.run(configuration: configuration, retainedResources: retainedResources)
            }
            currentCheck = (id, task)
            return await finish(task, id: id)
        }
    }

    public func shutdown() async {
        #if DEBUG
        didCompleteShutdownForTesting = false
        defer { didCompleteShutdownForTesting = true }
        #endif
        isShuttingDown = true
        #if DEBUG
        shutdownEntryObserver?()
        #endif
        while true {
            if let currentCheck {
                _ = await finish(currentCheck.task, id: currentCheck.id)
                continue
            }
            if let currentCleanup {
                await finishCleanup(currentCleanup.task, id: currentCleanup.id)
                continue
            }
            break
        }
        await drainRetainedResources()
    }

    public func drainRetainedResources() async {
        while true {
            if let currentCheck {
                _ = await finish(currentCheck.task, id: currentCheck.id)
                continue
            }
            if let currentCleanup {
                await finishCleanup(currentCleanup.task, id: currentCleanup.id)
                return
            }
            guard let retainedResources else { return }

            let id = UUID()
            let configuration = Configuration(
                hal: hal,
                isSupported: isSupported,
                uuid: uuidProvider(),
                topologyPollCount: topologyPollCount,
                cleanupPollCount: cleanupPollCount,
                pollInterval: pollInterval
            )
            let task = Task.detached(priority: .utility) {
                Self.drain(configuration: configuration, retainedResources: retainedResources)
            }
            currentCleanup = (id, task)
            await finishCleanup(task, id: id)
            return
        }
    }

    private func finish(_ task: Task<Outcome, Never>, id: UUID) async -> AudioSystemAccessResult {
        let outcome = await task.value
        guard currentCheck?.id == id else { return outcome.result }
        currentCheck = nil
        updateRetainedResources(outcome.retainedResources)
        return outcome.result
    }

    private func finishCleanup(_ task: Task<Resources?, Never>, id: UUID) async {
        let resources = await task.value
        guard currentCleanup?.id == id else { return }
        currentCleanup = nil
        updateRetainedResources(resources)
    }

    private func updateRetainedResources(_ resources: Resources?) {
        retainedResources = resources
        guard resources != nil else {
            cancelCleanupRetry()
            refreshCleanupRetention()
            return
        }
        refreshCleanupRetention()
        scheduleRetainedResourceCleanup()
    }

    private func scheduleRetainedResourceCleanup() {
        guard retainedResources != nil, cleanupRetry == nil else { return }
        let id = UUID()
        let cancellation = cleanupRetryScheduler.schedule(after: cleanupRetryDelay) { [weak self] in
            Task {
                await self?.retryRetainedResourceCleanup(id: id)
            }
        }
        cleanupRetry = (id, cancellation)
        refreshCleanupRetention()
    }

    private func retryRetainedResourceCleanup(id: UUID) async {
        guard cleanupRetry?.id == id else { return }
        cleanupRetry = nil
        refreshCleanupRetention()
        await drainRetainedResources()
    }

    private func cancelCleanupRetry() {
        cleanupRetry?.cancellation.cancel()
        cleanupRetry = nil
    }

    private func refreshCleanupRetention() {
        if retainedResources != nil || currentCleanup != nil || cleanupRetry != nil {
            cleanupRetention = self
        } else {
            cleanupRetention = nil
        }
    }

    #if DEBUG
    func testingObserveShutdownEntry(_ observer: @escaping @Sendable () -> Void) {
        shutdownEntryObserver = observer
    }

    func testingDidCompleteShutdown() -> Bool {
        didCompleteShutdownForTesting
    }

    func waitUntilIdleForTesting() async {
        while true {
            if let currentCheck {
                _ = await finish(currentCheck.task, id: currentCheck.id)
                continue
            }
            if let currentCleanup {
                await finishCleanup(currentCleanup.task, id: currentCleanup.id)
                continue
            }
            return
        }
    }
    #endif
}

private extension AudioSystemAccessService {
    private static func run(
        configuration: Configuration,
        retainedResources: Resources?
    ) -> Outcome {
        guard configuration.isSupported else {
            return .init(result: .otherFailure(.unsupported), retainedResources: retainedResources)
        }
        guard #available(macOS 14.2, *) else {
            return .init(result: .otherFailure(.unsupported), retainedResources: retainedResources)
        }
        return runSupported(configuration: configuration, retainedResources: retainedResources)
    }

    private static func drain(
        configuration: Configuration,
        retainedResources: Resources
    ) -> Resources? {
        guard configuration.isSupported, #available(macOS 14.2, *) else {
            return retainedResources
        }
        var resources = retainedResources
        return cleanup(&resources, configuration: configuration).isEmpty ? nil : resources
    }

    @available(macOS 14.2, *)
    private static func runSupported(
        configuration: Configuration,
        retainedResources: Resources?
    ) -> Outcome {
        var resources = retainedResources ?? Resources()
        if retainedResources != nil {
            let cleanupFailures = cleanup(&resources, configuration: configuration)
            guard cleanupFailures.isEmpty else {
                return .init(
                    result: .otherFailure(.cleanupFailed(cleanupFailures)),
                    retainedResources: resources
                )
            }
            resources = Resources()
        }

        let result: AudioSystemAccessResult
        do {
            let tapDescription = makeTapDescription(uuid: configuration.uuid)
            let tapObjectID = try configuration.hal.createProcessTap(tapDescription)
            resources.tap = .init(objectID: tapObjectID, uuid: tapDescription.uuid)

            let aggregateUID = AudioRoutePlanner.aggregateUIDPrefix
                + "access.\(configuration.uuid.uuidString)"
            let aggregateObjectID = try configuration.hal.createAggregateDevice(
                aggregateDescription(tapUUID: tapDescription.uuid, uid: aggregateUID)
            )
            resources.aggregate = .init(objectID: aggregateObjectID, uid: aggregateUID)

            let inputTopology = waitForInputTopology(
                aggregateObjectID,
                configuration: configuration
            )
            guard case .ready = inputTopology else {
                let cleanupFailures = cleanup(&resources, configuration: configuration)
                if cleanupFailures.isEmpty == false {
                    return .init(
                        result: .otherFailure(.cleanupFailed(cleanupFailures)),
                        retainedResources: resources
                    )
                }
                let topologyError: AudioHALError?
                if case .unavailable(let error) = inputTopology {
                    topologyError = error
                } else {
                    topologyError = nil
                }
                let topologyResult: AudioSystemAccessResult = topologyError?.status
                    == kAudioDevicePermissionsError
                    ? .permissionRequired(kAudioDevicePermissionsError)
                    : .otherFailure(.inputTopologyUnavailable(topologyError))
                return .init(
                    result: topologyResult,
                    retainedResources: nil
                )
            }

            let ioProcID = try configuration.hal.createIOProc(
                deviceID: aggregateObjectID,
                callback: audioSystemAccessNoopIOProc,
                clientData: nil
            )
            resources.ioProcID = ioProcID
            try configuration.hal.startDevice(deviceID: aggregateObjectID, ioProcID: ioProcID)
            resources.didStartIOProc = true
            result = .available
        } catch let error as AudioHALError {
            result = accessResult(for: error)
        } catch {
            result = .otherFailure(.operationFailed(unknownHALError()))
        }

        let cleanupFailures = cleanup(&resources, configuration: configuration)
        if cleanupFailures.isEmpty == false {
            return .init(
                result: .otherFailure(.cleanupFailed(cleanupFailures)),
                retainedResources: resources
            )
        }
        return .init(result: result, retainedResources: nil)
    }

    @available(macOS 14.2, *)
    private static func makeTapDescription(uuid: UUID) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.uuid = CoreAudioTapHardware.reservedTapUUID(entropy: uuid)
        description.name = "MacActivity Audio Access \(description.uuid.uuidString)"
        if #available(macOS 26.0, *) {
            description.isProcessRestoreEnabled = false
        }
        return description
    }

    @available(macOS 14.2, *)
    private static func aggregateDescription(tapUUID: UUID, uid: String) -> CFDictionary {
        let tap: [String: Any] = [
            kAudioSubTapUIDKey: tapUUID.uuidString,
            kAudioSubTapDriftCompensationKey: false,
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacActivity Audio Access \(tapUUID.uuidString)",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [tap],
        ]
        return description as CFDictionary
    }

    @available(macOS 14.2, *)
    private static func waitForInputTopology(
        _ aggregateObjectID: AudioDeviceID,
        configuration: Configuration
    ) -> InputTopologyReadiness {
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        )
        var lastError: AudioHALError?
        for attempt in 0..<max(1, configuration.topologyPollCount) {
            do {
                let streams = try configuration.hal.readArray(
                    AudioStreamID.self,
                    from: aggregateObjectID,
                    address: address
                )
                if streams.isEmpty == false {
                    return .ready
                }
            } catch let error as AudioHALError {
                lastError = error
            } catch {
                lastError = unknownHALError()
            }
            sleepIfNeeded(configuration.pollInterval, beforeNextAttempt: attempt + 1)
        }
        return .unavailable(lastError)
    }

    @available(macOS 14.2, *)
    private static func cleanup(
        _ resources: inout Resources,
        configuration: Configuration
    ) -> [AudioTeardownFailure] {
        while true {
            switch resources.cleanupStage {
            case .stopIOProc:
                if resources.didStartIOProc,
                   let aggregate = resources.aggregate,
                   let ioProcID = resources.ioProcID {
                    let identity = activeIdentity(
                        objectID: aggregate.objectID,
                        classID: kAudioAggregateDeviceClassID,
                        uid: aggregate.uid,
                        uidSelector: kAudioDevicePropertyDeviceUID,
                        configuration: configuration
                    )
                    switch identity {
                    case .owned:
                        break
                    case .absentOrReplaced:
                        discardAggregateResources(&resources)
                        continue
                    case .uncertain(let failure):
                        return [failure]
                    }
                    do {
                        try configuration.hal.stopDevice(
                            deviceID: aggregate.objectID,
                            ioProcID: ioProcID
                        )
                    } catch {
                        if objectWasAlreadyReleased(error) {
                            discardAggregateResources(&resources)
                            continue
                        }
                        return [teardownFailure(
                            error,
                            operation: .stopDevice,
                            objectID: aggregate.objectID
                        )]
                    }
                    resources.didStartIOProc = false
                }
                resources.cleanupStage = .destroyIOProc

            case .destroyIOProc:
                if let aggregate = resources.aggregate, let ioProcID = resources.ioProcID {
                    let identity = activeIdentity(
                        objectID: aggregate.objectID,
                        classID: kAudioAggregateDeviceClassID,
                        uid: aggregate.uid,
                        uidSelector: kAudioDevicePropertyDeviceUID,
                        configuration: configuration
                    )
                    switch identity {
                    case .owned:
                        break
                    case .absentOrReplaced:
                        discardAggregateResources(&resources)
                        continue
                    case .uncertain(let failure):
                        return [failure]
                    }
                    do {
                        try configuration.hal.destroyIOProc(
                            deviceID: aggregate.objectID,
                            ioProcID: ioProcID
                        )
                    } catch {
                        if objectWasAlreadyReleased(error) {
                            discardAggregateResources(&resources)
                            continue
                        }
                        return [teardownFailure(
                            error,
                            operation: .destroyIOProc,
                            objectID: aggregate.objectID
                        )]
                    }
                    resources.ioProcID = nil
                }
                resources.cleanupStage = .destroyAggregate

            case .destroyAggregate:
                if let aggregate = resources.aggregate {
                    switch activeIdentity(
                        objectID: aggregate.objectID,
                        classID: kAudioAggregateDeviceClassID,
                        uid: aggregate.uid,
                        uidSelector: kAudioDevicePropertyDeviceUID,
                        configuration: configuration
                    ) {
                    case .owned:
                        do {
                            try configuration.hal.destroyAggregateDevice(aggregate.objectID)
                        } catch {
                            if objectWasAlreadyReleased(error) {
                                discardAggregateResources(&resources)
                                continue
                            }
                            return [teardownFailure(
                                error,
                                operation: .destroyAggregate,
                                objectID: aggregate.objectID
                            )]
                        }
                    case .absentOrReplaced:
                        discardAggregateResources(&resources)
                        continue
                    case .uncertain(let failure):
                        return [failure]
                    }
                }
                resources.cleanupStage = .waitForAggregateDisappearance

            case .waitForAggregateDisappearance:
                guard let aggregate = resources.aggregate else {
                    resources.cleanupStage = .destroyTap
                    continue
                }
                for attempt in 0..<max(1, configuration.cleanupPollCount) {
                    switch destroyedIdentity(
                        objectID: aggregate.objectID,
                        classID: kAudioAggregateDeviceClassID,
                        uid: aggregate.uid,
                        uidSelector: kAudioDevicePropertyDeviceUID,
                        configuration: configuration
                    ) {
                    case .absentOrReplaced:
                        resources.aggregate = nil
                        resources.cleanupStage = .destroyTap
                    case .owned:
                        sleepIfNeeded(configuration.pollInterval, beforeNextAttempt: attempt + 1)
                        continue
                    case .uncertain(let failure):
                        return [failure]
                    }
                    break
                }
                if resources.aggregate != nil {
                    return [.init(
                        processObjectID: nil,
                        operation: .destroyAggregate,
                        objectID: aggregate.objectID,
                        status: kAudioHardwareUnspecifiedError
                    )]
                }

            case .destroyTap:
                if let tap = resources.tap {
                    switch activeIdentity(
                        objectID: tap.objectID,
                        classID: kAudioTapClassID,
                        uid: tap.uuid.uuidString,
                        uidSelector: kAudioTapPropertyUID,
                        configuration: configuration
                    ) {
                    case .owned:
                        do {
                            try configuration.hal.destroyProcessTap(tap.objectID)
                        } catch {
                            if objectWasAlreadyReleased(error) { break }
                            return [teardownFailure(
                                error,
                                operation: .destroyTap,
                                objectID: tap.objectID
                            )]
                        }
                    case .absentOrReplaced:
                        break
                    case .uncertain(let failure):
                        return [failure]
                    }
                    resources.tap = nil
                }
                resources.cleanupStage = .released

            case .released:
                return []
            }
        }
    }

    @available(macOS 14.2, *)
    private static func activeIdentity(
        objectID: AudioObjectID,
        classID: AudioClassID,
        uid: String,
        uidSelector: AudioObjectPropertySelector,
        configuration: Configuration
    ) -> ResourceIdentity {
        identity(
            objectID: objectID,
            classID: classID,
            uid: uid,
            uidSelector: uidSelector,
            badObjectMeansAbsent: false,
            configuration: configuration
        )
    }

    @available(macOS 14.2, *)
    private static func destroyedIdentity(
        objectID: AudioObjectID,
        classID: AudioClassID,
        uid: String,
        uidSelector: AudioObjectPropertySelector,
        configuration: Configuration
    ) -> ResourceIdentity {
        identity(
            objectID: objectID,
            classID: classID,
            uid: uid,
            uidSelector: uidSelector,
            badObjectMeansAbsent: true,
            configuration: configuration
        )
    }

    @available(macOS 14.2, *)
    private static func identity(
        objectID: AudioObjectID,
        classID: AudioClassID,
        uid: String,
        uidSelector: AudioObjectPropertySelector,
        badObjectMeansAbsent: Bool,
        configuration: Configuration
    ) -> ResourceIdentity {
        let classAddress = AudioHALPropertyAddress(selector: kAudioObjectPropertyClass)
        guard configuration.hal.hasProperty(objectID: objectID, address: classAddress) else {
            return .absentOrReplaced
        }
        do {
            guard try configuration.hal.readScalar(
                AudioClassID.self,
                from: objectID,
                address: classAddress
            ) == classID else {
                return .absentOrReplaced
            }
            let uidAddress = AudioHALPropertyAddress(selector: uidSelector)
            guard configuration.hal.hasProperty(objectID: objectID, address: uidAddress) else {
                return .uncertain(.init(
                    processObjectID: nil,
                    operation: .getData,
                    objectID: objectID,
                    status: kAudioHardwareUnknownPropertyError
                ))
            }
            return try configuration.hal.readRetainedString(
                from: objectID,
                address: uidAddress
            ) == uid ? .owned : .absentOrReplaced
        } catch {
            let failure = teardownFailure(error, operation: .getData, objectID: objectID)
            if badObjectMeansAbsent, failure.status == kAudioHardwareBadObjectError {
                return .absentOrReplaced
            }
            return .uncertain(failure)
        }
    }

    private static func accessResult(for error: AudioHALError) -> AudioSystemAccessResult {
        if error.status == kAudioDevicePermissionsError {
            return .permissionRequired(kAudioDevicePermissionsError)
        }
        return .otherFailure(.operationFailed(error))
    }

    private static func discardAggregateResources(_ resources: inout Resources) {
        resources.didStartIOProc = false
        resources.ioProcID = nil
        resources.aggregate = nil
        resources.cleanupStage = .destroyTap
    }

    private static func objectWasAlreadyReleased(_ error: Error) -> Bool {
        (error as? AudioHALError)?.status == kAudioHardwareBadObjectError
    }

    private static func teardownFailure(
        _ error: Error,
        operation: AudioHALOperation,
        objectID: AudioObjectID
    ) -> AudioTeardownFailure {
        let error = error as? AudioHALError
        return .init(
            processObjectID: nil,
            operation: error?.operation ?? operation,
            objectID: error?.objectID ?? objectID,
            status: error?.status ?? kAudioHardwareUnspecifiedError
        )
    }

    private static func unknownHALError() -> AudioHALError {
        AudioHALError(
            operation: .startDevice,
            objectID: kAudioObjectUnknown,
            address: nil,
            reason: .status(kAudioHardwareUnspecifiedError)
        )
    }

    private static func sleepIfNeeded(_ interval: TimeInterval, beforeNextAttempt attempt: Int) {
        guard interval > 0, attempt > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }
}

@available(macOS 14.2, *)
private let audioSystemAccessNoopIOProc: AudioDeviceIOProc = { _, _, _, _, _, _, _ in
    noErr
}
