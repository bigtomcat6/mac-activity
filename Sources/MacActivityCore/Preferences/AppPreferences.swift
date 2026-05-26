import Foundation

public enum TemperatureSource: String, CaseIterable, Codable, Sendable {
    case smc
    case battery

    public var preferencesTitle: String {
        switch self {
        case .smc:
            return "CPU/SMC"
        case .battery:
            return "Battery"
        }
    }

    public var dashboardTitle: String {
        switch self {
        case .smc:
            return "CPU Temp"
        case .battery:
            return "Battery Temp"
        }
    }

    public var summaryPrefix: String {
        switch self {
        case .smc:
            return "CPU"
        case .battery:
            return "BTMP"
        }
    }

    public var statusLabel: String {
        switch self {
        case .smc:
            return "CPU"
        case .battery:
            return "BAT"
        }
    }
}

public struct AppPreferences: Equatable, Codable, Sendable {
    public var launchAtLoginEnabled: Bool
    public var selectedSummaryMetrics: [MetricKind]
    public var temperatureSource: TemperatureSource

    public init(
        launchAtLoginEnabled: Bool,
        selectedSummaryMetrics: [MetricKind],
        temperatureSource: TemperatureSource = .smc
    ) {
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.selectedSummaryMetrics = selectedSummaryMetrics
        self.temperatureSource = temperatureSource
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLoginEnabled
        case selectedSummaryMetrics
        case temperatureSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.launchAtLoginEnabled = try container.decode(Bool.self, forKey: .launchAtLoginEnabled)
        self.selectedSummaryMetrics = try container.decode([MetricKind].self, forKey: .selectedSummaryMetrics)
        self.temperatureSource = try container.decodeIfPresent(TemperatureSource.self, forKey: .temperatureSource) ?? .smc
    }

    public static let `default` = AppPreferences(
        launchAtLoginEnabled: false,
        selectedSummaryMetrics: [.cpu, .gpu, .memory, .vram, .temperature, .fan, .network],
        temperatureSource: .smc
    )
}
