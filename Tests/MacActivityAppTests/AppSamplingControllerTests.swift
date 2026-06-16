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
}
