import Combine
import CoreAudio
import XCTest
import MacActivityCore
import MacActivityBatteryControl
@testable import MacActivityApp

@MainActor
final class AppSamplingControllerTests: XCTestCase {
    func testLateBatteryAssemblyAfterTerminationNeverCreatesModelOrObserver() async {
        let reply = expectation(description: "quit before startup")
        let delegate = AppDelegate(releasePageOpener: { _ in }, audioShutdown: {}, schedulerStop: {},
            terminationReply: { _ in reply.fulfill() })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        delegate.testingStartBatteryCare(preferences: lifecyclePreferences(), workspaceCenter: NotificationCenter())
        XCTAssertNil(delegate.testingBatteryCareModel)
        await fulfillment(of: [reply], timeout: 2)
        delegate.testingStartBatteryCare(preferences: lifecyclePreferences(), workspaceCenter: NotificationCenter())
        XCTAssertNil(delegate.testingBatteryCareModel)
    }

    func testProductionBatteryAssemblyStartsBeforeDashboardAndCannotRestartAfterQuit() async throws {
        let store = LifecycleBatteryPreferences(settings: try .init(isEnabled: true, limit: 64))
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let center = NotificationCenter()
        let replied = expectation(description: "termination replied")
        let delegate = AppDelegate(releasePageOpener: { _ in },
            audioShutdown: {}, schedulerStop: {}, terminationReply: { _ in replied.fulfill() })
        delegate.testingStartBatteryCare(preferences: preferences, workspaceCenter: center)
        let model = try XCTUnwrap(delegate.testingBatteryCareModel)
        delegate.testingStartBatteryCare(preferences: preferences, workspaceCenter: center)
        XCTAssertTrue(model === delegate.testingBatteryCareModel)
        let sleep = expectation(description: "startup bridge active without dashboard")
        let observer = model.$presentation.first(where: { $0.generation > 0 })
            .sink { _ in MainActor.assertIsolated(); sleep.fulfill() }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [sleep], timeout: 2)
        observer.cancel()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(delegate.batteryCareShutdownResult, .noControlAcquired)
        let generation = model.presentation.generation
        delegate.testingStartBatteryCare(preferences: preferences, workspaceCenter: center)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(model === delegate.testingBatteryCareModel)
        XCTAssertEqual(model.presentation.generation, generation)
        XCTAssertTrue(model.presentation.savedEnabled)
        XCTAssertEqual(model.presentation.savedLimit, 64)
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertNotEqual(model.presentation.recoveryStatus, .released)
    }

    func testTerminationWaitsForBatteryResultBeforeAudioSchedulerAndReply() async {
        let entered = expectation(description: "battery entered")
        let replied = expectation(description: "reply")
        var finish: CheckedContinuation<BatteryCareShutdownResult, Never>?
        var events: [String] = []
        let delegate = AppDelegate(releasePageOpener: { _ in }, batteryShutdown: {
            events.append("battery")
            return await withCheckedContinuation { finish = $0; entered.fulfill() }
        }, audioShutdown: { events.append("audio") }, schedulerStop: { events.append("scheduler") },
           terminationReply: { _ in events.append("reply"); replied.fulfill() })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(events, ["battery"])
        XCTAssertNil(delegate.batteryCareShutdownResult)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        finish?.resume(returning: .unconfirmed)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(events, ["battery", "audio", "scheduler", "reply"])
        XCTAssertEqual(delegate.batteryCareShutdownResult, .unconfirmed)
    }

    func testBatteryShutdownPrecedesBlockedAudioAndRetainsUnconfirmedResultExactlyOnce() async {
        var batteryCalls = 0
        let batteryEntered = expectation(description: "battery shutdown starts")
        let lifecycle = AppTerminationLifecycleSpy(blockAudioShutdown: true)
        let delegate = AppDelegate(releasePageOpener: { _ in },
            batteryShutdown: {
                batteryCalls += 1
                batteryEntered.fulfill()
                return .unconfirmed
            },
            audioShutdown: { await lifecycle.shutdownAudio() },
            schedulerStop: { await lifecycle.stopScheduler() },
            terminationReply: { lifecycle.reply($0) })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await fulfillment(of: [batteryEntered], timeout: 2)
        XCTAssertEqual(batteryCalls, 1)
        XCTAssertEqual(delegate.batteryCareShutdownResult, .unconfirmed)
        XCTAssertTrue(lifecycle.events.isEmpty)
        lifecycle.releaseAudioShutdown()
        await lifecycle.waitForReply()
        XCTAssertEqual(lifecycle.events, [.audioShutdown, .schedulerStop, .reply(true)])
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(batteryCalls, 1)
    }

    func testProductionAudioCompositionInjectsOneSharedAvailability() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacActivityApp/AppDelegate.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("let availability = AudioFeatureAvailability("))
        for injection in [
            "processProvider: AudioProcessService(availability: availability)",
            "monitor: AudioSystemMonitor(availability: availability)",
            "planner: AudioRoutePlanner()",
            "engine: ProcessTapVolumeEngine(availability: availability)",
        ] {
            XCTAssertTrue(source.contains(injection), injection)
        }
        XCTAssertFalse(source.contains("AudioRouteNativeValidationPolicy"))
    }

    func testHiddenDashboardDefaultsToBackgroundSampling() {
        let controller = AppSamplingController()

        XCTAssertEqual(controller.currentProfile, .background)
    }

    func testVisibleDashboardForcesRealtimeSampling() {
        let controller = AppSamplingController()

        controller.setDashboardVisible(true)

        XCTAssertEqual(controller.currentProfile, .realtime)
    }

    func testBatteryAndLowPowerPreferEnergySaverWhenDashboardHidden() {
        let controller = AppSamplingController()

        controller.setRunningOnBattery(true)
        XCTAssertEqual(controller.currentProfile, .energySaver)

        controller.setRunningOnBattery(false)
        controller.setLowPowerModeEnabled(true)
        XCTAssertEqual(controller.currentProfile, .energySaver)
    }

    func testAppDelegateOpensReleasesPageWhenSparkleCannotCheckForUpdates() {
        var openedURLs: [URL] = []
        let delegate = AppDelegate(
            sparkleUpdateController: RecordingUpdateChecker(result: false),
            releasePageOpener: { openedURLs.append($0) }
        )

        delegate.checkForUpdates()

        XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://github.com/bigtomcat6/mac-activity/releases"])
    }

    func testAppDelegateDoesNotOpenReleasesPageWhenSparkleHandlesUpdateCheck() {
        var openedURLs: [URL] = []
        let delegate = AppDelegate(
            sparkleUpdateController: RecordingUpdateChecker(result: true),
            releasePageOpener: { openedURLs.append($0) }
        )

        delegate.checkForUpdates()

        XCTAssertEqual(openedURLs, [])
    }

    func testAppDelegateCheckForUpdatesActionUsesSameFallback() {
        var openedURLs: [URL] = []
        let delegate = AppDelegate(
            sparkleUpdateController: nil,
            releasePageOpener: { openedURLs.append($0) }
        )
        let action = delegate.makeCheckForUpdatesAction()

        action()

        XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://github.com/bigtomcat6/mac-activity/releases"])
    }

    func testTerminationRepliesOnlyAfterAudioAndSchedulerStop() async {
        let lifecycle = AppTerminationLifecycleSpy(blockAudioShutdown: true)
        let delegate = AppDelegate(
            sparkleUpdateController: nil,
            releasePageOpener: { _ in },
            audioShutdown: { await lifecycle.shutdownAudio() },
            schedulerStop: { await lifecycle.stopScheduler() },
            terminationReply: { accepted in lifecycle.reply(accepted) }
        )

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(lifecycle.events, [])
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)

        lifecycle.releaseAudioShutdown()
        await lifecycle.waitForReply()

        XCTAssertEqual(lifecycle.events, [.audioShutdown, .schedulerStop, .reply(true)])
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testTerminationCancelsAndAwaitsOwnedStartupBeforeRealLifecycleShutdown() async throws {
        let audioEngine = AppTerminationAudioEngine()
        let audioMonitor = AppTerminationAudioMonitor()
        let audioServices = AppTerminationAudioServices()
        let preferences = PreferencesController(
            store: AppDelegatePreferencesStore(),
            launchService: NoopLaunchAtLoginService()
        )
        let coordinator = AudioControlCoordinator(
            availability: .supported,
            deviceProvider: audioServices,
            processProvider: audioServices,
            routeDeviceProvider: audioServices,
            monitor: audioMonitor,
            planner: AudioRoutePlanner(),
            engine: audioEngine,
            preferences: preferences,
            systemAudioAuthorizationReader: AudioSystemAuthorizationReaderFake(),
            systemAudioAuthorizationRequester: AudioSystemAuthorizationRequesterFake()
        )
        let metricsProvider = AppTerminationMetricProvider()
        let scheduler = MetricsScheduler(
            providers: [metricsProvider],
            store: MetricsStore()
        )
        let replies = AppTerminationReplyRecorder()
        let batteryRevoked = expectation(description: "battery revoked before suspended audio startup exits")
        let delegate = AppDelegate(
            sparkleUpdateController: nil,
            releasePageOpener: { _ in },
            batteryShutdown: { batteryRevoked.fulfill(); return .noControlAcquired },
            terminationReply: { accepted in replies.record(accepted) }
        )
        await audioEngine.blockPrepareRuntime()
        delegate.testingStartOwnedLifecycles(
            audioControlCoordinator: coordinator,
            scheduler: scheduler
        )
        await audioEngine.waitUntilPrepareRuntimeEntered()
        await metricsProvider.waitUntilEntered()

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await audioEngine.waitUntilPrepareRuntimeCanceled()
        await fulfillment(of: [batteryRevoked], timeout: 2)
        XCTAssertEqual(replies.values, [])
        let shutdownCountBeforePrepareRelease = await audioEngine.shutdownCount()
        let stopAllCountBeforePrepareRelease = await audioEngine.stopAllCount()
        XCTAssertEqual(shutdownCountBeforePrepareRelease, 0)
        XCTAssertEqual(stopAllCountBeforePrepareRelease, 0)

        await audioEngine.releasePrepareRuntime()
        await audioEngine.waitUntilShutdownCount(1)
        await metricsProvider.waitUntilCanceled()
        XCTAssertEqual(audioMonitor.startCount, 1)
        XCTAssertEqual(replies.values, [])

        await metricsProvider.release()
        await replies.waitForReply()
        XCTAssertEqual(replies.values, [true])
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testClosingAndReopeningPopoverKeepsOneDashboardIdentityAndAudioCoordinator() throws {
        let coordinator = TestAudioControlCoordinator()
        let batteryCareModel = makeTestBatteryCareModel()
        let delegate = AppDelegate(releasePageOpener: { _ in })
        delegate.testingConfigureDashboardPopoverFactory(
            preferencesController: PreferencesController(
                store: AppDelegatePreferencesStore(),
                launchService: NoopLaunchAtLoginService()
            ),
            audioControlCoordinator: coordinator,
            batteryCareModel: batteryCareModel
        )

        let firstPopover = delegate.testingResolveDashboardPopoverController()
        let firstModel = try XCTUnwrap(firstPopover.testingAudioDashboardModel)
        firstPopover.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        let secondPopover = delegate.testingResolveDashboardPopoverController()
        let secondModel = try XCTUnwrap(secondPopover.testingAudioDashboardModel)

        XCTAssertTrue(firstPopover === secondPopover)
        XCTAssertTrue(firstModel === secondModel)
        XCTAssertTrue(firstPopover.testingBatteryCareModel === secondPopover.testingBatteryCareModel)
        XCTAssertTrue(firstPopover.testingBatteryCareModel === batteryCareModel)
        XCTAssertTrue(firstModel.testingCoordinator === secondModel.testingCoordinator)
        XCTAssertEqual(coordinator.shutdownCallCount, 0)
    }
}

