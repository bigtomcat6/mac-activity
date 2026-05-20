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

        controller.setSummarySelection([.temperature, .cpu])

        XCTAssertEqual(controller.state.selectedSummaryMetrics, [.cpu, .temperature])
        XCTAssertEqual(store.savedValues.last?.selectedSummaryMetrics, [.cpu, .temperature])
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
