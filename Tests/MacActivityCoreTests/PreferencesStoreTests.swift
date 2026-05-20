import Foundation
import XCTest
@testable import MacActivityCore

final class PreferencesStoreTests: XCTestCase {
    func testSavePersistsPreferencesForFutureLoads() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)

        let expected = AppPreferences(
            launchAtLoginEnabled: true,
            selectedSummaryMetrics: [.vram, .memory, .temperature, .cpu]
        )

        try store.save(expected)
        let loaded = store.load()

        XCTAssertEqual(loaded, expected)
    }

    func testDefaultSummaryMetricsIncludeMenuBarHardwareMetrics() {
        XCTAssertEqual(
            AppPreferences.default.selectedSummaryMetrics,
            [.cpu, .gpu, .memory, .vram, .temperature, .fan, .network]
        )
    }
}
