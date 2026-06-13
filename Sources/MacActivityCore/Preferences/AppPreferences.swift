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

private enum LegacyDiskCleanupScope: String, Codable {
    case cachesOnly
    case cachesTrashAndLogs

    var categoryKinds: [DiskCleanupCategoryKind] {
        switch self {
        case .cachesOnly:
            return [.userCaches]
        case .cachesTrashAndLogs:
            return [.trash, .userCaches, .userLogs]
        }
    }
}

public struct AppPreferences: Equatable, Codable, Sendable {
    public var launchAtLoginEnabled: Bool
    public var selectedSummaryMetrics: [MetricKind]
    public var temperatureSource: TemperatureSource
    public var preferredLanguageIdentifier: String?
    public var diskCleanupCategories: [DiskCleanupCategoryKind]

    public init(
        launchAtLoginEnabled: Bool,
        selectedSummaryMetrics: [MetricKind],
        temperatureSource: TemperatureSource = .smc,
        preferredLanguageIdentifier: String? = nil,
        diskCleanupCategories: [DiskCleanupCategoryKind] = AppPreferences.defaultDiskCleanupCategories
    ) {
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.selectedSummaryMetrics = selectedSummaryMetrics
        self.temperatureSource = temperatureSource
        self.preferredLanguageIdentifier = preferredLanguageIdentifier
        self.diskCleanupCategories = AppPreferences.orderedDiskCleanupCategories(from: Set(diskCleanupCategories))
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLoginEnabled
        case selectedSummaryMetrics
        case temperatureSource
        case preferredLanguageIdentifier
        case diskCleanupCategories
        case diskCleanupScope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.launchAtLoginEnabled = try container.decode(Bool.self, forKey: .launchAtLoginEnabled)
        self.selectedSummaryMetrics = try container.decode([MetricKind].self, forKey: .selectedSummaryMetrics)
        self.temperatureSource = try container.decodeIfPresent(TemperatureSource.self, forKey: .temperatureSource) ?? .smc
        self.preferredLanguageIdentifier = try container.decodeIfPresent(String.self, forKey: .preferredLanguageIdentifier)
        if let categories = try container.decodeIfPresent([DiskCleanupCategoryKind].self, forKey: .diskCleanupCategories) {
            self.diskCleanupCategories = Self.orderedDiskCleanupCategories(from: Set(categories))
        } else if let legacyScope = try container.decodeIfPresent(LegacyDiskCleanupScope.self, forKey: .diskCleanupScope) {
            self.diskCleanupCategories = Self.orderedDiskCleanupCategories(from: Set(legacyScope.categoryKinds))
        } else {
            self.diskCleanupCategories = Self.defaultDiskCleanupCategories
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try container.encode(selectedSummaryMetrics, forKey: .selectedSummaryMetrics)
        try container.encode(temperatureSource, forKey: .temperatureSource)
        try container.encodeIfPresent(preferredLanguageIdentifier, forKey: .preferredLanguageIdentifier)
        try container.encode(diskCleanupCategories, forKey: .diskCleanupCategories)
    }

    public static let diskCleanupCategoryOrder: [DiskCleanupCategoryKind] = [.userCaches, .trash, .userLogs]
    public static let defaultDiskCleanupCategories: [DiskCleanupCategoryKind] = [.userCaches]

    public static func orderedDiskCleanupCategories(from categories: Set<DiskCleanupCategoryKind>) -> [DiskCleanupCategoryKind] {
        diskCleanupCategoryOrder.filter { categories.contains($0) }
    }

    public static let `default` = AppPreferences(
        launchAtLoginEnabled: false,
        selectedSummaryMetrics: [.cpu, .gpu, .memory, .vram, .temperature, .fan, .network],
        temperatureSource: .smc,
        preferredLanguageIdentifier: nil,
        diskCleanupCategories: defaultDiskCleanupCategories
    )
}
