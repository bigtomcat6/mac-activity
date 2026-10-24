import Foundation
import XCTest
import MacActivityBatteryControl
@testable import MacActivityCore

final class PreferencesStoreTests: XCTestCase {
    func testMissingOrMalformedBatteryCareKeepsOtherPreferences() throws {
        var expected = AppPreferences(
            launchAtLoginEnabled: true, selectedSummaryMetrics: [.cpu, .battery],
            temperatureSource: .battery, preferredLanguageIdentifier: "zh-Hans",
            diskCleanupCategories: [.trash, .userLogs], showsHardwareBatteryPercentage: true,
            showsProcessApplicationIdentifier: true, energyImpactAppScope: .regularAndAccessory,
            updateChannel: .beta, lastSyncedUpdateChannelReleaseTag: "v26.0.0-beta.2",
            audioProcessProfiles: ["com.example.Player": AudioProcessProfile(bundleIdentifier: "com.example.Player", volume: 0.4)]
        )
        expected.batteryCare = .default
        let encoded = try JSONEncoder().encode(expected)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let malformed: [Any?] = [nil, NSNull(), "bad", [:], ["isEnabled": true, "limit": 49],
                                 ["isEnabled": true, "limit": 101], ["isEnabled": true, "limit": 80.5],
                                 ["isEnabled": "true", "limit": 80], ["isEnabled": true]]
        for batteryCare in malformed {
            var payload = original
            payload["batteryCare"] = batteryCare
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: data), expected)
        }
        let legacy = Data(#"{"launchAtLoginEnabled":true,"selectedSummaryMetrics":["cpu","battery"]}"#.utf8)
        let loaded = try JSONDecoder().decode(AppPreferences.self, from: legacy)
        XCTAssertEqual(loaded.batteryCare, .default)
        XCTAssertTrue(loaded.launchAtLoginEnabled)
    }

    func testBatteryCarePreferencesRoundTripContainsOnlyRegularIntent() throws {
        var expected = AppPreferences.default
        expected.batteryCare = try BatteryCareSettings(isEnabled: true, limit: 67)
        expected.showsHardwareBatteryPercentage = true
        let data = try JSONEncoder().encode(expected)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: data), expected)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let batteryCare = try XCTUnwrap(json["batteryCare"] as? [String: Any])
        XCTAssertEqual(Set(batteryCare.keys), ["isEnabled", "limit"])
    }

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
            energyImpactAppScope: .regularAndAccessory,
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
        XCTAssertEqual(AppPreferences.default.energyImpactAppScope, .regularOnly)
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

    func testLoadDefaultsEnergyImpactAppScopeWhenMissingFromStoredPreferences() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults.set(
            Data(#"{"selectedSummaryMetrics":["cpu","battery"],"launchAtLoginEnabled":false,"temperatureSource":"smc"}"#.utf8),
            forKey: "mac-activity.preferences"
        )
        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)

        XCTAssertEqual(
            store.load().energyImpactAppScope,
            .regularOnly
        )
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

    func testLoadIgnoresLegacyDashboardStyleWithoutResettingOtherPreferences() throws {
        let suiteName = "MacActivityCoreTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults.set(
            Data(
                #"{"selectedSummaryMetrics":["cpu","battery"],"launchAtLoginEnabled":true,"temperatureSource":"battery","dashboardStyle":"transparent","updateChannel":"beta"}"#
                    .utf8
            ),
            forKey: "mac-activity.preferences"
        )
        let store = UserDefaultsPreferencesStore(userDefaults: userDefaults)
        let loaded = store.load()

        XCTAssertEqual(loaded.temperatureSource, .battery)
        XCTAssertEqual(loaded.selectedSummaryMetrics, [.cpu, .battery])
        XCTAssertTrue(loaded.launchAtLoginEnabled)
        XCTAssertEqual(loaded.updateChannel, .beta)
    }

}
