import Combine
import Foundation

public enum DashboardMetricStyle: Equatable, Sendable {
    case chart
    case memoryStackedChart
    case value
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
    public var title: String
    public var value: String
    public var secondaryText: String?
    public var detail: String?
    public var style: DashboardMetricStyle
    public var trend: DashboardTrend?
    public var memoryTrend: DashboardMemoryTrend?

    public var id: String {
        kind.rawValue
    }

    public init(
        kind: MetricKind,
        title: String,
        value: String,
        secondaryText: String? = nil,
        detail: String? = nil,
        style: DashboardMetricStyle = .value,
        trend: DashboardTrend? = nil,
        memoryTrend: DashboardMemoryTrend? = nil
    ) {
        self.kind = kind
        self.title = title
        self.value = value
        self.secondaryText = secondaryText
        self.detail = detail
        self.style = style
        self.trend = trend
        self.memoryTrend = memoryTrend
    }
}

@MainActor
public final class DashboardModel: ObservableObject {
    @Published public private(set) var metrics: [DashboardMetric]
    private let store: MetricsStore
    private let metricsBuilder: @Sendable (MetricsSnapshot, MetricsHistory) -> [DashboardMetric]
    private var subscription: AnyCancellable?
    private var refreshGeneration = 0
    private var isActive: Bool

    public convenience init(
        store: MetricsStore,
        isActive: Bool = true
    ) {
        self.init(
            store: store,
            isActive: isActive,
            metricsBuilder: DashboardModel.buildMetrics
        )
    }

    init(
        store: MetricsStore,
        isActive: Bool = true,
        metricsBuilder: @escaping @Sendable (MetricsSnapshot, MetricsHistory) -> [DashboardMetric]
    ) {
        self.store = store
        self.metricsBuilder = metricsBuilder
        self.isActive = isActive
        self.metrics = isActive ? metricsBuilder(store.snapshot, store.history) : []

        if isActive {
            startSubscription()
        }
    }

    public func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else {
            return
        }

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

    nonisolated private static func buildMetrics(from snapshot: MetricsSnapshot, history: MetricsHistory) -> [DashboardMetric] {
        var items: [DashboardMetric] = []

        if let cpu = snapshot.cpu {
            items.append(
                DashboardMetric(
                    kind: .cpu,
                    title: MetricKind.cpu.title,
                    value: "\(Int(cpu.usagePercent.rounded()))%",
                    style: .chart,
                    trend: trend(from: history, kind: .cpu, scale: .fixed(lowerBound: 0, upperBound: 100))
                )
            )
        }

        if let gpu = snapshot.gpu {
            items.append(
                DashboardMetric(
                    kind: .gpu,
                    title: MetricKind.gpu.title,
                    value: "\(Int(gpu.usagePercent.rounded()))%",
                    style: .chart,
                    trend: trend(from: history, kind: .gpu, scale: .fixed(lowerBound: 0, upperBound: 100))
                )
            )
        }

        if let memory = snapshot.memory {
            items.append(
                DashboardMetric(
                    kind: .memory,
                    title: MetricKind.memory.title,
                    value: "\(Int(memory.pressurePercent.rounded()))%",
                    secondaryText: "RAM \(DashboardMetricTextFormatter.formatBytes(memory.usedBytes)) / \(DashboardMetricTextFormatter.formatBytes(memory.totalBytes))",
                    detail: "RAM \(DashboardMetricTextFormatter.formatBytes(memory.usedBytes)) / \(DashboardMetricTextFormatter.formatBytes(memory.totalBytes))",
                    style: .memoryStackedChart,
                    trend: trend(from: history, kind: .memory, scale: .fixed(lowerBound: 0, upperBound: 100)),
                    memoryTrend: memoryTrend(from: history, memory: memory)
                )
            )
        }

        if let vram = snapshot.vram {
            items.append(
                DashboardMetric(
                    kind: .vram,
                    title: MetricKind.vram.title,
                    value: DashboardMetricTextFormatter.formatBytes(vram.usedBytes),
                    detail: "of \(DashboardMetricTextFormatter.formatBytes(vram.totalBytes))",
                    style: .chart,
                    trend: trend(from: history, kind: .vram, scale: .fixed(lowerBound: 0, upperBound: 100))
                )
            )
        }

        if let network = snapshot.network {
            items.append(
                DashboardMetric(
                    kind: .network,
                    title: MetricKind.network.title,
                    value: "↑ \(DashboardMetricTextFormatter.formatRate(network.uploadBytesPerSecond))  ↓ \(DashboardMetricTextFormatter.formatRate(network.downloadBytesPerSecond))",
                    style: .chart,
                    trend: trend(from: history, kind: .network, scale: .automatic)
                )
            )
        }

        if let battery = snapshot.battery {
            items.append(
                DashboardMetric(
                    kind: .battery,
                    title: MetricKind.battery.title,
                    value: "\(Int(battery.percentage.rounded()))%",
                    detail: battery.isCharging ? "Charging" : "On Battery",
                    style: .chart,
                    trend: trend(from: history, kind: .battery, scale: .fixed(lowerBound: 0, upperBound: 100))
                )
            )
        }

        if let temperature = snapshot.temperature {
            items.append(
                DashboardMetric(
                    kind: .temperature,
                    title: temperature.source.dashboardTitle,
                    value: formatTemperature(temperature.celsius),
                    style: .chart,
                    trend: trend(from: history, kind: .temperature, scale: .automatic)
                )
            )
        }

        if let fan = snapshot.fan {
            items.append(
                DashboardMetric(
                    kind: .fan,
                    title: MetricKind.fan.title,
                    value: "\(fan.rpm) RPM",
                    style: .chart,
                    trend: trend(from: history, kind: .fan, scale: .automatic)
                )
            )
        }

        return items.sorted { lhs, rhs in
            MetricKind.summaryOrder.firstIndex(of: lhs.kind)! < MetricKind.summaryOrder.firstIndex(of: rhs.kind)!
        }
    }