@MainActor
private final class AppTerminationLifecycleSpy {
    enum Event: Equatable {
        case audioShutdown
        case schedulerStop
        case reply(Bool)
    }

    private(set) var events: [Event] = []
    private var audioContinuation: CheckedContinuation<Void, Never>?
    private var replyContinuation: CheckedContinuation<Void, Never>?
    private let blockAudioShutdown: Bool
    private var didReleaseAudioShutdown = false

    init(blockAudioShutdown: Bool) {
        self.blockAudioShutdown = blockAudioShutdown
    }

    func shutdownAudio() async {
        if blockAudioShutdown && didReleaseAudioShutdown == false {
            await withCheckedContinuation { audioContinuation = $0 }
        }
        events.append(.audioShutdown)
    }

    func releaseAudioShutdown() {
        didReleaseAudioShutdown = true
        audioContinuation?.resume()
        audioContinuation = nil
    }

    func stopScheduler() async {
        events.append(.schedulerStop)
    }

    func reply(_ accepted: Bool) {
        events.append(.reply(accepted))
        replyContinuation?.resume()
        replyContinuation = nil
    }

    func waitForReply() async {
        if events.contains(.reply(true)) { return }
        await withCheckedContinuation { replyContinuation = $0 }
    }
}

@MainActor
private final class RecordingUpdateChecker: UpdateChecking {
    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func checkForUpdates() -> Bool {
        result
    }
}

