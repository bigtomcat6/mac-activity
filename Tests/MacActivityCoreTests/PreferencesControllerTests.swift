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
}

private final class RecordingPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private var value: AppPreferences
    private(set) var savedValues: [AppPreferences] = []

    init(initial: AppPreferences) {
        self.value = initial
    }

    func load() -> AppPreferences {
        value
    }

    func save(_ preferences: AppPreferences) throws {
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
