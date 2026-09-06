import CoreAudio
import Foundation
import MacActivityCore

@testable import MacActivityApp

enum FixtureError: Error {
    case writeFailed
}

@MainActor
final class CoordinatorFixture {
    let deviceProvider = DeviceProviderFake()
    let processProvider = ProcessProviderFake()
    let monitor = MonitorFake()
    let systemAudioAccessChecker: any AudioSystemAccessChecking
    let engine: EngineFake
    let store = PreferencesStoreFake()
    let lifecycle = LifecycleRecorder()
    let coordinator: AudioControlCoordinator

    init(
        availability: AudioFeatureAvailability,
        bundleIdentifier: String? = "com.example.music",
        savedProfiles: [String: AudioProcessProfile] = [:],
        engine: EngineFake = EngineFake(),
        planner: AudioRoutePlanner? = nil,
        systemAudioAccessChecker: any AudioSystemAccessChecking = AudioSystemAccessCheckerFake()
    ) {
        self.engine = engine
        self.systemAudioAccessChecker = systemAudioAccessChecker
        processProvider.bundleIdentifier = bundleIdentifier
        store.savedPreferences.audioProcessProfiles = savedProfiles
        monitor.lifecycle = lifecycle
        engine.lifecycle = lifecycle
        deviceProvider.lifecycle = lifecycle
        processProvider.lifecycle = lifecycle
        let preferences = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )
        let planner = planner ?? AudioRoutePlanner()
        coordinator = AudioControlCoordinator(
            availability: availability,
            deviceProvider: deviceProvider,
            processProvider: processProvider,
            routeDeviceProvider: deviceProvider,
            monitor: monitor,
            planner: planner,
            engine: engine,
            preferences: preferences,
            systemAudioAccessChecker: systemAudioAccessChecker
        )
    }

    func emit(_ changes: Set<AudioSystemChange>) async {
        let token = monitor.emit(changes)
        await coordinator.testingWaitForReconciliation(token: token)
    }

    func emitEngine(_ snapshot: ProcessTapSessionSnapshot) async {
        engine.emit(snapshot)
        await coordinator.testingWaitForEngineSnapshot(
            processObjectID: snapshot.processObjectID,
            order: snapshot.order
        )
    }

}

@MainActor
final class AudioControlComponentFixture {
    let bundleIdentifier = "com.example.Player"
    let player: AudioProcessEntry
    let coordinator: AudioControlCoordinator
    let monitor: FakeAudioSystemMonitor
    let engine: RecordingProcessTapEngine
    let preferences: PreferencesController
    let store: PreferencesStoreFake
    let lifecycle: LifecycleRecorder
    let deviceProvider: DeviceProviderFake
    let processProvider: ProcessProviderFake
    let systemAudioAccessChecker: AudioSystemAccessCheckerFake

    private var pendingReconciliationTokens: [UInt64] = []

    var devices: [AudioOutputDeviceSnapshot] {
        get { deviceProvider.outputSnapshots ?? [] }
        set { deviceProvider.outputSnapshots = newValue }
    }

    var routeDevices: [AudioRouteDevice] {
        get { deviceProvider.routeDescriptors }
        set { deviceProvider.routeDescriptors = newValue }
    }

    var processes: [AudioProcessEntry] {
        get { processProvider.processes ?? [] }
        set { processProvider.processes = newValue }
    }