@MainActor
final class TestAudioControlCoordinator: AudioControlCoordinating {
    let supportsProcessControls: Bool
    private(set) var snapshot: AudioControlSnapshot
    private let subject: CurrentValueSubject<AudioControlSnapshot, Never>
    var snapshotPublisher: AnyPublisher<AudioControlSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }
    private(set) var shutdownCallCount = 0
    private(set) var refreshSystemAudioAuthorizationCallCount = 0
    var onRefreshSystemAudioAuthorization: (() async -> Void)?

    init(supportsProcessControls: Bool = false, snapshot: AudioControlSnapshot = .empty) {
        self.supportsProcessControls = supportsProcessControls
        self.snapshot = snapshot
        self.subject = CurrentValueSubject(snapshot)
    }

    func start() async {}
    func refreshSystemAudioAuthorization() async {
        refreshSystemAudioAuthorizationCallCount += 1
        await onRefreshSystemAudioAuthorization?()
    }
    func requestSystemAudioAccess() async {}
    func retryDevice(_ deviceUID: String) {}
    func setDeviceVolume(_ volume: Double, for deviceUID: String) {}
    func setDeviceMuted(_ isMuted: Bool, for deviceUID: String) {}
    func setProcessVolume(_ volume: Double, for processObjectID: AudioObjectID) {}
    func setProcessMuted(_ isMuted: Bool, for processObjectID: AudioObjectID) {}
    func setProcessRoute(_ route: AudioRouteMode, for processObjectID: AudioObjectID) {}
    func retry(processObjectID: AudioObjectID) {}
    func reset(processObjectID: AudioObjectID) {}
    func shutdown() async { shutdownCallCount += 1 }
}

