import Foundation

public struct AppPreferences: Equatable, Codable, Sendable {
    public var launchAtLoginEnabled: Bool
    public var selectedSummaryMetrics: [MetricKind]

    public init(
        launchAtLoginEnabled: Bool,
        selectedSummaryMetrics: [MetricKind]
    ) {
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.selectedSummaryMetrics = selectedSummaryMetrics
    }

    public static let `default` = AppPreferences(
        launchAtLoginEnabled: false,
        selectedSummaryMetrics: [.cpu, .gpu, .memory, .vram, .temperature, .fan, .network]
    )
}