    init(
        savedProfile: AudioProcessProfile? = nil,
        systemAudioAccessChecker: AudioSystemAccessCheckerFake = .init()
    ) {
        let player = AudioProcessEntry(
            processObjectID: 11,
            processIdentifier: 101,
            name: "Player",
            bundleIdentifier: bundleIdentifier,
            bundleURL: nil,
            outputDeviceIDs: [10]
        )
        let deviceProvider = DeviceProviderFake()
        let routeDevices = [
            DeviceProviderFake.makeRouteDevice(id: 10, uid: "BuiltIn"),
            DeviceProviderFake.makeRouteDevice(id: 20, uid: "USB"),
            DeviceProviderFake.makeRouteDevice(id: 30, uid: "HDMI"),
        ]
        deviceProvider.routeDescriptors = routeDevices
        deviceProvider.outputSnapshots = routeDevices.map {
            AudioOutputDeviceSnapshot(
                id: $0.uid,
                objectID: $0.objectID,
                name: $0.name,
                volume: .value(0.5, isWritable: true),
                mute: .value(false, isWritable: true)
            )
        }
        let processProvider = ProcessProviderFake()
        processProvider.processes = [player]
        processProvider.bundleIdentifier = bundleIdentifier
        let monitor = FakeAudioSystemMonitor()
        let engine = RecordingProcessTapEngine()
        let store = PreferencesStoreFake()
        if let savedProfile {
            store.savedPreferences.audioProcessProfiles[bundleIdentifier] = savedProfile
        }
        let lifecycle = LifecycleRecorder()
        monitor.lifecycle = lifecycle
        engine.lifecycle = lifecycle
        deviceProvider.lifecycle = lifecycle
        processProvider.lifecycle = lifecycle
        let preferences = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        self.player = player
        self.deviceProvider = deviceProvider
        self.processProvider = processProvider
        self.systemAudioAccessChecker = systemAudioAccessChecker
        self.monitor = monitor
        self.engine = engine
        self.store = store
        self.lifecycle = lifecycle
        self.preferences = preferences
        coordinator = AudioControlCoordinator(
            availability: .supported,
            deviceProvider: deviceProvider,
            processProvider: processProvider,
            routeDeviceProvider: deviceProvider,
            monitor: monitor,
            planner: AudioRoutePlanner(),
            engine: engine,
            preferences: preferences,
            systemAudioAccessChecker: systemAudioAccessChecker
        )
    }

    func start() async {
        await coordinator.start()
        await coordinator.testingWaitUntilIdle()
    }

    func emit(_ changes: Set<AudioSystemChange>) {
        let token = monitor.emit(changes)
        if token > 0 { pendingReconciliationTokens.append(token) }
    }

    func finishPendingCommands() async {
        let tokens = pendingReconciliationTokens
        pendingReconciliationTokens.removeAll()
        for token in tokens {
            await coordinator.testingWaitForReconciliation(token: token)
        }
        await coordinator.testingWaitUntilIdle()
    }

    func disconnect(uid: String) {
        deviceProvider.setAlive(false, uid: uid)
    }

    func reconnect(_ device: AudioRouteDevice) {
        guard let index = routeDevices.firstIndex(where: { $0.uid == device.uid }) else {
            preconditionFailure("Component fixture can reconnect only a known device UID")
        }
        routeDevices[index] = device
    }

    func replaceProcess(oldObjectID: AudioObjectID, with replacement: AudioProcessEntry) {
        processes = processes.map { process in
            process.processObjectID == oldObjectID ? replacement : process
        }
    }

    func changeSource(to uid: String) {
        guard let objectID = routeDevices.first(where: { $0.uid == uid })?.objectID else {
            return
        }
        processes = processes.map { process in
            AudioProcessEntry(
                processObjectID: process.processObjectID,
                processIdentifier: process.processIdentifier,
                name: process.name,
                bundleIdentifier: process.bundleIdentifier,
                bundleURL: process.bundleURL,
                outputDeviceIDs: [objectID]
            )
        }
    }

    func makePlayer(objectID: AudioObjectID) -> AudioProcessEntry {
        AudioProcessEntry(
            processObjectID: objectID,
            processIdentifier: player.processIdentifier,
            name: player.name,
            bundleIdentifier: bundleIdentifier,
            bundleURL: nil,
            outputDeviceIDs: player.outputDeviceIDs
        )
    }

    func profile(
        volume: Double = 1,
        isMuted: Bool = false,
        route: AudioRouteMode = .followOriginal
    ) -> AudioProcessProfile {
        AudioProcessProfile(
            bundleIdentifier: bundleIdentifier,
            volume: volume,
            isMuted: isMuted,
            route: route
        )
    }

}

extension AudioFeatureAvailability {
    static let unsupported = AudioFeatureAvailability(
        operatingSystemVersion: .init(majorVersion: 14, minorVersion: 1, patchVersion: 0)
    )
    static let supported = AudioFeatureAvailability(
        operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0)
    )
}

