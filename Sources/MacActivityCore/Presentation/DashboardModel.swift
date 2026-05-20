import Combine
import Foundation

public enum DashboardMetricStyle: Equatable, Sendable {
    case progress
    case sparkline
    case value
}

public struct NetworkTrendPoint: Equatable, Sendable {
    public var downloadBytesPerSecond: Double
    public var uploadBytesPerSecond: Double

    public init(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }
}

public struct DashboardMetric: Identifiable, Equatable, Sendable {
    public var kind: MetricKind
    public var title: String
    public var value: String
    public var detail: String?
    public var style: DashboardMetricStyle
    public var progress: Double?
    public var trend: [NetworkTrendPoint]

    public var id: String {
        kind.rawValue
    }

    public init(
        kind: MetricKind,
        title: String,
        value: String,
        detail: String? = nil,
        style: DashboardMetricStyle = .value,
        progress: Double? = nil,
        trend: [NetworkTrendPoint] = []
    ) {
        self.kind = kind
        self.title = title
        self.value = value
        self.detail = detail
        self.style = style
        self.progress = progress
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
                    style: .progress,
                    progress: clamp(cpu.usagePercent / 100)
                )
            )
        }

        if let memory = snapshot.memory {
            let progress = memory.totalBytes > 0
                ? clamp(Double(memory.usedBytes) / Double(memory.totalBytes))
                : nil
            items.append(
                DashboardMetric(
                    kind: .memory,
                    title: MetricKind.memory.title,
                    value: formatBytes(memory.usedBytes),
                    detail: "of \(formatBytes(memory.totalBytes))",
                    style: .progress,
                    progress: progress
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
                    style: .sparkline,
                    trend: networkTrend(from: history)
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
                    style: .progress,
                    progress: clamp(battery.percentage / 100)
                )
            )
        }

        if let temperature = snapshot.temperature {
            items.append(
                DashboardMetric(
                    kind: .temperature,
                    title: MetricKind.temperature.title,
                    value: "\(Int(temperature.celsius.rounded()))C"
                )
            )
        }

        if let fan = snapshot.fan {
            items.append(
                DashboardMetric(
                    kind: .fan,
                    title: MetricKind.fan.title,
                    value: "\(fan.rpm) RPM"
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

    private static func networkTrend(from history: MetricsHistory) -> [NetworkTrendPoint] {
        history.samples.compactMap { sample in
            guard let download = sample.downloadBytesPerSecond,
                  let upload = sample.uploadBytesPerSecond else {
                return nil
            }

            return NetworkTrendPoint(
                downloadBytesPerSecond: max(0, download),
                uploadBytesPerSecond: max(0, upload)
            )
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