private final class AppDelegatePreferencesStore: PreferencesStoring, @unchecked Sendable {
    func load() -> AppPreferences { .default }
    func save(_ preferences: AppPreferences) throws {}
}

@MainActor
private final class AppTerminationAudioServices:
    AudioDeviceControlProviding,
    AudioProcessProviding,
    AudioRouteDeviceProviding {
    let routeDevice = DeviceProviderFake.makeRouteDevice(id: 10, uid: "BuiltIn")

    var discoveredProcessObjectIDs: Set<AudioObjectID> { [11] }

    func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot] {
        [AudioOutputDeviceSnapshot(
            id: routeDevice.uid,
            objectID: routeDevice.objectID,
            name: routeDevice.name,
            volume: .value(0.5, isWritable: true),
            mute: .value(false, isWritable: true)
        )]
    }
    func outputDeviceSnapshot(forUID uid: String) throws -> AudioOutputDeviceSnapshot {
        fatalError("No device should be requested")
    }
    func writeVolume(_ volume: Double, forUID uid: String) throws -> Double { volume }
    func writeMute(_ isMuted: Bool, forUID uid: String) throws -> Bool { isMuted }
    func audibleOutputProcesses() -> [AudioProcessEntry] {
        [.music(objectID: 11, outputDeviceIDs: [routeDevice.objectID])]
    }
    func routeDevices() throws -> [AudioRouteDevice] { [routeDevice] }
}

private final class AppTerminationAudioMonitor: AudioSystemMonitoring, @unchecked Sendable {
    let changes: AsyncStream<Set<AudioSystemChange>>
    private(set) var startCount = 0

    init() {
        changes = AsyncStream { _ in }
    }

    func start() throws { startCount += 1 }
    func updateObservedObjects(
        deviceIDs: Set<AudioDeviceID>,
        processObjectIDs: Set<AudioObjectID>
    ) throws {}
    func stop() {}
}

