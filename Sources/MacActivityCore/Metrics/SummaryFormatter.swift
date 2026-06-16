import Foundation

public protocol SummaryFormatting: Sendable {
    func render(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource
    ) -> String
    func renderStatusItems(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource
    ) -> [StatusSummaryItem]
}

public protocol HardwareBatterySummaryFormatting: SummaryFormatting {
    func render(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource,
        showsHardwareBatteryPercentage: Bool
    ) -> String

    func renderStatusItems(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource,
        showsHardwareBatteryPercentage: Bool
    ) -> [StatusSummaryItem]
}

public extension SummaryFormatting {
    func render(snapshot: MetricsSnapshot, selectedMetrics: [MetricKind]) -> String {
        render(
            snapshot: snapshot,
            selectedMetrics: selectedMetrics,
            preferredTemperatureSource: .smc
        )
    }

    func render(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource,
        showsHardwareBatteryPercentage: Bool
    ) -> String {
        if let formatter = self as? any HardwareBatterySummaryFormatting {
            return formatter.render(
                snapshot: snapshot,
                selectedMetrics: selectedMetrics,
                preferredTemperatureSource: preferredTemperatureSource,
                showsHardwareBatteryPercentage: showsHardwareBatteryPercentage
            )
        }

        return render(
            snapshot: snapshot,
            selectedMetrics: selectedMetrics,
            preferredTemperatureSource: preferredTemperatureSource
        )
    }

    func renderStatusItems(snapshot: MetricsSnapshot, selectedMetrics: [MetricKind]) -> [StatusSummaryItem] {
        renderStatusItems(
            snapshot: snapshot,
            selectedMetrics: selectedMetrics,
            preferredTemperatureSource: .smc
        )
    }

    func renderStatusItems(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource,
        showsHardwareBatteryPercentage: Bool
    ) -> [StatusSummaryItem] {
        if let formatter = self as? any HardwareBatterySummaryFormatting {
            return formatter.renderStatusItems(
                snapshot: snapshot,
                selectedMetrics: selectedMetrics,
                preferredTemperatureSource: preferredTemperatureSource,
                showsHardwareBatteryPercentage: showsHardwareBatteryPercentage
            )
        }

        return renderStatusItems(
            snapshot: snapshot,
            selectedMetrics: selectedMetrics,
            preferredTemperatureSource: preferredTemperatureSource
        )
    }
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

public struct SummaryFormatter: HardwareBatterySummaryFormatting {
    public init() {}

    public func render(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource
    ) -> String {
        render(
            snapshot: snapshot,
            selectedMetrics: selectedMetrics,
            preferredTemperatureSource: preferredTemperatureSource,
            showsHardwareBatteryPercentage: false
        )
    }

    public func render(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource,
        showsHardwareBatteryPercentage: Bool
    ) -> String {
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
            case .gpu:
                guard let gpu = snapshot.gpu else {
                    return nil
                }
                return "GPU \(Int(gpu.usagePercent.rounded()))%"
            case .disk:
                guard let disk = snapshot.disk else {
                    return nil
                }
                return "DISK \(Int(disk.usagePercent.rounded()))%"
            case .swap:
                guard let swap = snapshot.swap else {
                    return nil
                }
                return "SWAP \(Int(swap.usagePercent.rounded()))%"
            case .memory:
                guard let memory = snapshot.memory, memory.totalBytes > 0 else {
                    return nil
                }
                let percent = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
                return "MEM \(Int(percent.rounded()))%"
            case .vram:
                guard let vram = snapshot.vram, vram.totalBytes > 0 else {
                    return nil
                }
                let percent = Double(vram.usedBytes) / Double(vram.totalBytes) * 100
                return "VRAM \(Int(percent.rounded()))%"
            case .network:
                guard let network = snapshot.network else {
                    return nil
                }
                return "NET D\(formatBytesPerSecond(network.downloadBytesPerSecond)) U\(formatBytesPerSecond(network.uploadBytesPerSecond))"
            case .battery:
                guard let battery = snapshot.battery else {
                    return nil
                }
                let percentage = battery.displayPercentage(
                    showsHardwarePercentage: showsHardwareBatteryPercentage
                )
                return "BAT \(Int(percentage.rounded()))%"
            case .temperature:
                guard let temperature = snapshot.temperature(for: preferredTemperatureSource) else {
                    return nil
                }
                return "\(temperature.source.summaryPrefix) \(Int(temperature.celsius.rounded()))C"
            case .fan:
                guard let fan = snapshot.fan else {
                    return nil
                }
                return "FAN \(fan.rpm)RPM"
            }
        }