@MainActor
final class DeviceProviderFake: AudioDeviceControlProviding, AudioRouteDeviceProviding {
    enum Write: Equatable {
        case volume(Double)
        case mute(Bool)
    }

    var volumeWriteError: Error?
    var muteWriteError: Error?
    var confirmedMute = false
    var confirmedVolume = 0.5
    var snapshotVolume = 0.5
    var snapshotMute = false
    private(set) var writes: [Write] = []
    private(set) var volumeWrites: [Double] = []
    private(set) var muteWrites: [Bool] = []
    var lifecycle: LifecycleRecorder?
    var onVolumeWrite: (@MainActor () -> Void)?
    var onMuteWrite: (@MainActor () -> Void)?
    var onRouteRead: (@MainActor () -> Void)?
    var routeReadError: Error?
    var outputSnapshotsError: Error?
    var outputSnapshots: [AudioOutputDeviceSnapshot]?

    var routeDescriptors: [AudioRouteDevice] = [
        makeRouteDevice(id: 10, uid: "BuiltIn"),
        makeRouteDevice(id: 20, uid: "USB"),
    ]

    func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot] {
        lifecycle?.events.append("devices.read")
        if let outputSnapshotsError { throw outputSnapshotsError }
        return outputSnapshots ?? [.init(
            id: "BuiltIn",
            objectID: 10,
            name: "Speakers",
            volume: .value(snapshotVolume, isWritable: true),
            mute: .value(snapshotMute, isWritable: true)
        )]
    }

    func outputDeviceSnapshot(forUID uid: String) throws -> AudioOutputDeviceSnapshot {
        let snapshots = try outputDeviceSnapshots()
        return snapshots.first(where: { $0.id == uid }) ?? snapshots[0]
    }

    func writeVolume(_ volume: Double, forUID uid: String) throws -> Double {
        writes.append(.volume(volume))
        volumeWrites.append(volume)
        onVolumeWrite?()
        if let volumeWriteError { throw volumeWriteError }
        return confirmedVolume
    }
    func writeMute(_ isMuted: Bool, forUID uid: String) throws -> Bool {
        writes.append(.mute(isMuted))
        muteWrites.append(isMuted)
        onMuteWrite?()
        if let muteWriteError { throw muteWriteError }
        return confirmedMute
    }
    func routeDevices() throws -> [AudioRouteDevice] {
        lifecycle?.events.append("routes.read")
        onRouteRead?()
        if let routeReadError { throw routeReadError }
        return routeDescriptors
    }

    func setAlive(_ isAlive: Bool, uid: String) {
        routeDescriptors = routeDescriptors.map { device in
            guard device.uid == uid else { return device }
            return AudioRouteDevice(
                objectID: device.objectID,
                uid: device.uid,
                name: device.name,
                isAlive: isAlive,
                isAggregate: device.isAggregate,
                aggregateSubdeviceUIDs: device.aggregateSubdeviceUIDs,
                inputStreams: device.inputStreams,
                outputStreams: device.outputStreams,
                clockDomain: device.clockDomain,
                transportType: device.transportType,
                modelUID: device.modelUID,
                driverIdentity: device.driverIdentity,
                aggregateComposition: device.aggregateComposition
            )
        }
    }

    func removeRouteDevice(uid: String) {
        routeDescriptors.removeAll { $0.uid == uid }
    }

    static func makeRouteDevice(id: AudioObjectID, uid: String) -> AudioRouteDevice {
        AudioRouteDevice(
            objectID: id,
            uid: uid,
            name: uid,
            isAlive: true,
            isAggregate: false,
            aggregateSubdeviceUIDs: [],
            outputStreams: [.init(
                streamObjectID: id * 100,
                streamIndex: 0,
                format: .init(
                    sampleRate: 48_000,
                    channelCount: 2,
                    formatID: kAudioFormatLinearPCM,
                    formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                    bitsPerChannel: 32,
                    interleaving: .interleaved
                )
            )],
            clockDomain: 100,
            transportType: kAudioDeviceTransportTypeBuiltIn,
            modelUID: "model.\(uid)",
            driverIdentity: .init(plugInBundleID: "driver.\(uid)", availableVersion: nil)
        )
    }
}

