import Combine
import Foundation

public enum DashboardMetricStyle: Equatable, Sendable {
    case chart
    case memoryStackedChart
    case value
}

public enum DashboardMetricTitleRole: Equatable, Sendable {
    case metric(MetricKind)
    case temperature(TemperatureSource)
}

public enum DashboardMetricDetailRole: Equatable, Sendable {
    case batteryCharging
    case batteryOnBattery
    case raw(String)
}

public enum DashboardTrendScale: Equatable, Sendable {
    case automatic
    case fixed(lowerBound: Double, upperBound: Double)
}

public struct DashboardTrendSample: Equatable, Sendable {
    public var timestamp: Date
    public var primaryValue: Double
    public var secondaryValue: Double?

    public init(timestamp: Date, primaryValue: Double, secondaryValue: Double? = nil) {
        self.timestamp = timestamp
        self.primaryValue = primaryValue
        self.secondaryValue = secondaryValue
    }
}

public struct DashboardTrend: Equatable, Sendable {
    public var samples: [DashboardTrendSample]
    public var scale: DashboardTrendScale

    public init(samples: [DashboardTrendSample], scale: DashboardTrendScale) {
        self.samples = samples
        self.scale = scale
    }
}

public struct DashboardMemoryTrendSample: Equatable, Sendable {
    public var timestamp: Date
    public var pressurePercent: Double
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var breakdown: MemoryBreakdown

    public init(
        timestamp: Date,
        pressurePercent: Double,
        usedBytes: UInt64,
        totalBytes: UInt64,
        breakdown: MemoryBreakdown = MemoryBreakdown()
    ) {
        self.timestamp = timestamp
        self.pressurePercent = pressurePercent
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.breakdown = breakdown
    }
}

public struct DashboardMemoryTrend: Equatable, Sendable {
    public var samples: [DashboardMemoryTrendSample]

    public init(samples: [DashboardMemoryTrendSample]) {
        self.samples = samples
    }
}

public struct DashboardMetric: Identifiable, Equatable, Sendable {
    public var kind: MetricKind
    public var titleRole: DashboardMetricTitleRole
    public var title: String
    public var value: String
    public var secondaryText: String?
    public var detailRole: DashboardMetricDetailRole?
    public var detail: String?
    public var usedBytes: UInt64?
    public var totalBytes: UInt64?
    public var progress: Double?
    public var style: DashboardMetricStyle
    public var trend: DashboardTrend?
    public var memoryTrend: DashboardMemoryTrend?

    public var id: String {
        switch titleRole {
        case .metric(let kind):
            return kind.rawValue
        case .temperature(let source):
            return "\(MetricKind.temperature.rawValue)-\(source.rawValue)"
        }
    }

    public init(
        kind: MetricKind,
        titleRole: DashboardMetricTitleRole? = nil,
        value: String,
        secondaryText: String? = nil,
        detailRole: DashboardMetricDetailRole? = nil,
        title: String? = nil,
        detail: String? = nil,
        usedBytes: UInt64? = nil,
        totalBytes: UInt64? = nil,
        progress: Double? = nil,
        style: DashboardMetricStyle = .value,
        trend: DashboardTrend? = nil,
        memoryTrend: DashboardMemoryTrend? = nil
    ) {
        self.kind = kind
        self.titleRole = titleRole ?? .metric(kind)
        self.title = title ?? kind.title
        self.value = value
        self.secondaryText = secondaryText
        self.detailRole = detailRole
        self.detail = detail
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.progress = progress
        self.style = style
        self.trend = trend
        self.memoryTrend = memoryTrend
    }

    public init(
        kind: MetricKind,
        title: String,
        value: String,
        secondaryText: String? = nil,
        detail: String? = nil,
        usedBytes: UInt64? = nil,
        totalBytes: UInt64? = nil,
        progress: Double? = nil,
        style: DashboardMetricStyle = .value,
        trend: DashboardTrend? = nil,
        memoryTrend: DashboardMemoryTrend? = nil
    ) {
        self.init(
            kind: kind,
            titleRole: .metric(kind),
            value: value,
            secondaryText: secondaryText,
            title: title,
            detail: detail,
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            progress: progress,
            style: style,
            trend: trend,
            memoryTrend: memoryTrend
        )
    }
}

