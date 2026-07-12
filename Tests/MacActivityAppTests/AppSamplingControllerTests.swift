import Combine
import CoreAudio
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class AppSamplingControllerTests: XCTestCase {
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

    func testTerminationCancelsAndAwaitsOwnedStartupBeforeRealLifecycleShutdown() async {
        let audioEngine = AppTerminationAudioEngine()
        let audioMonitor = AppTerminationAudioMonitor()
        let audioServices = AppTerminationAudioServices()
        let preferences = PreferencesController(
            store: AppDelegatePreferencesStore(),
            launchService: NoopLaunchAtLoginService()
        )
        let coordinator = AudioControlCoordinator(
            availability: .init(
                operatingSystemVersion: .init(majorVersion: 14, minorVersion: 1, patchVersion: 0)
            ),
            deviceProvider: audioServices,
            processProvider: audioServices,
            routeDeviceProvider: audioServices,
            monitor: audioMonitor,
            engine: audioEngine,
            preferences: preferences
        )
        let metricsProvider = AppTerminationMetricProvider()
        let scheduler = MetricsScheduler(
            providers: [metricsProvider],
            store: MetricsStore()
        )
        let replies = AppTerminationReplyRecorder()
        let delegate = AppDelegate(
            sparkleUpdateController: nil,
            releasePageOpener: { _ in },
            terminationReply: { accepted in replies.record(accepted) }
        )
        await audioEngine.blockCleanup()
        delegate.testingStartOwnedLifecycles(
            audioControlCoordinator: coordinator,
            scheduler: scheduler
        )
        await audioEngine.waitUntilCleanupEntered()
        await metricsProvider.waitUntilEntered()

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await audioEngine.waitUntilCleanupCanceled()
        XCTAssertEqual(replies.values, [])

        await audioEngine.releaseCleanup()
        await audioEngine.waitUntilStopAllCount(1)
        await metricsProvider.waitUntilCanceled()
        XCTAssertEqual(audioMonitor.startCount, 0)
        XCTAssertEqual(replies.values, [])

        await metricsProvider.release()
        await replies.waitForReply()
        XCTAssertEqual(replies.values, [true])
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testClosingAndRecreatingPopoverKeepsOneApplicationAudioCoordinator() throws {
        let coordinator = TestAudioControlCoordinator()
        let delegate = AppDelegate(releasePageOpener: { _ in })
        delegate.testingConfigureDashboardPopoverFactory(
            preferencesController: PreferencesController(
                store: AppDelegatePreferencesStore(),
                launchService: NoopLaunchAtLoginService()
            ),
            audioControlCoordinator: coordinator
        )

        let firstPopover = delegate.testingResolveDashboardPopoverController()
        let firstModel = try XCTUnwrap(firstPopover.testingAudioDashboardModel)
        firstPopover.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        let secondPopover = delegate.testingResolveDashboardPopoverController()
        let secondModel = try XCTUnwrap(secondPopover.testingAudioDashboardModel)

        XCTAssertFalse(firstPopover === secondPopover)
        XCTAssertFalse(firstModel === secondModel)
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

    init(supportsProcessControls: Bool = false, snapshot: AudioControlSnapshot = .empty) {
        self.supportsProcessControls = supportsProcessControls
        self.snapshot = snapshot
        self.subject = CurrentValueSubject(snapshot)
    }

    func start() async {}
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
    AudioRouteDeviceProviding
{
    func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot] { [] }
    func outputDeviceSnapshot(forUID uid: String) throws -> AudioOutputDeviceSnapshot {
        fatalError("No device should be requested")
    }
    func writeVolume(_ volume: Double, forUID uid: String) throws -> Double { volume }
    func writeMute(_ isMuted: Bool, forUID uid: String) throws -> Bool { isMuted }
    func audibleOutputProcesses() -> [AudioProcessEntry] { [] }
    func routeDevices() throws -> [AudioRouteDevice] { [] }
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
    func cleanupOrphans() async -> [AudioTeardownFailure] {
        await state.enterCleanup()
        return []
    }

    func blockCleanup() async { await state.blockCleanup() }
    func releaseCleanup() async { await state.releaseCleanup() }
    func waitUntilCleanupEntered() async { await state.waitUntilCleanupEntered() }
    func waitUntilCleanupCanceled() async { await state.waitUntilCleanupCanceled() }
    func waitUntilStopAllCount(_ count: Int) async { await state.waitUntilStopAllCount(count) }
}

private actor AppTerminationAudioEngineState {
    private var blocksCleanup = false
    private var cleanupEntered = false
    private var cleanupCanceled = false
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private var cleanupEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cleanupCancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopAllCount = 0
    private var stopAllWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func blockCleanup() { blocksCleanup = true }

    func enterCleanup() async {
        cleanupEntered = true
        cleanupEntryWaiters.forEach { $0.resume() }
        cleanupEntryWaiters.removeAll()
        guard blocksCleanup else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { cleanupContinuation = $0 }
        } onCancel: {
            Task { await self.recordCleanupCancellation() }
        }
    }

    func releaseCleanup() {
        blocksCleanup = false
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }

    func waitUntilCleanupEntered() async {
        guard cleanupEntered == false else { return }
        await withCheckedContinuation { cleanupEntryWaiters.append($0) }
    }

    func waitUntilCleanupCanceled() async {
        guard cleanupCanceled == false else { return }
        await withCheckedContinuation { cleanupCancellationWaiters.append($0) }
    }

    func recordStopAll() {
        stopAllCount += 1
        let ready = stopAllWaiters.filter { stopAllCount >= $0.0 }
        stopAllWaiters.removeAll { stopAllCount >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitUntilStopAllCount(_ count: Int) async {
        guard stopAllCount < count else { return }
        await withCheckedContinuation { stopAllWaiters.append((count, $0)) }
    }

    private func recordCleanupCancellation() {
        cleanupCanceled = true
        cleanupCancellationWaiters.forEach { $0.resume() }
        cleanupCancellationWaiters.removeAll()
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