@MainActor
final class ProcessProviderFake: AudioProcessProviding {
    private(set) var callCount = 0
    private(set) var discoveredProcessObjectIDs: Set<AudioObjectID> = []
    var bundleIdentifier: String? = "com.example.music"
    var processes: [AudioProcessEntry]?
    var scriptedProcesses: [[AudioProcessEntry]] = []
    var scriptedDiscoveredProcessObjectIDs: [Set<AudioObjectID>] = []
    var lifecycle: LifecycleRecorder?

    func audibleOutputProcesses() -> [AudioProcessEntry] {
        callCount += 1
        lifecycle?.events.append("processes.read")
        let result: [AudioProcessEntry]
        if scriptedProcesses.isEmpty == false {
            result = scriptedProcesses.removeFirst()
        } else {
            result = processes ?? [.init(
                processObjectID: 11,
                processIdentifier: 101,
                name: "Music",
                bundleIdentifier: bundleIdentifier,
                bundleURL: nil,
                outputDeviceIDs: [10]
            )]
        }
        discoveredProcessObjectIDs = scriptedDiscoveredProcessObjectIDs.isEmpty
            ? Set(result.map(\.processObjectID))
            : scriptedDiscoveredProcessObjectIDs.removeFirst()
        return result
    }
}

extension AudioProcessEntry {
    static func music(
        objectID: AudioObjectID,
        outputDeviceIDs: [AudioDeviceID] = [10]
    ) -> AudioProcessEntry {
        .init(
            processObjectID: objectID,
            processIdentifier: 101,
            name: "Music",
            bundleIdentifier: "com.example.music",
            bundleURL: nil,
            outputDeviceIDs: outputDeviceIDs
        )
    }
}

final class FakeAudioSystemMonitor: AudioSystemMonitoring, @unchecked Sendable {
    struct Observation: Equatable {
        let deviceIDs: Set<AudioDeviceID>
        let processObjectIDs: Set<AudioObjectID>
    }

    let changes: AsyncStream<Set<AudioSystemChange>>
    private let continuation: AsyncStream<Set<AudioSystemChange>>.Continuation
    var lifecycle: LifecycleRecorder?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var observedDeviceIDs: Set<AudioDeviceID> = []
    private(set) var observedProcessObjectIDs: Set<AudioObjectID> = []
    private(set) var observationCalls: [Observation] = []
    var startError: Error?
    var observationError: Error?
    var changesOnNextObservation: Set<AudioSystemChange>?
    private var isStarted = false
    private var nextEmissionToken: UInt64 = 0

    init() {
        let stream = AsyncStream<Set<AudioSystemChange>>.makeStream()
        changes = stream.stream
        continuation = stream.continuation
    }

    func start() throws {
        startCount += 1
        lifecycle?.events.append("monitor.start")
        if let startError { throw startError }
        isStarted = true
    }
    func updateObservedObjects(
        deviceIDs: Set<AudioDeviceID>,
        processObjectIDs: Set<AudioObjectID>
    ) throws {
        lifecycle?.events.append("monitor.observe")
        if let observationError { throw observationError }
        observedDeviceIDs = deviceIDs
        observedProcessObjectIDs = processObjectIDs
        observationCalls.append(.init(
            deviceIDs: deviceIDs,
            processObjectIDs: processObjectIDs
        ))
        if let changesOnNextObservation {
            self.changesOnNextObservation = nil
            _ = emit(changesOnNextObservation)
        }
    }
    func stop() {
        isStarted = false
        stopCount += 1
        lifecycle?.events.append("monitor.stop")
    }
    @discardableResult
    func emit(_ changes: Set<AudioSystemChange>) -> UInt64 {
        guard isStarted else { return 0 }
        nextEmissionToken &+= 1
        continuation.yield(changes)
        return nextEmissionToken
    }
}

typealias MonitorFake = FakeAudioSystemMonitor

