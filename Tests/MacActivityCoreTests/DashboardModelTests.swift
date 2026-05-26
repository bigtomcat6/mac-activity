import XCTest
@testable import MacActivityCore

@MainActor
final class DashboardModelTests: XCTestCase {
    func testModelUsesSharedSnapshotAndHidesUnsupportedSensors() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 39.2)),
                .memory(MemoryReading(usedBytes: 8_589_934_592, totalBytes: 17_179_869_184)),
                .temperature(TemperatureReading(celsius: 55.1)),
                .unavailable(kind: .fan, reason: "Unsupported"),
            ],
            timestamp: Date(timeIntervalSince1970: 123)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.map(\.kind) == [.cpu, .memory, .temperature]
        }

        XCTAssertEqual(metrics.map(\.kind), [.cpu, .memory, .temperature])
        XCTAssertEqual(metrics.first?.value, "39%")
    }

    func testModelBuildsChartMetricsFromSharedHistory() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 25)),
                .memory(MemoryReading(usedBytes: 4_000, totalBytes: 8_000)),
                .network(NetworkReading(downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500)),
                .battery(BatteryReading(percentage: 80, isCharging: false)),
                .temperature(TemperatureReading(celsius: 55.1)),
            ],
            timestamp: Date(timeIntervalSince1970: 1)
        )
        store.apply(
            [
                .cpu(CPUReading(usagePercent: 40)),
                .memory(MemoryReading(usedBytes: 6_000, totalBytes: 8_000)),
                .network(NetworkReading(downloadBytesPerSecond: 2_000, uploadBytesPerSecond: 1_000)),
                .battery(BatteryReading(percentage: 78, isCharging: false)),
                .temperature(TemperatureReading(celsius: 57.4)),
            ],
            timestamp: Date(timeIntervalSince1970: 2)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .network }?.trend?.samples.count == 2
        }

        let cpu = try! XCTUnwrap(metrics.first { $0.kind == .cpu })
        let memory = try! XCTUnwrap(metrics.first { $0.kind == .memory })
        let network = try! XCTUnwrap(metrics.first { $0.kind == .network })
        let battery = try! XCTUnwrap(metrics.first { $0.kind == .battery })
        let temperature = try! XCTUnwrap(metrics.first { $0.kind == .temperature })

        XCTAssertEqual(cpu.style, .chart)
        XCTAssertEqual(try! XCTUnwrap(cpu.trend).scale, .fixed(lowerBound: 0, upperBound: 100))
        XCTAssertEqual(try! XCTUnwrap(cpu.trend).samples.map(\.primaryValue), [25, 40])

        XCTAssertEqual(memory.style, .memoryStackedChart)
        XCTAssertEqual(try! XCTUnwrap(memory.trend).scale, .fixed(lowerBound: 0, upperBound: 100))
        XCTAssertEqual(try! XCTUnwrap(memory.trend).samples.map(\.primaryValue), [50, 75])
        XCTAssertEqual(try! XCTUnwrap(memory.memoryTrend).samples.map(\.pressurePercent), [50, 75])

        XCTAssertEqual(battery.style, .chart)
        XCTAssertEqual(try! XCTUnwrap(battery.trend).scale, .fixed(lowerBound: 0, upperBound: 100))
        XCTAssertEqual(try! XCTUnwrap(battery.trend).samples.map(\.primaryValue), [80, 78])

        XCTAssertEqual(temperature.style, .chart)
        XCTAssertEqual(try! XCTUnwrap(temperature.trend).scale, .automatic)
        XCTAssertEqual(try! XCTUnwrap(temperature.trend).samples.map(\.primaryValue), [55.1, 57.4])

        XCTAssertEqual(network.style, .chart)
        XCTAssertEqual(try! XCTUnwrap(network.trend).scale, .automatic)
        XCTAssertEqual(try! XCTUnwrap(network.trend).samples.map(\.primaryValue), [1_000, 2_000])
        XCTAssertEqual(try! XCTUnwrap(network.trend).samples.map { $0.secondaryValue ?? -1 }, [500, 1_000])
        XCTAssertEqual(network.value, "↑ 1 KB/s  ↓ 2 KB/s")
        XCTAssertNil(network.secondaryText)
    }

    func testModelKeepsVRAMSeparateFromMemoryCardWhenBothAreAvailable() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .memory(
                    MemoryReading(
                        usedBytes: 6_000,
                        totalBytes: 10_000,
                        breakdown: MemoryBreakdown(
                            wiredBytes: 1_000,
                            activeBytes: 3_000,
                            compressedBytes: 2_000,
                            cachedBytes: 1_500,
                            availableBytes: 4_000
                        )
                    )
                ),
                .vram(VRAMReading(usedBytes: 2_000, totalBytes: 4_000)),
            ],
            timestamp: Date(timeIntervalSince1970: 6)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.contains { $0.kind == .memory }
        }
        let memory = try! XCTUnwrap(metrics.first { $0.kind == .memory })

        let vram = try! XCTUnwrap(metrics.first { $0.kind == .vram })
        XCTAssertEqual(memory.value, "60%")
        XCTAssertEqual(memory.secondaryText, "RAM 6 KB / 10 KB")
        XCTAssertEqual(try! XCTUnwrap(memory.memoryTrend).samples.last?.usedBytes, 6_000)
        XCTAssertEqual(vram.value, "2 KB")
        XCTAssertEqual(vram.detail, "of 4 KB")
    }

    func testModelUsesTemperatureSourceSpecificTitle() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .temperature(TemperatureReading(celsius: 30.2, source: .battery)),
            ],
            timestamp: Date(timeIntervalSince1970: 3)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.contains { $0.kind == .temperature }
        }
        let temperature = try! XCTUnwrap(metrics.first { $0.kind == .temperature })

        XCTAssertEqual(temperature.title, "Battery Temp")
        XCTAssertEqual(temperature.value, "30.2 C")
    }

    func testModelFormatsMemoryValueUsingDecimalUnits() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .memory(MemoryReading(usedBytes: 1_500_000_000, totalBytes: 3_000_000_000)),
            ],
            timestamp: Date(timeIntervalSince1970: 4)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.contains { $0.kind == .memory }
        }
        let memory = try! XCTUnwrap(metrics.first { $0.kind == .memory })

        XCTAssertEqual(memory.value, "50%")
        XCTAssertEqual(memory.secondaryText, "RAM 1.5 GB / 3 GB")
        XCTAssertEqual(memory.detail, "RAM 1.5 GB / 3 GB")
    }

    func testModelFormatsZeroRatesWithoutZeroWord() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .network(NetworkReading(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0)),
            ],
            timestamp: Date(timeIntervalSince1970: 5)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.contains { $0.kind == .network }
        }
        let network = try! XCTUnwrap(metrics.first { $0.kind == .network })

        XCTAssertEqual(network.value, "↑ 0 KB/s  ↓ 0 KB/s")
        XCTAssertNil(network.secondaryText)
        XCTAssertFalse(network.value.contains("Zero"))
    }

    func testMetricTextFormatterUsesDeterministicScalarFormatting() {
        XCTAssertEqual(DashboardMetricTextFormatter.formatBytes(0), "0 KB")
        XCTAssertEqual(DashboardMetricTextFormatter.formatBytes(1), "1 B")
        XCTAssertEqual(DashboardMetricTextFormatter.formatBytes(999), "999 B")
        XCTAssertEqual(DashboardMetricTextFormatter.formatBytes(1_500), "1.5 KB")
        XCTAssertEqual(DashboardMetricTextFormatter.formatBytes(1_500_000), "1.5 MB")
        XCTAssertEqual(DashboardMetricTextFormatter.formatBytes(1_500_000_000), "1.5 GB")

        XCTAssertEqual(DashboardMetricTextFormatter.formatRate(999), "999 B/s")
        XCTAssertEqual(DashboardMetricTextFormatter.formatRate(1_500), "1.5 KB/s")
    }

    func testModelDoesNotRepeatSlowTrendSamplesWhenOnlyFastMetricsRefresh() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 18)),
                .temperature(TemperatureReading(celsius: 50)),
            ],
            timestamp: Date(timeIntervalSince1970: 20)
        )
        store.apply(
            [
                .cpu(CPUReading(usagePercent: 42)),
            ],
            timestamp: Date(timeIntervalSince1970: 21)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            guard let cpu = metrics.first(where: { $0.kind == .cpu }),
                  let temperature = metrics.first(where: { $0.kind == .temperature }) else {
                return false
            }

            return cpu.trend?.samples.count == 2 && temperature.trend?.samples.count == 1
        }

        let cpu = try! XCTUnwrap(metrics.first { $0.kind == .cpu })
        let temperature = try! XCTUnwrap(metrics.first { $0.kind == .temperature })

        XCTAssertEqual(try! XCTUnwrap(cpu.trend).samples.map(\.primaryValue), [18, 42])
        XCTAssertEqual(try! XCTUnwrap(temperature.trend).samples.map(\.primaryValue), [50])
    }

    func testModelCanPauseAndResumeStoreSubscriptions() async {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        model.setActive(false)

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 12)),
            ],
            timestamp: Date(timeIntervalSince1970: 30)
        )

        XCTAssertTrue(model.metrics.isEmpty)

        model.setActive(true)

        let deadline = Date().addingTimeInterval(1)
        while model.metrics.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let cpu = try! XCTUnwrap(model.metrics.first { $0.kind == .cpu })
        XCTAssertEqual(cpu.value, "12%")
    }

    func testResumingInactiveModelDoesNotSynchronouslyBlockOnMetricsBuild() async {
        let store = MetricsStore()
        let model = DashboardModel(
            store: store,
            isActive: false,
            metricsBuilder: { snapshot, history in
                Thread.sleep(forTimeInterval: 0.2)
                return [
                    DashboardMetric(
                        kind: .cpu,
                        title: MetricKind.cpu.title,
                        value: "12%"
                    )
                ]
            }
        )

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 12)),
            ],
            timestamp: Date(timeIntervalSince1970: 40)
        )

        let startedAt = CFAbsoluteTimeGetCurrent()
        model.setActive(true)
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertLessThan(elapsed, 0.05)

        let deadline = Date().addingTimeInterval(1)
        while model.metrics.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let cpu = try! XCTUnwrap(model.metrics.first { $0.kind == .cpu })
        XCTAssertEqual(cpu.value, "12%")
    }

    func testStoreUpdatesDoNotSynchronouslyBlockOnMetricsBuild() async {
        let store = MetricsStore()
        let model = DashboardModel(
            store: store,
            isActive: false,
            metricsBuilder: { snapshot, history in
                Thread.sleep(forTimeInterval: 0.2)
                guard snapshot.cpu != nil else {
                    return []
                }

                return [
                    DashboardMetric(
                        kind: .cpu,
                        title: MetricKind.cpu.title,
                        value: "24%"
                    )
                ]
            }
        )

        model.setActive(true)

        let startedAt = CFAbsoluteTimeGetCurrent()
        store.apply(
            [
                .cpu(CPUReading(usagePercent: 24)),
            ],
            timestamp: Date(timeIntervalSince1970: 41)
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertLessThan(elapsed, 0.05)

        let deadline = Date().addingTimeInterval(1)
        while model.metrics.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let cpu = try! XCTUnwrap(model.metrics.first { $0.kind == .cpu })
        XCTAssertEqual(cpu.value, "24%")
    }

    func testSingleStoreApplyTriggersOneMetricsBuild() async {
        let store = MetricsStore()
        let counter = MetricsBuildCounter()
        let model = DashboardModel(
            store: store,
            isActive: false,
            metricsBuilder: { snapshot, _ in
                counter.increment()
                guard snapshot.cpu != nil else {
                    return []
                }

                return [
                    DashboardMetric(
                        kind: .cpu,
                        title: MetricKind.cpu.title,
                        value: "33%"
                    )
                ]
            }
        )

        model.setActive(true)
        let activationDeadline = Date().addingTimeInterval(1)
        while counter.currentValue != 1, Date() < activationDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(counter.currentValue, 1)
        counter.reset()

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 33)),
            ],
            timestamp: Date(timeIntervalSince1970: 42)
        )

        let deadline = Date().addingTimeInterval(1)
        while model.metrics.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(counter.currentValue, 1)
    }

    private func waitForMetrics(
        in model: DashboardModel,
        timeout: TimeInterval = 1,
        condition: ([DashboardMetric]) -> Bool
    ) async -> [DashboardMetric] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let metrics = model.metrics
            if condition(metrics) {
                return metrics
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return model.metrics
    }
}

private final class MetricsBuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var currentValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}
