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

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct LossyAudioProcessProfiles: Decodable {
    let values: [String: AudioProcessProfile]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var result: [String: AudioProcessProfile] = [:]
        for key in container.allKeys {
            guard let profile = try? container.decode(AudioProcessProfile.self, forKey: key),
                  profile.bundleIdentifier == key.stringValue,
                  profile.isDefault == false else {
                continue
            }
            result[key.stringValue] = profile
        }
        self.values = result
    }
}

public struct AppPreferences: Equatable, Codable, Sendable {
    public var launchAtLoginEnabled: Bool
    public var selectedSummaryMetrics: [MetricKind]
    public var temperatureSource: TemperatureSource
    public var preferredLanguageIdentifier: String?
    public var diskCleanupCategories: [DiskCleanupCategoryKind]
    public var showsHardwareBatteryPercentage: Bool
    public var showsProcessApplicationIdentifier: Bool
    public var updateChannel: UpdateChannel
    public var lastSyncedUpdateChannelReleaseTag: String?
    public var audioProcessProfiles: [String: AudioProcessProfile]

    public init(
        launchAtLoginEnabled: Bool,
        selectedSummaryMetrics: [MetricKind],
        temperatureSource: TemperatureSource = .smc,
        preferredLanguageIdentifier: String? = nil,
        diskCleanupCategories: [DiskCleanupCategoryKind] = AppPreferences.defaultDiskCleanupCategories,
        showsHardwareBatteryPercentage: Bool = false,
        showsProcessApplicationIdentifier: Bool = false,
        updateChannel: UpdateChannel = .release,
        lastSyncedUpdateChannelReleaseTag: String? = nil,
        audioProcessProfiles: [String: AudioProcessProfile] = [:]
    ) {
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.selectedSummaryMetrics = selectedSummaryMetrics
        self.temperatureSource = temperatureSource
        self.preferredLanguageIdentifier = preferredLanguageIdentifier
        self.diskCleanupCategories = AppPreferences.orderedDiskCleanupCategories(from: Set(diskCleanupCategories))
        self.showsHardwareBatteryPercentage = showsHardwareBatteryPercentage
        self.showsProcessApplicationIdentifier = showsProcessApplicationIdentifier
        self.updateChannel = updateChannel
        self.lastSyncedUpdateChannelReleaseTag = lastSyncedUpdateChannelReleaseTag
        self.audioProcessProfiles = audioProcessProfiles
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLoginEnabled
        case selectedSummaryMetrics
        case temperatureSource
        case preferredLanguageIdentifier
        case diskCleanupCategories
        case showsHardwareBatteryPercentage
        case showsProcessApplicationIdentifier
        case updateChannel
        case lastSyncedUpdateChannelReleaseTag
        case audioProcessProfiles
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
        self.showsHardwareBatteryPercentage = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsHardwareBatteryPercentage
        ) ?? false
        self.showsProcessApplicationIdentifier = try container.decodeIfPresent(
            Bool.self,
            forKey: .showsProcessApplicationIdentifier
        ) ?? false
        self.updateChannel = try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel) ?? .release
        self.lastSyncedUpdateChannelReleaseTag = try container.decodeIfPresent(
            String.self,
            forKey: .lastSyncedUpdateChannelReleaseTag
        )
        self.audioProcessProfiles = try container.decodeIfPresent(
            LossyAudioProcessProfiles.self,
            forKey: .audioProcessProfiles
        )?.values ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try container.encode(selectedSummaryMetrics, forKey: .selectedSummaryMetrics)
        try container.encode(temperatureSource, forKey: .temperatureSource)
        try container.encodeIfPresent(preferredLanguageIdentifier, forKey: .preferredLanguageIdentifier)
        try container.encode(diskCleanupCategories, forKey: .diskCleanupCategories)
        try container.encode(showsHardwareBatteryPercentage, forKey: .showsHardwareBatteryPercentage)
        try container.encode(showsProcessApplicationIdentifier, forKey: .showsProcessApplicationIdentifier)
        try container.encode(updateChannel, forKey: .updateChannel)
        try container.encodeIfPresent(lastSyncedUpdateChannelReleaseTag, forKey: .lastSyncedUpdateChannelReleaseTag)
        try container.encode(audioProcessProfiles, forKey: .audioProcessProfiles)
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
        diskCleanupCategories: defaultDiskCleanupCategories,
        showsHardwareBatteryPercentage: false,
        showsProcessApplicationIdentifier: false,
        updateChannel: .release,
        audioProcessProfiles: [:]
    )
}
