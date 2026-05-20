import Foundation

public enum MetricKind: String, CaseIterable, Codable, Sendable {
    case cpu
    case memory
    case network
    case battery
    case temperature
    case fan

    public static let summaryOrder: [MetricKind] = [
        .cpu,
        .memory,
        .network,
        .battery,
        .temperature,
        .fan,
    ]

    public var title: String {
        switch self {
        case .cpu:
            return "CPU"
        case .memory:
            return "Memory"
        case .network:
            return "Network"
        case .battery:
            return "Battery"
        case .temperature:
            return "Temperature"
        case .fan:
            return "Fan"
        }
    }
}