    nonisolated private static func formatTemperature(_ value: Double) -> String {
        String(format: "%.1f C", value)
    }

    nonisolated private static func trend(
        from history: MetricsHistory,
        kind: MetricKind,
        scale: DashboardTrendScale
    ) -> DashboardTrend {
        DashboardTrend(
            samples: history.samples(for: kind).map {
                DashboardTrendSample(
                    timestamp: $0.timestamp,
                    primaryValue: $0.primaryValue,
                    secondaryValue: $0.secondaryValue
                )
            },
            scale: scale
        )
    }

    nonisolated private static func memoryTrend(
        from history: MetricsHistory,
        memory: MemoryReading
    ) -> DashboardMemoryTrend {
        let memorySamples = history.samples(for: .memory)

        if memorySamples.isEmpty {
            return DashboardMemoryTrend(
                samples: [
                    makeMemoryTrendSample(
                        memory: memory,
                        timestamp: .now
                    ),
                ]
            )
        }

        return DashboardMemoryTrend(
            samples: memorySamples.map { sample in
                makeMemoryTrendSample(sample: sample, latestMemory: memory)
            }
        )
    }

    nonisolated private static func makeMemoryTrendSample(
        sample: MetricHistorySample,
        latestMemory: MemoryReading
    ) -> DashboardMemoryTrendSample {
        let pressurePercent = min(max(sample.primaryValue, 0), 100)
        let totalBytes = sample.memoryTotalBytes ?? latestMemory.totalBytes
        let usedBytes = sample.memoryUsedBytes ?? UInt64((Double(totalBytes) * pressurePercent / 100).rounded())

        return DashboardMemoryTrendSample(
            timestamp: sample.timestamp,
            pressurePercent: pressurePercent,
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            breakdown: sample.memoryBreakdown ?? MemoryBreakdown()
        )
    }

    nonisolated private static func makeMemoryTrendSample(
        memory: MemoryReading,
        timestamp: Date
    ) -> DashboardMemoryTrendSample {
        DashboardMemoryTrendSample(
            timestamp: timestamp,
            pressurePercent: min(max(memory.pressurePercent, 0), 100),
            usedBytes: memory.usedBytes,
            totalBytes: memory.totalBytes,
            breakdown: memory.breakdown
        )
    }

    private func startSubscription() {
        subscription = store.updatesPublisher
            .sink { [weak self] snapshot, history in
                self?.refreshMetricsAsync(snapshot: snapshot, history: history)
            }
    }

    private func refreshMetricsAsync() {
        refreshMetricsAsync(snapshot: store.snapshot, history: store.history)
    }

    private func refreshMetricsAsync(snapshot: MetricsSnapshot, history: MetricsHistory) {
        let metricsBuilder = self.metricsBuilder

        refreshGeneration += 1
        let refreshGeneration = refreshGeneration

        DispatchQueue.global(qos: .utility).async { [snapshot, history, metricsBuilder] in
            let metrics = metricsBuilder(snapshot, history)

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isActive,
                      self.refreshGeneration == refreshGeneration,
                      self.metrics != metrics else {
                    return
                }

                self.metrics = metrics
            }
        }
    }
}

public enum DashboardMetricTextFormatter {
    public static func formatBytes(_ value: UInt64) -> String {
        formatDecimalBytes(Double(value))
    }

    public static func formatRate(_ value: Double) -> String {
        "\(formatDecimalBytes(max(0, value)))/s"
    }

    private static func formatDecimalBytes(_ value: Double) -> String {
        if value == 0 {
            return "0 KB"
        }

        let unit: (threshold: Double, suffix: String)
        switch value {
        case 1_000_000_000...:
            unit = (1_000_000_000, "GB")
        case 1_000_000...:
            unit = (1_000_000, "MB")
        case 1_000...:
            unit = (1_000, "KB")
        default:
            return "\(Int(value.rounded())) B"
        }

        let tenths = Int((value / unit.threshold * 10).rounded())
        let whole = tenths / 10
        let fraction = tenths % 10
        if fraction == 0 {
            return "\(whole) \(unit.suffix)"
        }

        return "\(whole).\(fraction) \(unit.suffix)"
    }
}