final class AudioSystemAccessCheckerFake: AudioSystemAccessChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let gate = ControlledCallGate()
    private var results: [AudioSystemAccessResult]
    private var fallbackResult: AudioSystemAccessResult
    private var checks = 0
    private var drains = 0
    private var shutdowns = 0
    private var isShutdown = false
    private var checkStartObserver: (@Sendable (Int) -> Void)?

    init(results: [AudioSystemAccessResult] = [.available]) {
        self.results = results
        self.fallbackResult = results.last ?? .available
    }

    var checkCount: Int {
        lock.withLock { checks }
    }

    var drainCount: Int {
        lock.withLock { drains }
    }

    var shutdownCount: Int {
        lock.withLock { shutdowns }
    }

    func setResults(_ results: [AudioSystemAccessResult]) {
        lock.withLock {
            self.results = results
            fallbackResult = results.last ?? .available
        }
    }

    func observeCheckStarts(_ observer: @escaping @Sendable (Int) -> Void) {
        lock.withLock { checkStartObserver = observer }
    }

    func checkAccess() async -> AudioSystemAccessResult {
        let check = lock.withLock { () -> (count: Int, observer: (@Sendable (Int) -> Void)?)? in
            guard self.isShutdown == false else { return nil }
            checks += 1
            return (checks, checkStartObserver)
        }
        guard let check else { return .shutdown }
        check.observer?(check.count)
        await gate.enter()
        let result = lock.withLock {
            results.isEmpty ? fallbackResult : results.removeFirst()
        }
        return result
    }

    func drainRetainedResources() async {
        lock.withLock { drains += 1 }
    }

    func shutdown() async {
        lock.withLock {
            shutdowns += 1
            isShutdown = true
        }
        await drainRetainedResources()
    }

    func block() async { await gate.block() }
    func resume() async { await gate.resumeAll() }
}

final class SingleFlightAudioSystemAccessCheckerFake: AudioSystemAccessChecking, @unchecked Sendable {
    private struct Check {
        let id: UUID
        let task: Task<AudioSystemAccessResult, Never>
    }

    private let lock = NSLock()
    private let probeGate = ControlledIndexedCallGate()
    private var results: [AudioSystemAccessResult]
    private var fallbackResult: AudioSystemAccessResult
    private var probes = 0
    private var drains = 0
    private var shutdowns = 0
    private var isShutdown = false
    private var currentCheck: Check?
    private var probeStartObserver: (@Sendable (Int) -> Void)?

    init(results: [AudioSystemAccessResult]) {
        self.results = results
        fallbackResult = results.last ?? .available
    }

    var probeCount: Int {
        lock.withLock { probes }
    }

    var drainCount: Int {
        lock.withLock { drains }
    }

    var shutdownCount: Int {
        lock.withLock { shutdowns }
    }

    func observeProbeStarts(_ observer: @escaping @Sendable (Int) -> Void) {
        lock.withLock { probeStartObserver = observer }
    }

    func checkAccess() async -> AudioSystemAccessResult {
        let check = lock.withLock { () -> Check? in
            guard isShutdown == false else { return nil }
            if let currentCheck { return currentCheck }

            probes += 1
            let result = results.isEmpty ? fallbackResult : results.removeFirst()
            let task = Task.detached { [probeGate, probeStartObserver] in
                await probeGate.enter(probeStartObserver)
                return result
            }
            let check = Check(id: UUID(), task: task)
            currentCheck = check
            return check
        }
        guard let check else { return .shutdown }
        return await finish(check)
    }

    func drainRetainedResources() async {
        lock.withLock { drains += 1 }
    }

    func shutdown() async {
        lock.withLock {
            shutdowns += 1
            isShutdown = true
        }
        await drainRetainedResources()
    }

    func blockProbe(_ probe: Int) async { await probeGate.block(probe) }
    func resumeProbe(_ probe: Int) async { await probeGate.resume(probe) }

    private func finish(_ check: Check) async -> AudioSystemAccessResult {
        let result = await check.task.value
        lock.withLock {
            guard currentCheck?.id == check.id else { return }
            currentCheck = nil
        }
        return result
    }
}

