import Foundation

public struct AppPreferences: Equatable, Codable, Sendable {
    public var isMenuBarEnabled: Bool
    public var launchAtLoginEnabled: Bool
    public var selectedSummaryMetrics: [MetricKind]

    public init(
        isMenuBarEnabled: Bool,
        launchAtLoginEnabled: Bool,
        selectedSummaryMetrics: [MetricKind]
    ) {
        self.isMenuBarEnabled = isMenuBarEnabled
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.selectedSummaryMetrics = selectedSummaryMetrics
    }

    public static let `default` = AppPreferences(
        isMenuBarEnabled: true,
        launchAtLoginEnabled: false,
        selectedSummaryMetrics: [.cpu, .memory, .network]
    )
}
