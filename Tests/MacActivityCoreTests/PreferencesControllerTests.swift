import XCTest
@testable import MacActivityCore

@MainActor
final class PreferencesControllerTests: XCTestCase {
    func testSummarySelectionPersistsInFixedOrder() {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        controller.setSummarySelection([.temperature, .vram, .cpu])

        XCTAssertEqual(controller.state.selectedSummaryMetrics, [.cpu, .vram, .temperature])
        XCTAssertEqual(store.savedValues.last?.selectedSummaryMetrics, [.cpu, .vram, .temperature])
    }

    func testLaunchAtLoginFailureStaysInPreferencesState() {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: FailingLaunchService()
        )

        controller.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(controller.state.launchAtLoginEnabled, true)
        XCTAssertEqual(controller.launchAtLoginError, "Registration failed")
        XCTAssertEqual(store.savedValues.last?.launchAtLoginEnabled, true)
    }

    func testTemperatureSourcePersistsToPreferencesState() {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        controller.setTemperatureSource(.battery)

        XCTAssertEqual(controller.state.temperatureSource, .battery)
        XCTAssertEqual(store.savedValues.last?.temperatureSource, .battery)
    }

    func testHardwareBatteryPercentagePreferencePersistsToPreferencesState() {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        controller.setShowsHardwareBatteryPercentage(true)

        XCTAssertEqual(controller.state.showsHardwareBatteryPercentage, true)
        XCTAssertEqual(store.savedValues.last?.showsHardwareBatteryPercentage, true)
    }

    func testProcessApplicationIdentifierPreferencePersistsToPreferencesState() {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        controller.setShowsProcessApplicationIdentifier(true)

        XCTAssertEqual(controller.state.showsProcessApplicationIdentifier, true)
        XCTAssertEqual(store.savedValues.last?.showsProcessApplicationIdentifier, true)
    }

    func testUpdateChannelPersistsToPreferencesState() {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        controller.setUpdateChannel(.beta)

        XCTAssertEqual(controller.state.updateChannel, .beta)
        XCTAssertEqual(store.savedValues.last?.updateChannel, .beta)
    }

    func testUpdateChannelSyncsOnlyWhenInstalledReleaseTagChanges() throws {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        controller.syncUpdateChannelWithInstalledVersion(try ReleaseVersion("v26.0.0-beta.2"))

        XCTAssertEqual(controller.state.updateChannel, .beta)
        XCTAssertEqual(controller.state.lastSyncedUpdateChannelReleaseTag, "v26.0.0-beta.2")

        controller.setUpdateChannel(.release)
        controller.syncUpdateChannelWithInstalledVersion(try ReleaseVersion("v26.0.0-beta.2"))

        XCTAssertEqual(controller.state.updateChannel, .release)

        controller.syncUpdateChannelWithInstalledVersion(try ReleaseVersion("v26.0.0-alpha.3"))

        XCTAssertEqual(controller.state.updateChannel, .alpha)
        XCTAssertEqual(controller.state.lastSyncedUpdateChannelReleaseTag, "v26.0.0-alpha.3")
        XCTAssertEqual(store.savedValues.last?.updateChannel, .alpha)
    }

    func testPreferredLanguageIdentifierPersistsToPreferencesState() {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        controller.setPreferredLanguageIdentifier("zh-Hans")

        XCTAssertEqual(controller.state.preferredLanguageIdentifier, "zh-Hans")
        XCTAssertEqual(store.savedValues.last?.preferredLanguageIdentifier, "zh-Hans")
    }
    func testDiskCleanupCategoriesPersistToPreferencesStateInDisplayOrder() {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        controller.setDiskCleanupCategory(.userLogs, isSelected: true)
        controller.setDiskCleanupCategory(.trash, isSelected: true)
        controller.setDiskCleanupCategory(.userCaches, isSelected: false)

        XCTAssertEqual(controller.state.diskCleanupCategories, [.trash, .userLogs])
        XCTAssertEqual(store.savedValues.last?.diskCleanupCategories, [.trash, .userLogs])
    }

    func testNondefaultProfileIsPersistedByController() throws {
        let store = RecordingPreferencesStore(initial: .default)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.Player",
            volume: 0.4
        )

        try controller.setAudioProcessProfile(profile, for: "com.example.Player")

        XCTAssertEqual(controller.state.audioProcessProfiles["com.example.Player"], profile)
        XCTAssertEqual(store.savedValues.last?.audioProcessProfiles["com.example.Player"], profile)
    }

    func testDefaultProfileIsRemovedByController() throws {
        let bundleIdentifier = "com.example.Player"
        var initial = AppPreferences.default
        initial.audioProcessProfiles[bundleIdentifier] = AudioProcessProfile(
            bundleIdentifier: bundleIdentifier,
            volume: 0.4
        )
        let store = RecordingPreferencesStore(initial: initial)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        try controller.setAudioProcessProfile(
            AudioProcessProfile(bundleIdentifier: bundleIdentifier),
            for: bundleIdentifier
        )

        XCTAssertNil(controller.state.audioProcessProfiles[bundleIdentifier])
        XCTAssertNil(store.savedValues.last?.audioProcessProfiles[bundleIdentifier])
    }

    func testNilProfileIsRemovedByController() throws {
        let bundleIdentifier = "com.example.Player"
        var initial = AppPreferences.default
        initial.audioProcessProfiles[bundleIdentifier] = AudioProcessProfile(
            bundleIdentifier: bundleIdentifier,
            isMuted: true
        )
        let store = RecordingPreferencesStore(initial: initial)
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )

        try controller.setAudioProcessProfile(nil, for: bundleIdentifier)

        XCTAssertNil(controller.state.audioProcessProfiles[bundleIdentifier])
        XCTAssertNil(store.savedValues.last?.audioProcessProfiles[bundleIdentifier])
    }

    func testProfileStateRollsBackWhenStoreSaveFails() {
        let store = RecordingPreferencesStore(
            initial: .default,
            saveError: PreferencesStoreError.saveFailed("Disk full")
        )
        let controller = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.Player",
            volume: 0.4
        )

        XCTAssertThrowsError(
            try controller.setAudioProcessProfile(profile, for: "com.example.Player")
        )

        XCTAssertEqual(controller.state, .default)
        XCTAssertEqual(store.saveAttempts, 1)
        XCTAssertEqual(store.savedValues, [])
    }
}

private final class RecordingPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private var value: AppPreferences
    private(set) var savedValues: [AppPreferences] = []
    private(set) var saveAttempts = 0
    private let saveError: PreferencesStoreError?

    init(initial: AppPreferences, saveError: PreferencesStoreError? = nil) {
        self.value = initial
        self.saveError = saveError
    }

    func load() -> AppPreferences {
        value
    }

    func save(_ preferences: AppPreferences) throws {
        saveAttempts += 1
        if let saveError {
            throw saveError
        }
        value = preferences
        savedValues.append(preferences)
    }
}

private struct FailingLaunchService: LaunchAtLoginServicing {
    func setEnabled(_ enabled: Bool) throws {
        throw Failure.registrationFailed
    }

    func currentStatus() -> Bool {
        false
    }

    private enum Failure: LocalizedError {
        case registrationFailed

        var errorDescription: String? {
            "Registration failed"
        }
    }
}