struct RecordingEngineStopCall: Equatable {
    let processObjectID: AudioObjectID
    let generation: UInt64
}

struct RecordingEngineApplyKey: Hashable {
    let processObjectID: AudioObjectID
    let generation: UInt64
}

struct RecordingEngineGainCall: Equatable {
    let processObjectID: AudioObjectID
    let gain: ProcessGainState
}

final class PlannerQueryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func record() {
        lock.withLock { value += 1 }
    }
}

final class RecordingProcessTapEngine: ProcessTapVolumeControlling, @unchecked Sendable {
    private struct PendingStopAllApply {
        let plan: AudioRoutePlan
        let continuation: CheckedContinuation<ProcessTapSessionSnapshot, Never>
    }

    let sessionSnapshots: AsyncStream<ProcessTapSessionSnapshot>
    private let continuation: AsyncStream<ProcessTapSessionSnapshot>.Continuation
    private(set) var applyCount = 0
    private(set) var cleanupCount = 0
    private(set) var prepareRuntimeCount = 0
    private(set) var authorizationAttemptCount = 0
    private(set) var stopAllCount = 0
    private(set) var shutdownCount = 0
    private(set) var plans: [AudioRoutePlan] = []
    private(set) var gains: [ProcessGainState] = []
    private(set) var gainUpdateCalls: [RecordingEngineGainCall] = []
    private(set) var stoppedProcessObjectIDs: [AudioObjectID] = []
    private(set) var stoppedGenerations: [UInt64] = []
    private(set) var stopCalls: [RecordingEngineStopCall] = []
    private(set) var lastProducedSnapshot: ProcessTapSessionSnapshot?
    var nextError: ProcessTapEngineError?
    var scriptedApplyResults: [(ProcessTapSessionState, ProcessTapEngineError?)] = []
    var scriptedApplyResultsByCommand: [
        RecordingEngineApplyKey: (ProcessTapSessionState, ProcessTapEngineError?)
    ] = [:]
    var scriptedStopResults: [(ProcessTapSessionState, ProcessTapEngineError?)] = []
    var scriptedPreparationResults: [ProcessTapRuntimePreparation] = []
    var lifecycle: LifecycleRecorder?
    private var nextCommandSequence: UInt64 = 0
    private let stopGate = ControlledCallGate()
    private let prepareRuntimeGate = ControlledCallGate()
    private let shutdownGate = ControlledCallGate()
    private let applyGate = ControlledIndexedCallGate()
    private let applyReturnGate = ControlledIndexedCallGate()
    private let gainUpdateGate = ControlledIndexedCallGate()
    private var deferredObserverCalls: Set<Int> = []
    private var deferredStopObserverCalls: Set<Int> = []
    private var deferredObservers: [ProcessTapSessionSnapshot] = []
    private var appliesToCancelOnStopAll: Set<Int> = []
    private var pendingStopAllApplies: [PendingStopAllApply] = []
    private var pendingStopAllApplyWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init() {
        let stream = AsyncStream<ProcessTapSessionSnapshot>.makeStream()
        sessionSnapshots = stream.stream
        continuation = stream.continuation
    }

