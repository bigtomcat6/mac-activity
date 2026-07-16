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
            selectedSummaryMetrics: [.vram, .memory, .temperature, .cpu],
            temperatureSource: .battery,
            preferredLanguageIdentifier: "zh-Hans",
            diskCleanupCategories: [.userCaches, .trash, .userLogs],
            showsHardwareBatteryPercentage: true,
            showsProcessApplicationIdentifier: false,
            updateChannel: .alpha,
            audioProcessProfiles: [
                "com.example.Player": AudioProcessProfile(
                    bundleIdentifier: "com.example.Player",
                    volume: 0.4,
                    isMuted: true,
                    route: .explicit(targetDeviceUIDs: ["MissingButStable"])
                ),
            ]
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
        XCTAssertFalse(AppPreferences.default.showsHardwareBatteryPercentage)
        XCTAssertFalse(AppPreferences.default.showsProcessApplicationIdentifier)
        XCTAssertEqual(AppPreferences.default.updateChannel, .release)
    }

    func testLoadMigratesLegacyDefaultSummaryMetricsToCurrentHardwareMetrics() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        let legacyData = Data(
            #"{"selectedSummaryMetrics":["cpu","memory","network"],"launchAtLoginEnabled":true,"isMenuBarEnabled":true}"#
                .utf8
        )
        userDefaults.set(legacyData, forKey: "mac-activity.preferences")

        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)
        let loaded = store.load()

        XCTAssertEqual(loaded.selectedSummaryMetrics, AppPreferences.default.selectedSummaryMetrics)
        XCTAssertEqual(loaded.launchAtLoginEnabled, true)
        XCTAssertEqual(loaded.temperatureSource, .smc)
    }

    func testLoadDefaultsTemperatureSourceWhenMissingFromStoredPreferences() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        let legacyData = Data(
            #"{"selectedSummaryMetrics":["cpu","temperature"],"launchAtLoginEnabled":true}"#
                .utf8
        )
        userDefaults.set(legacyData, forKey: "mac-activity.preferences")

        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)
        let loaded = store.load()

        XCTAssertEqual(loaded.selectedSummaryMetrics, [.cpu, .temperature])
        XCTAssertEqual(loaded.launchAtLoginEnabled, true)
        XCTAssertEqual(loaded.temperatureSource, .smc)
        XCTAssertNil(loaded.preferredLanguageIdentifier)
    }

    func testLoadDefaultsDiskCleanupCategoriesWhenMissingFromStoredPreferences() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        let legacyData = Data(
            #"{"selectedSummaryMetrics":["cpu","temperature"],"launchAtLoginEnabled":true,"temperatureSource":"battery"}"#
                .utf8
        )
        userDefaults.set(legacyData, forKey: "mac-activity.preferences")

        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)
        let loaded = store.load()

        XCTAssertEqual(loaded.diskCleanupCategories, [.userCaches])
    }

    func testLoadDefaultsHardwareBatteryPercentageToFalseWhenMissingFromStoredPreferences() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        let legacyData = Data(
            #"{"selectedSummaryMetrics":["cpu","battery"],"launchAtLoginEnabled":false,"temperatureSource":"smc"}"#
                .utf8
        )
        userDefaults.set(legacyData, forKey: "mac-activity.preferences")

        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)
        let loaded = store.load()

        XCTAssertFalse(loaded.showsHardwareBatteryPercentage)
    }

    func testLoadDefaultsProcessApplicationIdentifierToFalseWhenMissingFromStoredPreferences() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        let legacyData = Data(
            #"{"selectedSummaryMetrics":["cpu","battery"],"launchAtLoginEnabled":false,"temperatureSource":"smc"}"#
                .utf8
        )
        userDefaults.set(legacyData, forKey: "mac-activity.preferences")

        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)
        let loaded = store.load()

        XCTAssertFalse(loaded.showsProcessApplicationIdentifier)
    }

    func testLoadDefaultsUpdateChannelToReleaseWhenMissingFromStoredPreferences() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        let legacyData = Data(
            #"{"selectedSummaryMetrics":["cpu","battery"],"launchAtLoginEnabled":false,"temperatureSource":"smc"}"#
                .utf8
        )
        userDefaults.set(legacyData, forKey: "mac-activity.preferences")

        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)
        let loaded = store.load()

        XCTAssertEqual(loaded.updateChannel, .release)
    }

    func testLoadMigratesLegacyDiskCleanupScopeToCategories() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        let legacyData = Data(
            #"{"selectedSummaryMetrics":["cpu","temperature"],"launchAtLoginEnabled":true,"temperatureSource":"battery","diskCleanupScope":"cachesTrashAndLogs"}"#
                .utf8
        )
        userDefaults.set(legacyData, forKey: "mac-activity.preferences")

        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)
        let loaded = store.load()

        XCTAssertEqual(loaded.diskCleanupCategories, [.userCaches, .trash, .userLogs])
    }

}
