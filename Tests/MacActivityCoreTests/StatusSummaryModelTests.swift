import Combine
import XCTest
@testable import MacActivityCore

@MainActor
final class StatusSummaryModelTests: XCTestCase {
    func testModelRendersSharedSnapshotUsingSelectedMetrics() {
        let store = MetricsStore(
            snapshot: MetricsSnapshot(
                timestamp: Date(timeIntervalSince1970: 100),
                cpu: CPUReading(usagePercent: 41.8),
                memory: MemoryReading(usedBytes: 8_000, totalBytes: 16_000),
                temperature: TemperatureReading(celsius: 54.4)
            )
        )
        let preferences = PreferencesController(
            store: InMemoryPreferencesStore(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: [.temperature, .cpu]
                )
            ),
            launchService: NoopLaunchAtLoginService()
        )

        let model = StatusSummaryModel(store: store, preferences: preferences)

        XCTAssertEqual(model.summaryText, "CPU 42% | CPU 54C")
    }

    func testModelPublishesOnlyWhenVisibleSummaryChanges() {
        let store = MetricsStore(
            snapshot: MetricsSnapshot(
                timestamp: Date(timeIntervalSince1970: 100),
                cpu: CPUReading(usagePercent: 41.4)
            )
        )
        let preferences = PreferencesController(
            store: InMemoryPreferencesStore(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: [.cpu]
                )
            ),
            launchService: NoopLaunchAtLoginService()
        )
        let model = StatusSummaryModel(store: store, preferences: preferences)
        var emitted: [String] = []
        let cancellable = model.$summaryText.dropFirst().sink { emitted.append($0) }

        store.apply([.cpu(CPUReading(usagePercent: 41.6))], timestamp: Date(timeIntervalSince1970: 101))
        store.apply([.cpu(CPUReading(usagePercent: 42.2))], timestamp: Date(timeIntervalSince1970: 102))

        XCTAssertEqual(emitted, ["CPU 42%"])
        _ = cancellable
    }

    func testModelUpdatesBatterySummaryWhenHardwareBatteryPreferenceChanges() {
        let store = MetricsStore(
            snapshot: MetricsSnapshot(
                timestamp: Date(timeIntervalSince1970: 100),
                battery: BatteryReading(
                    percentage: 79,
                    isCharging: false,
                    hardwarePercentage: 74.51
                )
            )
        )
        let preferences = PreferencesController(
            store: InMemoryPreferencesStore(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: [.battery],
                    showsHardwareBatteryPercentage: false
                )
            ),
            launchService: NoopLaunchAtLoginService()
        )
        let model = StatusSummaryModel(store: store, preferences: preferences)

        XCTAssertEqual(model.summaryText, "BAT 79%")

        preferences.setShowsHardwareBatteryPercentage(true)

        XCTAssertEqual(model.summaryText, "BAT 75%")
        XCTAssertEqual(model.summaryItems.first?.primaryText, "75%")
    }

    func testModelAcceptsLegacySummaryFormatterWhenHardwareBatteryPreferenceEnabled() {
        let store = MetricsStore(
            snapshot: MetricsSnapshot(
                timestamp: Date(timeIntervalSince1970: 100),
                battery: BatteryReading(
                    percentage: 79,
                    isCharging: false,
                    hardwarePercentage: 74.51
                )
            )
        )
        let preferences = PreferencesController(
            store: InMemoryPreferencesStore(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: [.battery],
                    showsHardwareBatteryPercentage: true
                )
            ),
            launchService: NoopLaunchAtLoginService()
        )
        let model = StatusSummaryModel(
            store: store,
            preferences: preferences,
            formatter: LegacySummaryFormatter()
        )

        XCTAssertEqual(model.summaryText, "legacy")
        XCTAssertEqual(model.summaryItems, [])
    }
}

private struct LegacySummaryFormatter: SummaryFormatting {
    func render(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource
    ) -> String {
        "legacy"
    }

    func renderStatusItems(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource
    ) -> [StatusSummaryItem] {
        []
    }
}

private final class InMemoryPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private var value: AppPreferences

    init(initial: AppPreferences) {
        self.value = initial
    }

    func load() -> AppPreferences {
        value
    }

    func save(_ preferences: AppPreferences) throws {
        value = preferences
    }
}