    func apply(plan: AudioRoutePlan, gain: ProcessGainState) async -> ProcessTapSessionSnapshot {
        lifecycle?.events.append("engine.apply")
        applyCount += 1
        let applyCall = applyCount
        authorizationAttemptCount += 1
        plans.append(plan)
        gains.append(gain)
        await applyGate.enter()
        if appliesToCancelOnStopAll.contains(applyCall) {
            return await withCheckedContinuation { continuation in
                pendingStopAllApplies.append(.init(plan: plan, continuation: continuation))
                let ready = pendingStopAllApplyWaiters.filter {
                    pendingStopAllApplies.count >= $0.0
                }
                pendingStopAllApplyWaiters.removeAll {
                    pendingStopAllApplies.count >= $0.0
                }
                ready.forEach { $0.1.resume() }
            }
        }
        let scripted = scriptedApplyResultsByCommand.removeValue(forKey: .init(
            processObjectID: plan.processObjectID,
            generation: plan.generation
        ))
            ?? (scriptedApplyResults.isEmpty
                ? (nextError == nil ? ProcessTapSessionState.running : .failed, nextError)
                : scriptedApplyResults.removeFirst())
        nextCommandSequence += 1
        let snapshot = ProcessTapSessionSnapshot(
            processObjectID: plan.processObjectID,
            generation: plan.generation,
            state: scripted.0,
            error: scripted.1,
            commandSequence: nextCommandSequence,
            emissionOrdinal: 1
        )
        lastProducedSnapshot = snapshot
        if deferredObserverCalls.contains(applyCall) {
            deferredObservers.append(snapshot)
        } else {
            continuation.yield(snapshot)
        }
        await applyReturnGate.enter()
        return snapshot
    }
    func updateGain(_ gain: ProcessGainState, for processObjectID: AudioObjectID) async {
        gainUpdateCalls.append(.init(processObjectID: processObjectID, gain: gain))
        lifecycle?.events.append("engine.updateGain")
        await gainUpdateGate.enter()
    }
    func stop(processObjectID: AudioObjectID, generation: UInt64) async -> ProcessTapSessionSnapshot {
        lifecycle?.events.append("engine.stop")
        stoppedProcessObjectIDs.append(processObjectID)
        stoppedGenerations.append(generation)
        stopCalls.append(.init(processObjectID: processObjectID, generation: generation))
        await stopGate.enter()
        let scripted = scriptedStopResults.isEmpty
            ? (ProcessTapSessionState.idle, nil)
            : scriptedStopResults.removeFirst()
        nextCommandSequence += 1
        let snapshot = ProcessTapSessionSnapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: scripted.0,
            error: scripted.1,
            commandSequence: nextCommandSequence,
            emissionOrdinal: 1
        )
        if deferredStopObserverCalls.contains(stopCalls.count) {
            deferredObservers.append(snapshot)
        } else {
            continuation.yield(snapshot)
        }
        return snapshot
    }
    func stopAll() async {
        stopAllCount += 1
        lifecycle?.events.append("engine.stopAll")
        let pending = pendingStopAllApplies
        pendingStopAllApplies.removeAll()
        for apply in pending {
            nextCommandSequence += 1
            let snapshot = ProcessTapSessionSnapshot(
                processObjectID: apply.plan.processObjectID,
                generation: apply.plan.generation,
                state: .failed,
                error: .routeSuperseded,
                commandSequence: nextCommandSequence,
                emissionOrdinal: 1
            )
            lastProducedSnapshot = snapshot
            continuation.yield(snapshot)
            apply.continuation.resume(returning: snapshot)
        }
    }
    func prepareRuntime() async -> ProcessTapRuntimePreparation {
        prepareRuntimeCount += 1
        lifecycle?.events.append("engine.prepareRuntime")
        await prepareRuntimeGate.enter()
        return scriptedPreparationResults.isEmpty
            ? .ready(cleanupFailures: [])
            : scriptedPreparationResults.removeFirst()
    }
    func shutdown() async {
        shutdownCount += 1
        lifecycle?.events.append("engine.shutdown")
        await shutdownGate.enter()
    }
    var lastAppliedPlan: AudioRoutePlan? { plans.last }
    var lastStopObjectID: AudioObjectID? { stopCalls.last?.processObjectID }
    func emit(_ snapshot: ProcessTapSessionSnapshot) { continuation.yield(snapshot) }
    func blockStops() async { await stopGate.block() }
    func resumeStops() async { await stopGate.resumeAll() }
    func waitUntilStopCount(_ count: Int) async { await stopGate.waitUntilEntered(count) }
    func blockPrepareRuntime() async { await prepareRuntimeGate.block() }
    func resumePrepareRuntime() async { await prepareRuntimeGate.resumeAll() }
    func waitUntilPrepareRuntimeCount(_ count: Int) async {
        await prepareRuntimeGate.waitUntilEntered(count)
    }
    func blockShutdown() async { await shutdownGate.block() }
    func resumeShutdown() async { await shutdownGate.resumeAll() }
    func waitUntilShutdownCount(_ count: Int) async { await shutdownGate.waitUntilEntered(count) }
    func blockApplyCall(_ call: Int) async { await applyGate.block(call) }
    func resumeApplies() async { await applyGate.resumeAll() }
    func waitUntilApplyCount(_ count: Int) async { await applyGate.waitUntilEntered(count) }
    func blockApplyReturn(_ call: Int) async { await applyReturnGate.block(call) }
    func resumeApplyReturns() async { await applyReturnGate.resumeAll() }
    func waitUntilApplyReturnCount(_ count: Int) async {
        await applyReturnGate.waitUntilEntered(count)
    }
    func blockGainUpdateCall(_ call: Int) async { await gainUpdateGate.block(call) }
    func resumeGainUpdates() async { await gainUpdateGate.resumeAll() }
    func waitUntilGainUpdateCount(_ count: Int) async {
        await gainUpdateGate.waitUntilEntered(count)
    }
    func cancelApplyOnStopAll(_ call: Int) {
        appliesToCancelOnStopAll.insert(call)
    }
    func waitUntilApplyPendingForStopAll(_ count: Int) async {
        guard pendingStopAllApplies.count < count else { return }
        await withCheckedContinuation { pendingStopAllApplyWaiters.append((count, $0)) }
    }
    func deferApplyObserver(_ call: Int) { deferredObserverCalls.insert(call) }
    func deferStopObserver(_ call: Int) { deferredStopObserverCalls.insert(call) }
    func deliverDeferredObservers() {
        let pending = deferredObservers
        deferredObservers.removeAll()
        pending.forEach { continuation.yield($0) }
    }
    func onStreamTermination(_ action: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in action() }
    }
}

