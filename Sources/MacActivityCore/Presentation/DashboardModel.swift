import Combine
import Foundation

public enum DashboardMetricStyle: Equatable, Sendable {
    case chart
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

public struct DashboardMetric: Identifiable, Equatable, Sendable {
    public var kind: MetricKind
    public var title: String
    public var value: String
    public var detail: String?
    public var style: DashboardMetricStyle
    public var trend: DashboardTrend?

    public var id: String {
        kind.rawValue
    }

    public init(
        kind: MetricKind,
        title: String,
        value: String,
        detail: String? = nil,
        style: DashboardMetricStyle = .value,
        trend: DashboardTrend? = nil
    ) {
        self.kind = kind
        self.title = title
        self.value = value
        self.detail = detail
        self.style = style
        self.trend = trend
    }
}

@MainActor
public final class DashboardModel: ObservableObject {
    @Published public private(set) var metrics: [DashboardMetric]
    private var cancellables: Set<AnyCancellable> = []

    public init(store: MetricsStore) {
        self.metrics = DashboardModel.buildMetrics(from: store.snapshot, history: store.history)

        Publishers.CombineLatest(store.$snapshot, store.$history)
            .map { snapshot, history in
                DashboardModel.buildMetrics(from: snapshot, history: history)
            }
            .removeDuplicates()
            .sink { [weak self] metrics in
                self?.metrics = metrics
            }
            .store(in: &cancellables)
    }

    private static func buildMetrics(from snapshot: MetricsSnapshot, history: MetricsHistory) -> [DashboardMetric] {
        var items: [DashboardMetric] = []

        if let cpu = snapshot.cpu {
            items.append(
                DashboardMetric(
                    kind: .cpu,
                    title: MetricKind.cpu.title,
                    value: "\(Int(cpu.usagePercent.rounded()))%",
                    style: .chart,
                    trend: trend(
                        from: history,
                        scale: .fixed(lowerBound: 0, upperBound: 100)
                    ) { sample in
                        guard let primaryValue = sample.cpuUsagePercent else {
                            return nil
                        }

                        return DashboardTrendSample(
                            timestamp: sample.timestamp,
                            primaryValue: primaryValue
                        )
                    }
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
                    trend: trend(
                        from: history,
                        scale: .fixed(lowerBound: 0, upperBound: 100)
                    ) { sample in
                        guard let primaryValue = sample.gpuUsagePercent else {
                            return nil
                        }

                        return DashboardTrendSample(
                            timestamp: sample.timestamp,
                            primaryValue: primaryValue
                        )
                    }
                )
            )
        }

        if let memory = snapshot.memory {
            items.append(
                DashboardMetric(
                    kind: .memory,
                    title: MetricKind.memory.title,
                    value: formatBytes(memory.usedBytes),
                    detail: "of \(formatBytes(memory.totalBytes))",
                    style: .chart,
                    trend: trend(
                        from: history,
                        scale: .fixed(lowerBound: 0, upperBound: 100)
                    ) { sample in
                        guard let primaryValue = sample.memoryUsedPercent else {
                            return nil
                        }

                        return DashboardTrendSample(
                            timestamp: sample.timestamp,
                            primaryValue: primaryValue
                        )
                    }
                )
            )
        }

        if let vram = snapshot.vram {
            items.append(
                DashboardMetric(
                    kind: .vram,
                    title: MetricKind.vram.title,
                    value: formatBytes(vram.usedBytes),
                    detail: "of \(formatBytes(vram.totalBytes))",
                    style: .chart,
                    trend: trend(
                        from: history,
                        scale: .fixed(lowerBound: 0, upperBound: 100)
                    ) { sample in
                        guard let primaryValue = sample.vramUsedPercent else {
                            return nil
                        }

                        return DashboardTrendSample(
                            timestamp: sample.timestamp,
                            primaryValue: primaryValue
                        )
                    }
                )
            )
        }

        if let network = snapshot.network {
            items.append(
                DashboardMetric(
                    kind: .network,
                    title: MetricKind.network.title,
                    value: "Down \(formatRate(network.downloadBytesPerSecond))",
                    detail: "Up \(formatRate(network.uploadBytesPerSecond))",
                    style: .chart,
                    trend: trend(
                        from: history,
                        scale: .automatic
                    ) { sample in
                        guard let primaryValue = sample.downloadBytesPerSecond,
                              let secondaryValue = sample.uploadBytesPerSecond else {
                            return nil
                        }

                        return DashboardTrendSample(
                            timestamp: sample.timestamp,
                            primaryValue: max(0, primaryValue),
                            secondaryValue: max(0, secondaryValue)
                        )
                    }
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
                    trend: trend(
                        from: history,
                        scale: .fixed(lowerBound: 0, upperBound: 100)
                    ) { sample in
                        guard let primaryValue = sample.batteryPercent else {
                            return nil
                        }

                        return DashboardTrendSample(
                            timestamp: sample.timestamp,
                            primaryValue: primaryValue
                        )
                    }
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
                    trend: trend(
                        from: history,
                        scale: .automatic
                    ) { sample in
                        guard let primaryValue = sample.temperatureCelsius else {
                            return nil
                        }

                        return DashboardTrendSample(
                            timestamp: sample.timestamp,
                            primaryValue: primaryValue
                        )
                    }
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
                    trend: trend(
                        from: history,
                        scale: .automatic
                    ) { sample in
                        guard let primaryValue = sample.fanRPM else {
                            return nil
                        }

                        return DashboardTrendSample(
                            timestamp: sample.timestamp,
                            primaryValue: Double(primaryValue)
                        )
                    }
                )
            )
        }

        return items.sorted { lhs, rhs in
            MetricKind.summaryOrder.firstIndex(of: lhs.kind)! < MetricKind.summaryOrder.firstIndex(of: rhs.kind)!
        }
    }

    private static func formatBytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(value))
    }

    private static func formatRate(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .decimal
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return "\(formatter.string(fromByteCount: Int64(max(0, value))))/s"
    }

    private static func formatTemperature(_ value: Double) -> String {
        String(format: "%.1f C", value)
    }

    private static func trend(
        from history: MetricsHistory,
        scale: DashboardTrendScale,
        build: (MetricHistorySample) -> DashboardTrendSample?
    ) -> DashboardTrend {
        DashboardTrend(
            samples: history.samples.compactMap(build),
            scale: scale
        )
    }
}