private struct DashboardDisplayPreferences: Equatable {
    var temperatureSource: TemperatureSource
    var showsHardwareBatteryPercentage: Bool
}

@MainActor
public final class DashboardModel: ObservableObject {
    @Published public private(set) var metrics: [DashboardMetric]
    private let store: MetricsStore
    private let metricsBuilder: @Sendable (MetricsSnapshot, MetricsHistory, TemperatureSource, Bool) -> [DashboardMetric]
    private var subscription: AnyCancellable?
    private var temperatureSourceSubscription: AnyCancellable?
    private var refreshGeneration = 0
    private var isActive: Bool
    private var preferredTemperatureSource: TemperatureSource
    private var showsHardwareBatteryPercentage: Bool

    public convenience init(store: MetricsStore, isActive: Bool = true) {
        self.init(
            store: store,
            isActive: isActive,
            preferredTemperatureSource: .smc,
            showsHardwareBatteryPercentage: false,
            metricsBuilder: DashboardModel.buildMetrics
        )
    }

    public convenience init(
        store: MetricsStore,
        preferences: PreferencesController,
        isActive: Bool = true
    ) {
        self.init(
            store: store,
            isActive: isActive,
            preferredTemperatureSource: preferences.state.temperatureSource,
            showsHardwareBatteryPercentage: preferences.state.showsHardwareBatteryPercentage,
            metricsBuilder: DashboardModel.buildMetrics
        )
        temperatureSourceSubscription = preferences.$state
            .map { state in
                DashboardDisplayPreferences(
                    temperatureSource: state.temperatureSource,
                    showsHardwareBatteryPercentage: state.showsHardwareBatteryPercentage
                )
            }
            .removeDuplicates()
            .sink { [weak self] preferences in
                self?.setDisplayPreferences(preferences)
            }
    }

    init(
        store: MetricsStore,
        isActive: Bool = true,
        preferredTemperatureSource: TemperatureSource = .smc,
        showsHardwareBatteryPercentage: Bool = false,
        metricsBuilder: @escaping @Sendable (MetricsSnapshot, MetricsHistory, TemperatureSource, Bool) -> [DashboardMetric]
    ) {
        self.store = store
        self.metricsBuilder = metricsBuilder
        self.isActive = isActive
        self.preferredTemperatureSource = preferredTemperatureSource
        self.showsHardwareBatteryPercentage = showsHardwareBatteryPercentage
        self.metrics = isActive ? metricsBuilder(store.snapshot, store.history, preferredTemperatureSource, showsHardwareBatteryPercentage) : []
        if isActive { startSubscription() }
    }