typealias EngineFake = RecordingProcessTapEngine

final class PreferencesStoreFake: PreferencesStoring, @unchecked Sendable {
    private(set) var saveCount = 0
    var savedPreferences: AppPreferences = .default
    var saveError: Error?
    var saveFailuresRemaining = 0
    func load() -> AppPreferences { savedPreferences }
    func save(_ preferences: AppPreferences) throws {
        saveCount += 1
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw FixtureError.writeFailed
        }
        if let saveError { throw saveError }
        savedPreferences = preferences
    }
}

final class LifecycleRecorder: @unchecked Sendable {
    var events: [String] = []
}

actor ControlledCallGate {
    private var isBlocked = false
    private var enteredCount = 0
    private var blockedCalls: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func block() {
        isBlocked = true
    }

    func enter() async {
        enteredCount += 1
        let ready = enteredWaiters.filter { enteredCount >= $0.0 }
        enteredWaiters.removeAll { enteredCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard isBlocked else { return }
        await withCheckedContinuation { blockedCalls.append($0) }
    }

    func waitUntilEntered(_ count: Int) async {
        guard enteredCount < count else { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    func resumeAll() {
        isBlocked = false
        let calls = blockedCalls
        blockedCalls.removeAll()
        calls.forEach { $0.resume() }
    }
}

actor ControlledIndexedCallGate {
    private var blockedEntries: Set<Int> = []
    private var enteredCount = 0
    private var blockedCalls: [(Int, CheckedContinuation<Void, Never>)] = []
    private var enteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func block(_ entry: Int) {
        blockedEntries.insert(entry)
    }

    func enter(_ observer: (@Sendable (Int) -> Void)? = nil) async {
        enteredCount += 1
        let current = enteredCount
        observer?(current)
        let ready = enteredWaiters.filter { enteredCount >= $0.0 }
        enteredWaiters.removeAll { enteredCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard blockedEntries.contains(current) else { return }
        await withCheckedContinuation { blockedCalls.append((current, $0)) }
    }

    func waitUntilEntered(_ count: Int) async {
        guard enteredCount < count else { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    func resumeAll() {
        blockedEntries.removeAll()
        let calls = blockedCalls
        blockedCalls.removeAll()
        calls.forEach { $0.1.resume() }
    }

    func resume(_ entry: Int) {
        blockedEntries.remove(entry)
        let calls = blockedCalls.filter { $0.0 == entry }
        blockedCalls.removeAll { $0.0 == entry }
        calls.forEach { $0.1.resume() }
    }
}
