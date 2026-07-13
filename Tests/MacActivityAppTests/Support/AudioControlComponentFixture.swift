import CoreAudio
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
        delay: @escaping AudioControlDelay = { _ in }
    ) {
        self.engine = engine
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
        let planner = planner ?? Self.validatedPlanner(devices: deviceProvider.routeDescriptors)
        coordinator = AudioControlCoordinator(
            availability: availability,
            deviceProvider: deviceProvider,
            processProvider: processProvider,
            routeDeviceProvider: deviceProvider,
            monitor: monitor,
            planner: planner,
            engine: engine,
            preferences: preferences,
            delay: delay
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

    private static func validatedPlanner(devices: [AudioRouteDevice]) -> AudioRoutePlanner {
        let fingerprintPlanner = AudioRoutePlanner()
        let requests: [([String], AudioRouteMode)] = [
            (["BuiltIn"], .followOriginal),
            (["USB"], .followOriginal),
            (["BuiltIn"], .explicit(targetDeviceUIDs: ["BuiltIn"])),
            (["BuiltIn"], .explicit(targetDeviceUIDs: ["USB"])),
            (["BuiltIn"], .explicit(targetDeviceUIDs: ["BuiltIn", "USB"])),
            (["BuiltIn"], .explicit(targetDeviceUIDs: ["USB", "BuiltIn"])),
        ]
        let fingerprints = requests.compactMap { sourceUIDs, mode in
            try? fingerprintPlanner.topologyFingerprint(for: .init(
                processObjectID: 11,
                generation: 1,
                sourceDeviceUIDs: sourceUIDs,
                systemDefaultOutputDeviceUID: nil,
                mode: mode,
                devices: devices
            ))
        }
        return AudioRoutePlanner(
            policy: .init(validatedFingerprints: Set(fingerprints))
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

    init(savedProfile: AudioProcessProfile? = nil) {
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
            planner: Self.validatedPlanner(devices: routeDevices),
            engine: engine,
            preferences: preferences,
            delay: { _ in }
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

    private static func validatedPlanner(devices: [AudioRouteDevice]) -> AudioRoutePlanner {
        let fingerprintPlanner = AudioRoutePlanner()
        let uids = devices.map(\.uid)
        var fingerprints: Set<AudioRouteTopologyFingerprint> = []
        for sourceUID in uids {
            let modes: [AudioRouteMode] = [.followOriginal] + (1..<(1 << uids.count)).map { mask in
                .explicit(targetDeviceUIDs: uids.enumerated().compactMap { index, uid in
                    mask & (1 << index) == 0 ? nil : uid
                })
            }
            for mode in modes {
                guard let fingerprint = try? fingerprintPlanner.topologyFingerprint(for: .init(
                    processObjectID: 11,
                    generation: 1,
                    sourceDeviceUIDs: [sourceUID],
                    systemDefaultOutputDeviceUID: nil,
                    mode: mode,
                    devices: devices
                )) else { continue }
                fingerprints.insert(fingerprint)
            }
        }
        return AudioRoutePlanner(
            policy: .init(validatedFingerprints: fingerprints)
        )
    }
}

extension AudioFeatureAvailability {
    private static let testValidatedPolicy = AudioRouteNativeValidationPolicy(
        validatedFingerprints: [AudioRouteTopologyFingerprint(
            osBuild: "test",
            sourceDeviceUIDs: ["source"],
            selectedTargetUIDs: ["target"],
            devices: []
        )]
    )

    static let unsupported = AudioFeatureAvailability(
        operatingSystemVersion: .init(majorVersion: 14, minorVersion: 1, patchVersion: 0),
        nativeValidationPolicy: testValidatedPolicy
    )
    static let supported = AudioFeatureAvailability(
        operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0),
        nativeValidationPolicy: testValidatedPolicy
    )
}

@MainActor
final class DeviceProviderFake: AudioDeviceControlProviding, AudioRouteDeviceProviding {
    var volumeWriteError: Error?
    var muteWriteError: Error?
    var confirmedMute = false
    var confirmedVolume = 0.5
    var snapshotVolume = 0.5
    var snapshotMute = false
    private(set) var volumeWrites: [Double] = []
    private(set) var muteWrites: [Bool] = []
    var lifecycle: LifecycleRecorder?
    var onRouteRead: (@MainActor () -> Void)?
    var routeReadError: Error?
    var outputSnapshots: [AudioOutputDeviceSnapshot]?

    var routeDescriptors: [AudioRouteDevice] = [
        makeRouteDevice(id: 10, uid: "BuiltIn"),
        makeRouteDevice(id: 20, uid: "USB"),
    ]

    func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot] {
        lifecycle?.events.append("devices.read")
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
        volumeWrites.append(volume)
        if let volumeWriteError { throw volumeWriteError }
        return confirmedVolume
    }
    func writeMute(_ isMuted: Bool, forUID uid: String) throws -> Bool {
        muteWrites.append(isMuted)
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
    var bundleIdentifier: String? = "com.example.music"
    var processes: [AudioProcessEntry]?
    var scriptedProcesses: [[AudioProcessEntry]] = []
    var lifecycle: LifecycleRecorder?

    func audibleOutputProcesses() -> [AudioProcessEntry] {
        callCount += 1
        lifecycle?.events.append("processes.read")
        if scriptedProcesses.isEmpty == false {
            return scriptedProcesses.removeFirst()
        }
        return processes ?? [.init(
            processObjectID: 11,
            processIdentifier: 101,
            name: "Music",
            bundleIdentifier: bundleIdentifier,
            bundleURL: nil,
            outputDeviceIDs: [10]
        )]
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

struct RecordingEngineStopCall: Equatable {
    let processObjectID: AudioObjectID
    let generation: UInt64
}

struct RecordingEngineApplyKey: Hashable {
    let processObjectID: AudioObjectID
    let generation: UInt64
}

final class RecordingProcessTapEngine: ProcessTapVolumeControlling, @unchecked Sendable {
    let sessionSnapshots: AsyncStream<ProcessTapSessionSnapshot>
    private let continuation: AsyncStream<ProcessTapSessionSnapshot>.Continuation
    private(set) var applyCount = 0
    private(set) var cleanupCount = 0
    private(set) var authorizationAttemptCount = 0
    private(set) var stopAllCount = 0
    private(set) var plans: [AudioRoutePlan] = []
    private(set) var gains: [ProcessGainState] = []
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
    var scriptedCleanupResults: [[AudioTeardownFailure]] = []
    var lifecycle: LifecycleRecorder?
    private var nextCommandSequence: UInt64 = 0
    private let stopGate = ControlledCallGate()
    private let cleanupGate = ControlledCallGate()
    private let applyGate = ControlledIndexedCallGate()
    private let applyReturnGate = ControlledIndexedCallGate()
    private var deferredObserverCalls: Set<Int> = []
    private var deferredObservers: [ProcessTapSessionSnapshot] = []

    init() {
        let stream = AsyncStream<ProcessTapSessionSnapshot>.makeStream()
        sessionSnapshots = stream.stream
        continuation = stream.continuation
    }

    func apply(plan: AudioRoutePlan, gain: ProcessGainState) async -> ProcessTapSessionSnapshot {
        lifecycle?.events.append("engine.apply")
        applyCount += 1
        authorizationAttemptCount += 1
        plans.append(plan)
        gains.append(gain)
        await applyGate.enter()
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
        if deferredObserverCalls.contains(applyCount) {
            deferredObservers.append(snapshot)
        } else {
            continuation.yield(snapshot)
        }
        await applyReturnGate.enter()
        return snapshot
    }
    func updateGain(_ gain: ProcessGainState, for processObjectID: AudioObjectID) async {}
    func stop(processObjectID: AudioObjectID, generation: UInt64) async -> ProcessTapSessionSnapshot {
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
        continuation.yield(snapshot)
        return snapshot
    }
    func stopAll() async {
        stopAllCount += 1
        lifecycle?.events.append("engine.stopAll")
    }
    func cleanupOrphans() async -> [AudioTeardownFailure] {
        cleanupCount += 1
        lifecycle?.events.append("engine.cleanup")
        await cleanupGate.enter()
        return scriptedCleanupResults.isEmpty ? [] : scriptedCleanupResults.removeFirst()
    }
    var lastAppliedPlan: AudioRoutePlan? { plans.last }
    var lastStopObjectID: AudioObjectID? { stopCalls.last?.processObjectID }
    func emit(_ snapshot: ProcessTapSessionSnapshot) { continuation.yield(snapshot) }
    func blockStops() async { await stopGate.block() }
    func resumeStops() async { await stopGate.resumeAll() }
    func waitUntilStopCount(_ count: Int) async { await stopGate.waitUntilEntered(count) }
    func blockCleanup() async { await cleanupGate.block() }
    func resumeCleanup() async { await cleanupGate.resumeAll() }
    func waitUntilCleanupCount(_ count: Int) async { await cleanupGate.waitUntilEntered(count) }
    func blockApplyCall(_ call: Int) async { await applyGate.block(call) }
    func resumeApplies() async { await applyGate.resumeAll() }
    func waitUntilApplyCount(_ count: Int) async { await applyGate.waitUntilEntered(count) }
    func blockApplyReturn(_ call: Int) async { await applyReturnGate.block(call) }
    func resumeApplyReturns() async { await applyReturnGate.resumeAll() }
    func waitUntilApplyReturnCount(_ count: Int) async {
        await applyReturnGate.waitUntilEntered(count)
    }
    func deferApplyObserver(_ call: Int) { deferredObserverCalls.insert(call) }
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

actor ControlledAudioDelay {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func callAsFunction(_ duration: Duration) async {
        callCount += 1
        let ready = callCountWaiters.filter { callCount >= $0.0 }
        callCountWaiters.removeAll { callCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilCallCount(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { callCountWaiters.append((count, $0)) }
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

actor ControlledShutdownDelay {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var canceled = false
    private var released = false

    func callAsFunction(_ duration: Duration) async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withTaskCancellationHandler {
            await withCheckedContinuation { enteredContinuation = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
        guard released == false else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard entered == false else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitUntilCanceled() async {
        guard canceled == false else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func cancel() {
        canceled = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }
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
    private var blockedCalls: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func block(_ entry: Int) {
        blockedEntries.insert(entry)
    }

    func enter() async {
        enteredCount += 1
        let current = enteredCount
        let ready = enteredWaiters.filter { enteredCount >= $0.0 }
        enteredWaiters.removeAll { enteredCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard blockedEntries.contains(current) else { return }
        await withCheckedContinuation { blockedCalls.append($0) }
    }

    func waitUntilEntered(_ count: Int) async {
        guard enteredCount < count else { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    func resumeAll() {
        blockedEntries.removeAll()
        let calls = blockedCalls
        blockedCalls.removeAll()
        calls.forEach { $0.resume() }
    }
}