    public func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else { return }
        self.isActive = isActive
        if isActive {
            startSubscription()
            refreshMetricsAsync()
        } else {
            subscription = nil
            refreshGeneration += 1
            metrics = []
        }
    }

    private func setDisplayPreferences(_ displayPreferences: DashboardDisplayPreferences) {
        let changed = preferredTemperatureSource != displayPreferences.temperatureSource ||
            showsHardwareBatteryPercentage != displayPreferences.showsHardwareBatteryPercentage
        guard changed else { return }

        preferredTemperatureSource = displayPreferences.temperatureSource
        showsHardwareBatteryPercentage = displayPreferences.showsHardwareBatteryPercentage
        if isActive {
            refreshMetricsAsync()
        }
    }

    nonisolated private static func buildMetrics(
        from snapshot: MetricsSnapshot,
        history: MetricsHistory,
        preferredTemperatureSource: TemperatureSource,
        showsHardwareBatteryPercentage: Bool
    ) -> [DashboardMetric] {
        var items: [DashboardMetric] = []

        if let cpu = snapshot.cpu {
            items.append(
                DashboardMetric(
                    kind: .cpu,
                    titleRole: .metric(.cpu),
                    value: "\(Int(cpu.usagePercent.rounded()))%",
                    title: MetricKind.cpu.title,
                    progress: progressFraction(for: cpu.usagePercent),
                    style: .chart,
                    trend: trend(from: history, kind: .cpu, scale: .fixed(lowerBound: 0, upperBound: 100))
                )
            )
        }

        if let gpu = snapshot.gpu {
            items.append(
                DashboardMetric(
                    kind: .gpu,
                    titleRole: .metric(.gpu),
                    value: "\(Int(gpu.usagePercent.rounded()))%",
                    title: MetricKind.gpu.title,
                    progress: progressFraction(for: gpu.usagePercent),
                    style: .chart,
                    trend: trend(from: history, kind: .gpu, scale: .fixed(lowerBound: 0, upperBound: 100))
                )
            )
        }

        if let disk = snapshot.disk {
            let detail = DashboardMetricTextFormatter.formatUsageDetail(
                usedBytes: disk.usedBytes,
                percent: disk.usagePercent
            )
            items.append(
                DashboardMetric(
                    kind: .disk,
                    titleRole: .metric(.disk),
                    value: DashboardMetricTextFormatter.formatPercent(disk.usagePercent),
                    detailRole: .raw(detail),
                    title: MetricKind.disk.title,
                    detail: detail,
                    usedBytes: disk.usedBytes,
                    totalBytes: disk.totalBytes,
                    progress: progressFraction(for: disk.usagePercent),
                    style: .chart,
                    trend: trend(from: history, kind: .disk, scale: .fixed(lowerBound: 0, upperBound: 100))
                )
            )
        }

        if let swap = snapshot.swap {
            let detail = DashboardMetricTextFormatter.formatUsageDetail(
                usedBytes: swap.usedBytes,
                percent: swap.usagePercent
            )
            items.append(
                DashboardMetric(
                    kind: .swap,
                    titleRole: .metric(.swap),
                    value: DashboardMetricTextFormatter.formatPercent(swap.usagePercent),
                    detailRole: .raw(detail),
                    title: MetricKind.swap.title,
                    detail: detail,
                    usedBytes: swap.usedBytes,
                    totalBytes: swap.totalBytes,
                    progress: progressFraction(for: swap.usagePercent),
                    style: .chart,
                    trend: trend(from: history, kind: .swap, scale: .fixed(lowerBound: 0, upperBound: 100))
                )
            )
        }

        if let memory = snapshot.memory {
            items.append(
                DashboardMetric(
                    kind: .memory,
                    titleRole: .metric(.memory),
                    value: DashboardMetricTextFormatter.formatMemorySummary(
                        usedBytes: memory.usedBytes,
                        totalBytes: memory.totalBytes,
                        percent: memory.pressurePercent
                    ),
                    title: MetricKind.memory.title,
                    style: .memoryStackedChart,
                    trend: trend(from: history, kind: .memory, scale: .fixed(lowerBound: 0, upperBound: 100)),
                    memoryTrend: memoryTrend(from: history, memory: memory)
                )
            )
        }

        if let network = snapshot.network {
            items.append(
                DashboardMetric(
                    kind: .network,
                    titleRole: .metric(.network),
                    value: "↑ \(DashboardMetricTextFormatter.formatRate(network.uploadBytesPerSecond))  ↓ \(DashboardMetricTextFormatter.formatRate(network.downloadBytesPerSecond))",
                    title: MetricKind.network.title,
                    style: .chart,
                    trend: trend(from: history, kind: .network, scale: .automatic)
                )
            )
        }

        if let battery = snapshot.battery {
            let percentage = battery.displayPercentage(
                showsHardwarePercentage: showsHardwareBatteryPercentage
            )
            let detailRole: DashboardMetricDetailRole = battery.isCharging ? .batteryCharging : .batteryOnBattery
            items.append(
                DashboardMetric(
                    kind: .battery,
                    titleRole: .metric(.battery),
                    value: "\(Int(percentage.rounded()))%",
                    detailRole: detailRole,
                    title: MetricKind.battery.title,
                    detail: battery.isCharging ? "Charging" : "On Battery",
                    style: .chart,
                    trend: batteryTrend(
                        from: history,
                        showsHardwareBatteryPercentage: showsHardwareBatteryPercentage
                    )
                )
            )
        }

        if let temperature = snapshot.temperature(for: preferredTemperatureSource) {
            items.append(
                DashboardMetric(
                    kind: .temperature,
                    titleRole: .temperature(temperature.source),
                    value: formatTemperature(temperature.celsius),
                    title: temperature.source.dashboardTitle,
                    style: .chart,
                    trend: trend(
                        from: history,
                        kind: .temperature,
                        scale: .automatic,
                        source: preferredTemperatureSource
                    )
                )
            )
        }

        if let fan = snapshot.fan {
            items.append(
                DashboardMetric(
                    kind: .fan,
                    titleRole: .metric(.fan),
                    value: "\(fan.rpm) RPM",
                    title: MetricKind.fan.title,
                    style: .chart,
                    trend: trend(from: history, kind: .fan, scale: .automatic)
                )
            )
        }

        return items.sorted { lhs, rhs in
            MetricKind.summaryOrder.firstIndex(of: lhs.kind)! < MetricKind.summaryOrder.firstIndex(of: rhs.kind)!
        }
    }

    nonisolated private static func formatTemperature(_ value: Double) -> String { String(format: "%.1f C", value) }

    nonisolated private static func progressFraction(for percent: Double) -> Double {
        min(max(percent / 100, 0), 1)
    }

    nonisolated private static func batteryTrend(
        from history: MetricsHistory,
        showsHardwareBatteryPercentage: Bool
    ) -> DashboardTrend {
        DashboardTrend(
            samples: history.samples(for: .battery).map { sample in
                DashboardTrendSample(
                    timestamp: sample.timestamp,
                    primaryValue: showsHardwareBatteryPercentage
                        ? (sample.secondaryValue ?? sample.primaryValue)
                        : sample.primaryValue
                )
            },
            scale: .fixed(lowerBound: 0, upperBound: 100)
        )
    }

    nonisolated private static func trend(
        from history: MetricsHistory,
        kind: MetricKind,
        scale: DashboardTrendScale,
        source: TemperatureSource? = nil
    ) -> DashboardTrend {
        DashboardTrend(
            samples: history.samples(for: kind, source: source).map {
                DashboardTrendSample(
                    timestamp: $0.timestamp,
                    primaryValue: $0.primaryValue,
                    secondaryValue: kind == .network ? $0.secondaryValue : nil
                )
            },
            scale: scale
        )
    }

    nonisolated private static func memoryTrend(from history: MetricsHistory, memory: MemoryReading) -> DashboardMemoryTrend {
        let memorySamples = history.samples(for: .memory)
        guard !memorySamples.isEmpty else { return DashboardMemoryTrend(samples: [makeMemoryTrendSample(memory: memory, timestamp: .now)]) }
        return DashboardMemoryTrend(samples: memorySamples.map { makeMemoryTrendSample(sample: $0, latestMemory: memory) })
    }

    nonisolated private static func makeMemoryTrendSample(sample: MetricHistorySample, latestMemory: MemoryReading) -> DashboardMemoryTrendSample {
        let pressurePercent = min(max(sample.primaryValue, 0), 100)
        let totalBytes = sample.memoryTotalBytes ?? latestMemory.totalBytes
        let usedBytes = sample.memoryUsedBytes ?? UInt64((Double(totalBytes) * pressurePercent / 100).rounded())
        return DashboardMemoryTrendSample(timestamp: sample.timestamp, pressurePercent: pressurePercent, usedBytes: usedBytes, totalBytes: totalBytes, breakdown: sample.memoryBreakdown ?? MemoryBreakdown())
    }

    nonisolated private static func makeMemoryTrendSample(memory: MemoryReading, timestamp: Date) -> DashboardMemoryTrendSample {
        DashboardMemoryTrendSample(timestamp: timestamp, pressurePercent: min(max(memory.pressurePercent, 0), 100), usedBytes: memory.usedBytes, totalBytes: memory.totalBytes, breakdown: memory.breakdown)
    }

    private func startSubscription() {
        subscription = store.updatesPublisher.sink { [weak self] snapshot, history in self?.refreshMetricsAsync(snapshot: snapshot, history: history) }
    }

    private func refreshMetricsAsync() { refreshMetricsAsync(snapshot: store.snapshot, history: store.history) }

    private func refreshMetricsAsync(snapshot: MetricsSnapshot, history: MetricsHistory) {
        let metricsBuilder = self.metricsBuilder
        let preferredTemperatureSource = self.preferredTemperatureSource
        let showsHardwareBatteryPercentage = self.showsHardwareBatteryPercentage
        refreshGeneration += 1
        let refreshGeneration = refreshGeneration
        DispatchQueue.global(qos: .utility).async { [weak self, snapshot, history, metricsBuilder, preferredTemperatureSource, showsHardwareBatteryPercentage, refreshGeneration] in
            let metrics = metricsBuilder(snapshot, history, preferredTemperatureSource, showsHardwareBatteryPercentage)
            DispatchQueue.main.async { [weak self, refreshGeneration, metrics] in
                guard let self, self.isActive, self.refreshGeneration == refreshGeneration, self.metrics != metrics else { return }
                self.metrics = metrics
            }
        }
    }
}

