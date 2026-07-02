import XCTest
@testable import MacActivityCore

@MainActor
final class DashboardModelTests: XCTestCase {
    func testModelBuildsMemoryStackedMetricAndOmitsVRAMCard() async throws {
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
                .network(NetworkReading(downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500))
            ],
            timestamp: Date(timeIntervalSince1970: 1)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.contains { $0.kind == .memory }
        }

        XCTAssertEqual(metrics.map(\.kind), [.cpu, .memory, .network])
        let memory = try XCTUnwrap(metrics.first { $0.kind == .memory })
        XCTAssertEqual(memory.style, .memoryStackedChart)
        XCTAssertEqual(memory.value, "6.0GB/10.0GB (60%)")
        XCTAssertNil(memory.secondaryText)
        XCTAssertNil(memory.detail)
        XCTAssertEqual(try XCTUnwrap(memory.memoryTrend).samples.last?.breakdown.activeBytes, 3_221_225_472)
    }

    func testModelBuildsDiskAndSwapMetricsForOverviewUsageArea() async throws {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 25)),
                .gpu(GPUReading(usagePercent: 50)),
                .disk(DiskReading(usedBytes: 750, totalBytes: 1_000)),
                .swap(SwapReading(usedBytes: 256, totalBytes: 1_024))
            ],
            timestamp: Date(timeIntervalSince1970: 11)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.contains { $0.kind == .swap }
        }

        XCTAssertEqual(metrics.map(\.kind), [.cpu, .gpu, .disk, .swap])
        let disk = try XCTUnwrap(metrics.first { $0.kind == .disk })
        XCTAssertEqual(disk.titleRole, .metric(.disk))
        XCTAssertEqual(disk.title, "Disk")
        XCTAssertEqual(disk.value, "75%")
        XCTAssertEqual(disk.usedBytes, 750)
        XCTAssertEqual(disk.totalBytes, 1_000)
        XCTAssertEqual(try XCTUnwrap(disk.progress), 0.75, accuracy: 0.001)
        XCTAssertEqual(disk.detailRole, .raw("750 B (75%)"))
        XCTAssertEqual(disk.detail, "750 B (75%)")

        let swap = try XCTUnwrap(metrics.first { $0.kind == .swap })
        XCTAssertEqual(swap.titleRole, .metric(.swap))
        XCTAssertEqual(swap.title, "Swap")
        XCTAssertEqual(swap.value, "25%")
        XCTAssertEqual(swap.usedBytes, 256)
        XCTAssertEqual(swap.totalBytes, 1_024)
        XCTAssertEqual(try XCTUnwrap(swap.progress), 0.25, accuracy: 0.001)
        XCTAssertEqual(swap.detailRole, .raw("256 B (25%)"))
        XCTAssertEqual(swap.detail, "256 B (25%)")
    }

    func testModelBuildsZeroSwapUsageDetailWithoutDividingByTotal() async throws {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [.swap(SwapReading(usedBytes: 0, totalBytes: 0))],
            timestamp: Date(timeIntervalSince1970: 12)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.contains { $0.kind == .swap }
        }

        let swap = try XCTUnwrap(metrics.first { $0.kind == .swap })
        XCTAssertEqual(swap.value, "0%")
        XCTAssertEqual(try XCTUnwrap(swap.progress), 0.0, accuracy: 0.001)
        XCTAssertEqual(swap.detailRole, .raw("0 KB (0%)"))
        XCTAssertEqual(swap.detail, "0 KB (0%)")
    }

    func testTemperatureMetricIDIncludesSelectedTemperatureSource() {
        let cpu = DashboardMetric(
            kind: .temperature,
            titleRole: .temperature(.smc),
            value: "32.0 C"
        )
        let battery = DashboardMetric(
            kind: .temperature,
            titleRole: .temperature(.battery),
            value: "31.0 C"
        )

        XCTAssertEqual(cpu.id, "temperature-smc")
        XCTAssertEqual(battery.id, "temperature-battery")
    }

    func testModelBuildsFanMetricWhenFanReadingExists() async throws {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [.fan(FanReading(rpm: 1_800))],
            timestamp: Date(timeIntervalSince1970: 13)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.contains { $0.kind == .fan }
        }
        let fan = try XCTUnwrap(metrics.first { $0.kind == .fan })

        XCTAssertEqual(fan.titleRole, .metric(.fan))
        XCTAssertEqual(fan.title, "Fan")
        XCTAssertEqual(fan.value, "1800 RPM")
        XCTAssertEqual(fan.style, .chart)
        XCTAssertNotNil(fan.trend)
    }

    func testModelPreservesHistoricalMemoryBreakdownForStackedBars() async throws {
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
        let memory = try XCTUnwrap(metrics.first { $0.kind == .memory })
        let samples = try XCTUnwrap(memory.memoryTrend).samples

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

    func testModelCanPauseAndResumeStoreSubscriptions() async throws {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        model.setActive(false)
        store.apply([.cpu(CPUReading(usagePercent: 12))], timestamp: Date(timeIntervalSince1970: 30))
        XCTAssertTrue(model.metrics.isEmpty)

        model.setActive(true)
        let metrics = await waitForMetrics(in: model) { !$0.isEmpty }
        let cpu = try XCTUnwrap(metrics.first { $0.kind == .cpu })
        XCTAssertEqual(cpu.value, "12%")
    }

    func testBatteryTrendDoesNotExposeHardwarePercentageAsSecondarySeriesByDefault() async throws {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .battery(BatteryReading(percentage: 79, isCharging: false, hardwarePercentage: 74.51))
            ],
            timestamp: Date(timeIntervalSince1970: 30)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .battery }?.trend?.samples.isEmpty == false
        }
        let battery = try XCTUnwrap(metrics.first { $0.kind == .battery })
        let sample = try XCTUnwrap(battery.trend?.samples.first)

        XCTAssertEqual(sample.primaryValue, 79, accuracy: 0.001)
        XCTAssertNil(sample.secondaryValue)
    }

    func testBatteryTrendCarriesConnectedPowerState() async throws {
        let store = MetricsStore()
        let model = DashboardModel(store: store)
        let start = Date(timeIntervalSince1970: 40)

        store.apply(
            [.battery(BatteryReading(percentage: 78, isCharging: false))],
            timestamp: start
        )
        store.apply(
            [.battery(BatteryReading(percentage: 79, isCharging: false, isConnectedToPower: true))],
            timestamp: start.addingTimeInterval(15)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .battery }?.trend?.samples.count == 2
        }
        let battery = try XCTUnwrap(metrics.first { $0.kind == .battery })

        XCTAssertEqual(battery.trend?.samples.map(\.batteryIsConnectedToPower), [false, true])
        XCTAssertEqual(battery.detailRole, .batteryConnectedToPower)
    }

    func testBatteryMetricUsesSystemPercentageWhenHardwareDisplayIsDisabled() async throws {
        let store = MetricsStore()
        let preferences = PreferencesController(
            store: InMemoryDashboardPreferencesStore(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: [.battery],
                    showsHardwareBatteryPercentage: false
                )
            ),
            launchService: NoopLaunchAtLoginService()
        )
        let model = DashboardModel(store: store, preferences: preferences)

        store.apply(
            [
                .battery(BatteryReading(percentage: 79, isCharging: false, hardwarePercentage: 74.51))
            ],
            timestamp: Date(timeIntervalSince1970: 20)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .battery }?.value == "79%"
        }
        let battery = try XCTUnwrap(metrics.first { $0.kind == .battery })

        XCTAssertEqual(battery.value, "79%")
        XCTAssertEqual(battery.detailRole, .batteryOnBattery)
        XCTAssertEqual(battery.trend?.samples.map(\.primaryValue), [79])
    }

    func testBatteryMetricUsesHardwarePercentageWhenPreferenceIsEnabled() async throws {
        let store = MetricsStore()
        let preferences = PreferencesController(
            store: InMemoryDashboardPreferencesStore(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: [.battery],
                    showsHardwareBatteryPercentage: true
                )
            ),
            launchService: NoopLaunchAtLoginService()
        )
        let model = DashboardModel(store: store, preferences: preferences)

        store.apply(
            [
                .battery(BatteryReading(percentage: 79, isCharging: false, hardwarePercentage: 74.51))
            ],
            timestamp: Date(timeIntervalSince1970: 21)
        )

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .battery }?.value == "75%"
        }
        let battery = try XCTUnwrap(metrics.first { $0.kind == .battery })

        XCTAssertEqual(battery.value, "75%")
        XCTAssertEqual(battery.trend?.samples.map(\.primaryValue), [74.51])
    }

    func testBatteryMetricUpdatesImmediatelyWhenHardwarePreferenceChanges() async {
        let store = MetricsStore()
        let preferences = PreferencesController(
            store: InMemoryDashboardPreferencesStore(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: [.battery],
                    showsHardwareBatteryPercentage: false
                )
            ),
            launchService: NoopLaunchAtLoginService()
        )
        let model = DashboardModel(store: store, preferences: preferences)

        store.apply(
            [
                .battery(BatteryReading(percentage: 79, isCharging: false, hardwarePercentage: 74.51))
            ],
            timestamp: Date(timeIntervalSince1970: 22)
        )
        _ = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .battery }?.value == "79%"
        }

        preferences.setShowsHardwareBatteryPercentage(true)

        let metrics = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .battery }?.value == "75%"
        }

        XCTAssertEqual(metrics.first { $0.kind == .battery }?.trend?.samples.map(\.primaryValue), [74.51])
    }

    func testTemperatureMetricSwitchesPreferredSourceTrendImmediately() async throws {
        let store = MetricsStore()
        let preferences = PreferencesController(
            store: InMemoryDashboardPreferencesStore(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: [.temperature],
                    temperatureSource: .battery
                )
            ),
            launchService: NoopLaunchAtLoginService()
        )
        let model = DashboardModel(store: store, preferences: preferences)
        let start = Date(timeIntervalSince1970: 2_000)

        store.apply(
            [
                .temperatures([
                    TemperatureReading(celsius: 55, source: .smc),
                    TemperatureReading(celsius: 30, source: .battery)
                ])
            ],
            timestamp: start
        )
        store.apply(
            [
                .temperatures([
                    TemperatureReading(celsius: 56, source: .smc),
                    TemperatureReading(celsius: 31, source: .battery)
                ])
            ],
            timestamp: start.addingTimeInterval(2)
        )

        let batteryMetrics = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .temperature }?.trend?.samples.map(\.primaryValue) == [30, 31]
        }
        let batteryTemperature = try XCTUnwrap(batteryMetrics.first { $0.kind == .temperature })
        XCTAssertEqual(batteryTemperature.titleRole, .temperature(.battery))
        XCTAssertEqual(batteryTemperature.title, TemperatureSource.battery.dashboardTitle)
        XCTAssertEqual(batteryTemperature.value, "31.0 C")

        preferences.setTemperatureSource(.smc)

        let smcMetrics = await waitForMetrics(in: model) { metrics in
            metrics.first { $0.kind == .temperature }?.trend?.samples.map(\.primaryValue) == [55, 56]
        }
        let smcTemperature = try XCTUnwrap(smcMetrics.first { $0.kind == .temperature })
        XCTAssertEqual(smcTemperature.titleRole, .temperature(.smc))
        XCTAssertEqual(smcTemperature.title, TemperatureSource.smc.dashboardTitle)
        XCTAssertEqual(smcTemperature.value, "56.0 C")
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

private final class InMemoryDashboardPreferencesStore: PreferencesStoring, @unchecked Sendable {
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
