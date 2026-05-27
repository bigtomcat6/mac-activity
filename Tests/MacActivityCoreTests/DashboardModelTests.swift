import XCTest
@testable import MacActivityCore

@MainActor
final class DashboardModelTests: XCTestCase {
    func testModelBuildsMemoryStackedMetricAndOmitsVRAMCard() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 25)),
                .memory(
                    MemoryReading(
                        usedBytes: 6_442_450_944,
                        totalBytes: 10_737_418_240,
                        breakdown: MemoryBreakdown(
                            wiredBytes: 1_073_741_824,
                            activeBytes: 3_221_225_472,
                            compressedBytes: 2_147_483_648,
                            cachedBytes: 1_610_612_736,
                            availableBytes: 4_294_967_296
                        )
                    )
                ),
                .vram(VRAMReading(usedBytes: 2_147_483_648, totalBytes: 4_294_967_296)),
                .network(NetworkReading(downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500)),
            ],
            timestamp: Date(timeIntervalSince1970: 1)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.contains { $0.kind == .memory }
        }

        XCTAssertEqual(metrics.map(\.kind), [.cpu, .memory, .network])
        let memory = try! XCTUnwrap(metrics.first { $0.kind == .memory })
        XCTAssertEqual(memory.style, .memoryStackedChart)
        XCTAssertEqual(memory.value, "6.0GB/10.0GB (60%)")
        XCTAssertNil(memory.secondaryText)
        XCTAssertNil(memory.detail)
        XCTAssertEqual(try! XCTUnwrap(memory.memoryTrend).samples.last?.breakdown.activeBytes, 3_221_225_472)
    }

    func testModelPreservesHistoricalMemoryBreakdownForStackedBars() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [.memory(MemoryReading(usedBytes: 1_500, totalBytes: 3_000, breakdown: MemoryBreakdown(wiredBytes: 300, activeBytes: 900, compressedBytes: 300)))],
            timestamp: Date(timeIntervalSince1970: 7)
        )
        store.apply(
            [.memory(MemoryReading(usedBytes: 3_900, totalBytes: 6_000, breakdown: MemoryBreakdown(wiredBytes: 600, activeBytes: 2_400, compressedBytes: 900)))],
            timestamp: Date(timeIntervalSince1970: 8)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .memory }?.memoryTrend?.samples.count == 2
        }
        let memory = try! XCTUnwrap(metrics.first { $0.kind == .memory })
        let samples = try! XCTUnwrap(memory.memoryTrend).samples

        XCTAssertEqual(samples.map(\.usedBytes), [1_500, 3_900])
        XCTAssertEqual(samples.map(\.totalBytes), [3_000, 6_000])
        XCTAssertEqual(samples.map(\.breakdown.wiredBytes), [300, 600])
        XCTAssertEqual(samples.map(\.breakdown.activeBytes), [900, 2_400])
        XCTAssertEqual(samples.map(\.breakdown.compressedBytes), [300, 900])
    }

    func testMetricTextFormatterUsesExpectedScalarFormatting() {
        XCTAssertEqual(DashboardMetricTextFormatter.formatBytes(1_500_000_000), "1.5 GB")
        XCTAssertEqual(DashboardMetricTextFormatter.formatMemoryBytes(29_465_886_720), "27.4 GB")
        XCTAssertEqual(DashboardMetricTextFormatter.formatMemoryGB(1_610_612_736), "1.5GB")
        XCTAssertEqual(
            DashboardMetricTextFormatter.formatMemorySummary(
                usedBytes: 1_610_612_736,
                totalBytes: 3_221_225_472,
                percent: 50
            ),
            "1.5GB/3.0GB (50%)"
        )
        XCTAssertEqual(DashboardMetricTextFormatter.formatRate(1_500), "1.5 KB/s")
    }

    func testModelCanPauseAndResumeStoreSubscriptions() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        model.setActive(false)
        store.apply([.cpu(CPUReading(usagePercent: 12))], timestamp: Date(timeIntervalSince1970: 30))
        XCTAssertTrue(model.metrics.isEmpty)

        model.setActive(true)
        let metrics = await waitForMetrics(in: model) { !$0.isEmpty }
        let cpu = try! XCTUnwrap(metrics.first { $0.kind == .cpu })
        XCTAssertEqual(cpu.value, "12%")
    }

    private func waitForMetrics(
        in model: DashboardModel,
        timeout: TimeInterval = 1,
        condition: ([DashboardMetric]) -> Bool
    ) async -> [DashboardMetric] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let metrics = model.metrics
            if condition(metrics) { return metrics }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return model.metrics
    }
}
