import Foundation

public protocol SummaryFormatting: Sendable {
    func render(snapshot: MetricsSnapshot, selectedMetrics: [MetricKind]) -> String
    func renderStatusItems(snapshot: MetricsSnapshot, selectedMetrics: [MetricKind]) -> [StatusSummaryItem]
}

public enum StatusSummaryItemStyle: Equatable, Sendable {
    case metric
    case network
}

public struct StatusSummaryItem: Equatable, Identifiable, Sendable {
    public var id: MetricKind { kind }
    public let kind: MetricKind
    public let primaryText: String
    public let secondaryText: String
    public let style: StatusSummaryItemStyle

    public init(
        kind: MetricKind,
        primaryText: String,
        secondaryText: String,
        style: StatusSummaryItemStyle
    ) {
        self.kind = kind
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.style = style
    }
}

public struct SummaryFormatter: SummaryFormatting {
    public init() {}

    public func render(snapshot: MetricsSnapshot, selectedMetrics: [MetricKind]) -> String {
        let selectedSet = Set(selectedMetrics)
        let rendered = MetricKind.summaryOrder.compactMap { kind -> String? in
            guard selectedSet.contains(kind) else {
                return nil
            }

            switch kind {
            case .cpu:
                guard let cpu = snapshot.cpu else {
                    return nil
                }
                return "CPU \(Int(cpu.usagePercent.rounded()))%"
            case .memory:
                guard let memory = snapshot.memory, memory.totalBytes > 0 else {
                    return nil
                }
                let percent = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
                return "MEM \(Int(percent.rounded()))%"
            case .network:
                guard let network = snapshot.network else {
                    return nil
                }
                return "NET D\(formatBytesPerSecond(network.downloadBytesPerSecond)) U\(formatBytesPerSecond(network.uploadBytesPerSecond))"
            case .battery:
                guard let battery = snapshot.battery else {
                    return nil
                }
                return "BAT \(Int(battery.percentage.rounded()))%"
            case .temperature:
                guard let temperature = snapshot.temperature else {
                    return nil
                }
                return "TMP \(Int(temperature.celsius.rounded()))C"
            case .fan:
                guard let fan = snapshot.fan else {
                    return nil
                }
                return "FAN \(fan.rpm)RPM"
            }
        }

        return rendered.isEmpty ? "Metrics" : rendered.joined(separator: " | ")
    }

    public func renderStatusItems(snapshot: MetricsSnapshot, selectedMetrics: [MetricKind]) -> [StatusSummaryItem] {
        let selectedSet = Set(selectedMetrics)
        return Self.statusDisplayOrder.compactMap { kind -> StatusSummaryItem? in
            guard selectedSet.contains(kind) else {
                return nil
            }

            switch kind {
            case .cpu:
                guard let cpu = snapshot.cpu else {
                    return nil
                }
                return StatusSummaryItem(
                    kind: .cpu,
                    primaryText: "\(Int(cpu.usagePercent.rounded()))%",
                    secondaryText: "CPU",
                    style: .metric
                )
            case .memory:
                guard let memory = snapshot.memory, memory.totalBytes > 0 else {
                    return nil
                }
                let percent = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
                return StatusSummaryItem(
                    kind: .memory,
                    primaryText: "\(Int(percent.rounded()))%",
                    secondaryText: "MEM",
                    style: .metric
                )
            case .network:
                guard let network = snapshot.network else {
                    return nil
                }
                return StatusSummaryItem(
                    kind: .network,
                    primaryText: "↑\(formatStatusBytesPerSecond(network.uploadBytesPerSecond))",
                    secondaryText: "↓\(formatStatusBytesPerSecond(network.downloadBytesPerSecond))",
                    style: .network
                )
            case .battery:
                guard let battery = snapshot.battery else {
                    return nil
                }
                return StatusSummaryItem(
                    kind: .battery,
                    primaryText: "\(Int(battery.percentage.rounded()))%",
                    secondaryText: "BAT",
                    style: .metric
                )
            case .temperature:
                guard let temperature = snapshot.temperature else {
                    return nil
                }
                return StatusSummaryItem(
                    kind: .temperature,
                    primaryText: "\(Int(temperature.celsius.rounded()))℃",
                    secondaryText: "SEN",
                    style: .metric
                )
            case .fan:
                guard let fan = snapshot.fan else {
                    return nil
                }
                return StatusSummaryItem(
                    kind: .fan,
                    primaryText: "\(fan.rpm)",
                    secondaryText: "RPM",
                    style: .metric
                )
            }
        }
    }

    private static let statusDisplayOrder: [MetricKind] = [
        .cpu,
        .memory,
        .battery,
        .temperature,
        .fan,
        .network,
    ]

    private func formatBytesPerSecond(_ value: Double) -> String {
        let absoluteValue = max(0, value)
        switch absoluteValue {
        case 1_000_000...:
            return String(format: "%.1fM", absoluteValue / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", absoluteValue / 1_000)
        default:
            return String(format: "%.0fB", absoluteValue)
        }
    }

    private func formatStatusBytesPerSecond(_ value: Double) -> String {
        let absoluteValue = max(0, value)
        switch absoluteValue {
        case 1_000_000...:
            return String(format: "%.1f M/s", absoluteValue / 1_000_000)
        case 1_000...:
            return String(format: "%.1f K/s", absoluteValue / 1_000)
        default:
            return String(format: "%.0f B/s", absoluteValue)
        }
    }
}
