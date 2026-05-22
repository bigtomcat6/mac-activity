import Foundation

public enum MetricKind: String, CaseIterable, Codable, Sendable {
    case cpu
    case gpu
    case memory
    case vram
    case network
    case battery
    case temperature
    case fan

    public static let summaryOrder: [MetricKind] = [
        .cpu,
        .gpu,
        .memory,
        .vram,
        .temperature,
        .fan,
        .network,
        .battery,
    ]

    public var title: String {
        switch self {
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        case .memory:
            return "Memory"
        case .vram:
            return "VRAM"
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