private final class AppTerminationAudioEngine: ProcessTapVolumeControlling, @unchecked Sendable {
    let sessionSnapshots: AsyncStream<ProcessTapSessionSnapshot>
    private let state = AppTerminationAudioEngineState()

    init() {
        sessionSnapshots = AsyncStream { _ in }
    }

    func apply(
        plan: AudioRoutePlan,
        gain: ProcessGainState
    ) async -> ProcessTapSessionSnapshot {
        fatalError("No process rule should be restored")
    }
    func updateGain(_ gain: ProcessGainState, for processObjectID: AudioObjectID) async {}
    func stop(
        processObjectID: AudioObjectID,
        generation: UInt64
    ) async -> ProcessTapSessionSnapshot {
        fatalError("No process should be stopped")
    }
    func stopAll() async { await state.recordStopAll() }
    func prepareRuntime() async -> ProcessTapRuntimePreparation {
        await state.enterPreparation()
        return .ready(cleanupFailures: [])
    }
    func shutdown() async { await state.recordShutdown() }

    func blockPrepareRuntime() async { await state.blockPreparation() }
    func releasePrepareRuntime() async { await state.releasePreparation() }
    func waitUntilPrepareRuntimeEntered() async { await state.waitUntilPreparationEntered() }
    func waitUntilPrepareRuntimeCanceled() async { await state.waitUntilPreparationCanceled() }
    func waitUntilShutdownCount(_ count: Int) async { await state.waitUntilShutdownCount(count) }
    func stopAllCount() async -> Int { await state.currentStopAllCount() }
    func shutdownCount() async -> Int { await state.currentShutdownCount() }
}

private actor AppTerminationAudioEngineState {
    private var blocksPreparation = false
    private var preparationEntered = false
    private var preparationCanceled = false
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    private var preparationEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var preparationCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopAllCount = 0
    private var shutdownCount = 0
    private var shutdownWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func blockPreparation() { blocksPreparation = true }

    func enterPreparation() async {
        preparationEntered = true
        preparationEntryWaiters.forEach { $0.resume() }
        preparationEntryWaiters.removeAll()
        guard blocksPreparation else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { preparationContinuation = $0 }
        } onCancel: {
            Task { await self.recordPreparationCancellation() }
        }
    }

    func releasePreparation() {
        blocksPreparation = false
        preparationContinuation?.resume()
        preparationContinuation = nil
    }

    func waitUntilPreparationEntered() async {
        guard preparationEntered == false else { return }
        await withCheckedContinuation { preparationEntryWaiters.append($0) }
    }

    func waitUntilPreparationCanceled() async {
        guard preparationCanceled == false else { return }
        await withCheckedContinuation { preparationCancellationWaiters.append($0) }
    }

    func recordStopAll() {
        stopAllCount += 1
    }

    func recordShutdown() {
        shutdownCount += 1
        let ready = shutdownWaiters.filter { shutdownCount >= $0.0 }
        shutdownWaiters.removeAll { shutdownCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilShutdownCount(_ count: Int) async {
        guard shutdownCount < count else { return }
        await withCheckedContinuation { shutdownWaiters.append((count, $0)) }
    }

    func currentStopAllCount() -> Int { stopAllCount }
    func currentShutdownCount() -> Int { shutdownCount }

    private func recordPreparationCancellation() {
        preparationCanceled = true
        preparationCancellationWaiters.forEach { $0.resume() }
        preparationCancellationWaiters.removeAll()
    }
}

private actor AppTerminationMetricProvider: MetricProvider {
    let kind = MetricKind.cpu
    let cadence = MetricCadenceLane.fast

    private var entered = false
    private var canceled = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func sample() async -> MetricUpdate {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withTaskCancellationHandler {
            guard released == false else { return }
            await withCheckedContinuation { releaseContinuation = $0 }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        return .cpu(CPUReading(usagePercent: 1))
    }

    func waitUntilEntered() async {
        guard entered == false else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
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

    private func recordCancellation() {
        canceled = true
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }
}

@MainActor
private final class AppTerminationReplyRecorder {
    private(set) var values: [Bool] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func record(_ value: Bool) {
        values.append(value)
        waiter?.resume()
        waiter = nil
    }

    func waitForReply() async {
        guard values.isEmpty else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