public enum DashboardMetricTextFormatter {
    public static func formatBytes(_ value: UInt64) -> String { formatDecimalBytes(Double(value)) }
    public static func formatMemoryBytes(_ value: UInt64) -> String { formatBinaryBytes(Double(value)) }
    public static func formatMemoryGB(_ value: UInt64) -> String { String(format: "%.1fGB", Double(value) / 1_073_741_824) }
    public static func formatPercent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
    public static func formatUsageDetail(usedBytes: UInt64, percent: Double) -> String {
        "\(formatBytes(usedBytes)) (\(formatPercent(percent)))"
    }
    public static func formatMemorySummary(usedBytes: UInt64, totalBytes: UInt64, percent: Double) -> String {
        "\(formatMemoryGB(usedBytes))/\(formatMemoryGB(totalBytes)) (\(Int(percent.rounded()))%)"
    }
    public static func formatRate(_ value: Double) -> String { "\(formatDecimalBytes(max(0, value)))/s" }

    private static func formatDecimalBytes(_ value: Double) -> String {
        if value == 0 { return "0 KB" }
        let unit: (threshold: Double, suffix: String)
        switch value {
        case 1_000_000_000...: unit = (1_000_000_000, "GB")
        case 1_000_000...: unit = (1_000_000, "MB")
        case 1_000...: unit = (1_000, "KB")
        default: return "\(Int(value.rounded())) B"
        }
        let tenths = Int((value / unit.threshold * 10).rounded())
        let whole = tenths / 10
        let fraction = tenths % 10
        return fraction == 0 ? "\(whole) \(unit.suffix)" : "\(whole).\(fraction) \(unit.suffix)"
    }

    private static func formatBinaryBytes(_ value: Double) -> String {
        if value == 0 { return "0 KB" }
        let unit: (threshold: Double, suffix: String)
        switch value {
        case 1_073_741_824...: unit = (1_073_741_824, "GB")
        case 1_048_576...: unit = (1_048_576, "MB")
        case 1_024...: unit = (1_024, "KB")
        default: return "\(Int(value.rounded())) B"
        }
        let tenths = Int((value / unit.threshold * 10).rounded())
        let whole = tenths / 10
        let fraction = tenths % 10
        return fraction == 0 ? "\(whole) \(unit.suffix)" : "\(whole).\(fraction) \(unit.suffix)"
    }
}