        return rendered.isEmpty ? "Metrics" : rendered.joined(separator: " | ")
    }

    public func renderStatusItems(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource
    ) -> [StatusSummaryItem] {
        renderStatusItems(
            snapshot: snapshot,
            selectedMetrics: selectedMetrics,
            preferredTemperatureSource: preferredTemperatureSource,
            showsHardwareBatteryPercentage: false
        )
    }

    public func renderStatusItems(
        snapshot: MetricsSnapshot,
        selectedMetrics: [MetricKind],
        preferredTemperatureSource: TemperatureSource,
        showsHardwareBatteryPercentage: Bool
    ) -> [StatusSummaryItem] {
        let selectedSet = Set(selectedMetrics)
        return Self.statusDisplayOrder.compactMap { kind -> StatusSummaryItem? in
            guard selectedSet.contains(kind) else {
                return nil
            }

            switch kind {
            case .cpu:
                return StatusSummaryItem(
                    kind: .cpu,
                    primaryText: formatPercent(snapshot.cpu?.usagePercent),
                    secondaryText: "CPU",
                    style: .metric
                )
            case .gpu:
                return StatusSummaryItem(
                    kind: .gpu,
                    primaryText: formatPercent(snapshot.gpu?.usagePercent),
                    secondaryText: "GPU",
                    style: .metric
                )
            case .disk:
                return StatusSummaryItem(
                    kind: .disk,
                    primaryText: formatPercent(snapshot.disk?.usagePercent),
                    secondaryText: "DISK",
                    style: .metric
                )
            case .swap:
                return StatusSummaryItem(
                    kind: .swap,
                    primaryText: formatPercent(snapshot.swap?.usagePercent),
                    secondaryText: "SWAP",
                    style: .metric
                )
            case .memory:
                return StatusSummaryItem(
                    kind: .memory,
                    primaryText: formatPercent(usedPercent(used: snapshot.memory?.usedBytes, total: snapshot.memory?.totalBytes)),
                    secondaryText: "MEM",
                    style: .metric
                )
            case .vram:
                return StatusSummaryItem(
                    kind: .vram,
                    primaryText: formatPercent(usedPercent(used: snapshot.vram?.usedBytes, total: snapshot.vram?.totalBytes)),
                    secondaryText: "VRAM",
                    style: .metric
                )
            case .network:
                return StatusSummaryItem(
                    kind: .network,
                    primaryText: "↑\(formatOptionalStatusBytesPerSecond(snapshot.network?.uploadBytesPerSecond))",
                    secondaryText: "↓\(formatOptionalStatusBytesPerSecond(snapshot.network?.downloadBytesPerSecond))",
                    style: .network
                )
            case .battery:
                guard let battery = snapshot.battery else {
                    return nil
                }
                let percentage = battery.displayPercentage(
                    showsHardwarePercentage: showsHardwareBatteryPercentage
                )
                return StatusSummaryItem(
                    kind: .battery,
                    primaryText: "\(Int(percentage.rounded()))%",
                    secondaryText: "BAT",
                    style: .metric
                )
            case .temperature:
                let temperature = snapshot.temperature(for: preferredTemperatureSource)
                return StatusSummaryItem(
                    kind: .temperature,
                    primaryText: temperature.map { "\(Int($0.celsius.rounded()))℃" } ?? "--",
                    secondaryText: temperature?.source.statusLabel ?? preferredTemperatureSource.statusLabel,
                    style: .metric
                )
            case .fan:
                return StatusSummaryItem(
                    kind: .fan,
                    primaryText: snapshot.fan.map { "\($0.rpm)" } ?? "--",
                    secondaryText: "RPM",
                    style: .metric
                )
            }
        }
    }

    private static let statusDisplayOrder: [MetricKind] = [
        .cpu,
        .gpu,
        .disk,
        .swap,
        .memory,
        .vram,
        .temperature,
        .fan,
        .network,
        .battery,
    ]

    private func formatBytesPerSecond(_ value: Double) -> String {
        let absoluteValue = max(0, value)
        switch absoluteValue {
        case 1_000_000_000...:
            return String(format: "%.1fG", absoluteValue / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", absoluteValue / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", absoluteValue / 1_000)
        default:
            return String(format: "%.0fB", absoluteValue)
        }
    }

    private func formatOptionalStatusBytesPerSecond(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        return formatBytesPerSecond(value)
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        return "\(Int(value.rounded()))%"
    }

    private func usedPercent(used: UInt64?, total: UInt64?) -> Double? {
        guard let used, let total, total > 0 else {
            return nil
        }

        return Double(used) / Double(total) * 100
    }
}
