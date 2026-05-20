import XCTest
@testable import MacActivityCore

final class SummaryFormatterTests: XCTestCase {
    func testRenderUsesFixedMvpOrderingAndCompactFormatting() {
        let snapshot = MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 500),
            cpu: CPUReading(usagePercent: 41.8),
            memory: MemoryReading(usedBytes: 12_884_901_888, totalBytes: 34_359_738_368),
            battery: BatteryReading(percentage: 82, isCharging: true),
            temperature: TemperatureReading(celsius: 54.4)
        )

        let summary = SummaryFormatter().render(
            snapshot: snapshot,
            selectedMetrics: [.temperature, .battery, .cpu]
        )

        XCTAssertEqual(summary, "CPU 42% | BAT 82% | TMP 54C")
    }

    func testRenderStatusItemsUsesTwoLineMenuBarFormatting() {
        let snapshot = MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 600),
            cpu: CPUReading(usagePercent: 6.6),
            memory: MemoryReading(usedBytes: 12_884_901_888, totalBytes: 34_359_738_368),
            network: NetworkReading(downloadBytesPerSecond: 15_400, uploadBytesPerSecond: 13_800),
            temperature: TemperatureReading(celsius: 40.8),
            fan: FanReading(rpm: 0)
        )

        let items = SummaryFormatter().renderStatusItems(
            snapshot: snapshot,
            selectedMetrics: [.network, .fan, .temperature, .memory, .cpu]
        )

        XCTAssertEqual(
            items,
            [
                StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
                StatusSummaryItem(kind: .memory, primaryText: "38%", secondaryText: "MEM", style: .metric),
                StatusSummaryItem(kind: .temperature, primaryText: "41℃", secondaryText: "SEN", style: .metric),
                StatusSummaryItem(kind: .fan, primaryText: "0", secondaryText: "RPM", style: .metric),
                StatusSummaryItem(kind: .network, primaryText: "↑13.8 K/s", secondaryText: "↓15.4 K/s", style: .network),
            ]
        )
    }
}
