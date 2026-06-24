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
