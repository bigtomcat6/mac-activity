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

        XCTAssertEqual(summary, "CPU 42% | TMP 54C | BAT 82%")
    }

    func testRenderStatusItemsUsesTwoLineMenuBarFormatting() {
        let snapshot = MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 600),
            cpu: CPUReading(usagePercent: 6.6),
            gpu: GPUReading(usagePercent: 12.9),
            memory: MemoryReading(usedBytes: 12_884_901_888, totalBytes: 34_359_738_368),
            vram: VRAMReading(usedBytes: 2_147_483_648, totalBytes: 8_589_934_592),
            network: NetworkReading(downloadBytesPerSecond: 15_400, uploadBytesPerSecond: 13_800),
            temperature: TemperatureReading(celsius: 40.8),
            fan: FanReading(rpm: 0)
        )

        let items = SummaryFormatter().renderStatusItems(
            snapshot: snapshot,
            selectedMetrics: [.network, .fan, .temperature, .vram, .memory, .gpu, .cpu]
        )

        XCTAssertEqual(
            items,
            [
                StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
                StatusSummaryItem(kind: .gpu, primaryText: "13%", secondaryText: "GPU", style: .metric),
                StatusSummaryItem(kind: .memory, primaryText: "38%", secondaryText: "MEM", style: .metric),
                StatusSummaryItem(kind: .vram, primaryText: "25%", secondaryText: "VRAM", style: .metric),
                StatusSummaryItem(kind: .temperature, primaryText: "41℃", secondaryText: "SEN", style: .metric),
                StatusSummaryItem(kind: .fan, primaryText: "0", secondaryText: "RPM", style: .metric),
                StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓15.4K", style: .network),
            ]
        )
    }

    func testRenderStatusItemsUsesBatteryLabelForBatteryTemperatureSource() {
        let snapshot = MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 601),
            temperature: TemperatureReading(celsius: 30.2, source: .battery)
        )

        let items = SummaryFormatter().renderStatusItems(
            snapshot: snapshot,
            selectedMetrics: [.temperature]
        )

        XCTAssertEqual(
            items,
            [
                StatusSummaryItem(kind: .temperature, primaryText: "30℃", secondaryText: "BAT", style: .metric),
            ]
        )
    }

    func testRenderStatusItemsUsesCompactGigabyteNetworkSuffixForMenuBar() {
        let snapshot = MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 650),
            network: NetworkReading(downloadBytesPerSecond: 1_500_000_000, uploadBytesPerSecond: 2_300_000_000)
        )

        let items = SummaryFormatter().renderStatusItems(
            snapshot: snapshot,
            selectedMetrics: [.network]
        )

        XCTAssertEqual(
            items,
            [
                StatusSummaryItem(kind: .network, primaryText: "↑2.3G", secondaryText: "↓1.5G", style: .network),
            ]
        )
    }

    func testRenderStatusItemsShowsPlaceholdersForUnavailableSelectedMetrics() {
        let items = SummaryFormatter().renderStatusItems(
            snapshot: MetricsSnapshot(timestamp: Date(timeIntervalSince1970: 700)),
            selectedMetrics: [.cpu, .gpu, .memory, .vram, .temperature, .fan, .network]
        )

        XCTAssertEqual(
            items,
            [
                StatusSummaryItem(kind: .cpu, primaryText: "--", secondaryText: "CPU", style: .metric),
                StatusSummaryItem(kind: .gpu, primaryText: "--", secondaryText: "GPU", style: .metric),
                StatusSummaryItem(kind: .memory, primaryText: "--", secondaryText: "MEM", style: .metric),
                StatusSummaryItem(kind: .vram, primaryText: "--", secondaryText: "VRAM", style: .metric),
                StatusSummaryItem(kind: .temperature, primaryText: "--", secondaryText: "SEN", style: .metric),
                StatusSummaryItem(kind: .fan, primaryText: "--", secondaryText: "RPM", style: .metric),
                StatusSummaryItem(kind: .network, primaryText: "↑--", secondaryText: "↓--", style: .network),
            ]
        )
    }
}
