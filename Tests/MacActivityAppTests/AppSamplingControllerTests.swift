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
