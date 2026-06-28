import Foundation
import MacActivityCore

enum AppLocalization {
    private static let preferredLanguageLock = NSLock()
    nonisolated(unsafe) private static var preferredLanguageIdentifier: String?

    enum Key: String, CaseIterable {
        case appName = "app.name"
        case preferences = "app.action.preferences"
        case quit = "app.action.quit"
        case live = "dashboard.status.live"
        case dashboardTabOverview = "dashboard.tab.overview"
        case dashboardTabActives = "dashboard.tab.actives"
        case dashboardSection = "dashboard.section.label"
        case dashboardWaitingFirstSample = "dashboard.waiting.firstSample"
        case dashboardWaitingFirstMetricSample = "dashboard.waiting.firstMetricSample"
        case dashboardCPUGPU = "dashboard.cpuGpu"
        case dashboardTrendCollecting = "dashboard.trend.collecting"
        case dashboardStorageAccessibility = "dashboard.storage.accessibility"
        case memoryChartCollectingSamples = "dashboard.memory.chart.collectingSamples"
        case memoryChartAccessibility = "dashboard.memory.chart.accessibility"
        case memorySegmentActive = "dashboard.memory.segment.active"
        case memorySegmentCompressed = "dashboard.memory.segment.compressed"
        case memorySegmentWired = "dashboard.memory.segment.wired"
        case memorySegmentOther = "dashboard.memory.segment.other"
        case memorySegmentTooltip = "dashboard.memory.segment.tooltip"
        case metricCPU = "metric.cpu"
        case metricGPU = "metric.gpu"
        case metricDisk = "metric.disk"
        case metricSwap = "metric.swap"
        case metricMemory = "metric.memory"
        case metricVRAM = "metric.vram"
        case metricNetwork = "metric.network"
        case metricBattery = "metric.battery"
        case metricTemperature = "metric.temperature"
        case metricFan = "metric.fan"
        case metricBatteryCharging = "metric.battery.charging"
        case metricBatteryOnBattery = "metric.battery.onBattery"
        case chartDimensionTime = "chart.dimension.time"
        case chartDimensionPrimary = "chart.dimension.primary"
        case chartDimensionSecondary = "chart.dimension.secondary"
        case chartDimensionSeries = "chart.dimension.series"
        case chartDimensionBaseline = "chart.dimension.baseline"
        case chartDimensionSelection = "chart.dimension.selection"
        case chartDimensionSelectionTime = "chart.dimension.selectionTime"
        case chartDimensionSelectionValue = "chart.dimension.selectionValue"
        case chartTemperatureAxis = "chart.temperature.axis"
        case chartTemperatureReadout = "chart.temperature.readout"
        case chartFanAxis = "chart.fan.axis"
        case chartFanReadout = "chart.fan.readout"
        case networkUpload = "network.upload"
        case networkDownload = "network.download"
        case temperatureSourceCPUSMC = "temperature.source.cpuSMC"
        case temperatureSourceBattery = "temperature.source.battery"
        case temperatureDashboardCPU = "temperature.dashboard.cpu"
        case temperatureDashboardBattery = "temperature.dashboard.battery"
        case preferencesLaunchAtLogin = "preferences.launchAtLogin"
        case preferencesCurrentVersion = "preferences.currentVersion"
        case preferencesCheckForUpdates = "preferences.checkForUpdates"
        case preferencesShowUpdateChannel = "preferences.showUpdateChannel"
        case preferencesHideUpdateChannel = "preferences.hideUpdateChannel"
        case preferencesUpdateChannel = "preferences.updateChannel"
        case preferencesLanguage = "preferences.language"
        case preferencesLanguageHelp = "preferences.languageHelp"
        case preferencesTemperatureSource = "preferences.temperatureSource"
        case preferencesTemperatureHelp = "preferences.temperatureHelp"
        case preferencesHardwareBatteryPercentage = "preferences.hardwareBatteryPercentage"
        case preferencesHardwareBatteryPercentageHelp = "preferences.hardwareBatteryPercentageHelp"
        case preferencesProcessApplicationIdentifier = "preferences.processApplicationIdentifier"
        case preferencesDiskCleanupScope = "preferences.diskCleanupScope"
        case preferencesDiskCleanupHelp = "preferences.diskCleanupHelp"
        case preferencesMenuBarMetrics = "preferences.menuBarMetrics"
        case preferencesMetricsFixedOrder = "preferences.metricsFixedOrder"
        case languageSystem = "language.system"
        case languageSelfName = "language.selfName"
        case languageEnglish = "language.english"
        case languageSimplifiedChinese = "language.simplifiedChinese"
        case updateChannelAlpha = "update.channel.alpha"
        case updateChannelBeta = "update.channel.beta"
        case updateChannelRelease = "update.channel.release"
        case diskCleanupCategoryUserCaches = "diskCleanup.category.userCaches"
        case diskCleanupCategoryTrash = "diskCleanup.category.trash"
        case diskCleanupCategoryUserLogs = "diskCleanup.category.userLogs"
        case memoryReleaseActionRelease = "memoryRelease.action.release"
        case memoryReleaseActionReleasing = "memoryRelease.action.releasing"
        case memoryReleaseTitleIdle = "memoryRelease.title.idle"
        case memoryReleaseTitleUsage = "memoryRelease.title.usage"
        case memoryReleaseTitleReclaimable = "memoryRelease.title.reclaimable"
        case memoryReleaseTitleReleasing = "memoryRelease.title.releasing"
        case memoryReleaseTitleReleased = "memoryRelease.title.released"
        case memoryReleaseTitleNoSignificantRelease = "memoryRelease.title.noSignificantRelease"
        case memoryReleaseTitleCooldown = "memoryRelease.title.cooldown"
        case memoryReleaseTitleUnavailable = "memoryRelease.title.unavailable"
        case memoryReleaseTitleFailed = "memoryRelease.title.failed"
        case memoryReleaseTitleReadFailed = "memoryRelease.title.readFailed"
        case memoryReleaseSubtitleUsage = "memoryRelease.subtitle.usage"
        case memoryReleaseSubtitlePercentOfTotal = "memoryRelease.subtitle.percentOfTotal"
        case memoryReleaseSubtitleNoSignificantRelease = "memoryRelease.subtitle.noSignificantRelease"
        case memoryReleaseSubtitleCooldown = "memoryRelease.subtitle.cooldown"
        case memoryReleaseSubtitleUnavailable = "memoryRelease.subtitle.unavailable"
        case memoryReleaseSubtitleReadFailed = "memoryRelease.subtitle.readFailed"
        case memoryReleaseSubtitleDefault = "memoryRelease.subtitle.default"
        case memoryReleaseSubtitleFailedWithExitCode = "memoryRelease.subtitle.failedWithExitCode"
        case trashActionRetry = "trash.action.retry"
        case trashActionClean = "trash.action.clean"
        case trashTitleScanning = "trash.title.scanning"
        case trashTitleClean = "trash.title.clean"
        case trashTitleCleanable = "trash.title.cleanable"
        case trashTitleCleaning = "trash.title.cleaning"
        case trashTitleCleaned = "trash.title.cleaned"
        case trashTitleFailed = "trash.title.failed"
        case trashSubtitleScanning = "trash.subtitle.scanning"
        case trashSubtitleClean = "trash.subtitle.clean"
        case trashSubtitleCleanable = "trash.subtitle.cleanable"
        case trashSubtitleCleaning = "trash.subtitle.cleaning"
        case trashSubtitleCleaned = "trash.subtitle.cleaned"
        case trashSubtitlePartial = "trash.subtitle.partial"
        case trashSubtitlePartialWithRemaining = "trash.subtitle.partialWithRemaining"
        case trashItemSingular = "trash.item.singular"
        case trashItemPlural = "trash.item.plural"
        case diskCleanupActionRetry = "diskCleanup.action.retry"
        case diskCleanupActionClean = "diskCleanup.action.clean"
        case diskCleanupTitleScanning = "diskCleanup.title.scanning"
        case diskCleanupTitleClean = "diskCleanup.title.clean"
        case diskCleanupTitleCleanable = "diskCleanup.title.cleanable"
        case diskCleanupTitleCleaning = "diskCleanup.title.cleaning"
        case diskCleanupTitleCleaned = "diskCleanup.title.cleaned"
        case diskCleanupTitleFailed = "diskCleanup.title.failed"
        case diskCleanupSubtitleScanning = "diskCleanup.subtitle.scanning"
        case diskCleanupSubtitleClean = "diskCleanup.subtitle.clean"
        case diskCleanupSubtitleCleanable = "diskCleanup.subtitle.cleanable"
        case diskCleanupSubtitleCleaning = "diskCleanup.subtitle.cleaning"
        case diskCleanupSubtitleCleaned = "diskCleanup.subtitle.cleaned"
        case diskCleanupSubtitlePartial = "diskCleanup.subtitle.partial"
        case diskCleanupSubtitlePartialWithRemaining = "diskCleanup.subtitle.partialWithRemaining"
        case diskCleanupItemSingular = "diskCleanup.item.singular"
        case diskCleanupItemPlural = "diskCleanup.item.plural"
        case diskCleanupCategorySingular = "diskCleanup.category.singular"
        case diskCleanupCategoryPlural = "diskCleanup.category.plural"
        case processEmpty = "process.empty"
        case processFallbackName = "process.fallbackName"
        case processActionRequested = "process.action.requested"
        case processActionNotFound = "process.action.notFound"
        case processActionNotTerminable = "process.action.notTerminable"
        case processActionQuit = "process.action.quit"
        case processActionConfirm = "process.action.confirm"
    }

    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    static func availableLanguageIdentifiers(in sourceBundle: Bundle? = nil) -> [String] {
        let targetBundle = sourceBundle ?? bundle
        let resources = localizedResources(in: targetBundle)

        return Array(resources.keys)
            .sorted { lhs, rhs in
                if lhs == "en" {
                    return true
                }
                if rhs == "en" {
                    return false
                }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    private static func localizedResources(in bundle: Bundle) -> [String: String] {
        var resources: [String: String] = [:]

        for identifier in bundle.localizations where identifier != "Base" {
            resources[canonicalLanguageIdentifier(identifier)] = identifier
        }

        if let resourceURL = bundle.resourceURL,
           let resourceContents = try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
           ) {
            for url in resourceContents where url.pathExtension == "lproj" {
                let identifier = url.deletingPathExtension().lastPathComponent
                if identifier != "Base" {
                    resources[canonicalLanguageIdentifier(identifier), default: identifier] = identifier
                }
            }
        }

        return resources
    }

    private static func canonicalLanguageIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .enumerated()
            .map { index, component in
                let value = String(component)
                if index == 0 {
                    return value.lowercased()
                }
                if value.count == 4 {
                    return value.prefix(1).uppercased() + value.dropFirst().lowercased()
                }
                if value.count == 2 || value.count == 3 {
                    return value.uppercased()
                }
                return value
            }
            .joined(separator: "-")
    }

    static func bundle(forLanguageIdentifier languageIdentifier: String) -> Bundle? {
        guard let normalized = normalizedLanguageIdentifier(languageIdentifier) else {
            return nil
        }

        let resources = localizedResources(in: bundle)
        let available = Array(resources.keys)
        let preferred = Bundle.preferredLocalizations(
            from: available,
            forPreferences: [normalized]
        ).first

        guard let preferred,
              let resourceIdentifier = resources[preferred],
              let path = bundle.path(forResource: resourceIdentifier, ofType: "lproj") else {
            return nil
        }

        return Bundle(path: path)
    }

    static func normalizedLanguageIdentifier(_ languageIdentifier: String?) -> String? {
        guard let normalized = languageIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              normalized.isEmpty == false else {
            return nil
        }
        return normalized
    }

    static func setPreferredLanguageIdentifier(_ preferredLanguageIdentifier: String?) {
        preferredLanguageLock.lock()
        self.preferredLanguageIdentifier = normalizedLanguageIdentifier(preferredLanguageIdentifier)
        preferredLanguageLock.unlock()
    }

    static func string(_ key: Key, _ arguments: CVarArg..., bundle: Bundle? = nil) -> String {
        let targetBundle = bundle ?? configuredBundle()
        let format = targetBundle.localizedString(forKey: key.rawValue, value: nil, table: nil)

        guard arguments.isEmpty == false else {
            return format
        }

        return String(
            format: format,
            locale: locale(for: targetBundle),
            arguments: arguments
        )
    }

    static func currentLocale(bundle: Bundle? = nil) -> Locale {
        locale(for: bundle ?? configuredBundle())
    }

    static func metricTitle(for kind: MetricKind, bundle: Bundle? = nil) -> String {
        switch kind {
        case .cpu:
            return string(.metricCPU, bundle: bundle)
        case .gpu:
            return string(.metricGPU, bundle: bundle)
        case .disk:
            return string(.metricDisk, bundle: bundle)
        case .swap:
            return string(.metricSwap, bundle: bundle)
        case .memory:
            return string(.metricMemory, bundle: bundle)
        case .vram:
            return string(.metricVRAM, bundle: bundle)
        case .network:
            return string(.metricNetwork, bundle: bundle)
        case .battery:
            return string(.metricBattery, bundle: bundle)
        case .temperature:
            return string(.metricTemperature, bundle: bundle)
        case .fan:
            return string(.metricFan, bundle: bundle)
        }
    }

    static func metricTitle(for metric: DashboardMetric, bundle: Bundle? = nil) -> String {
        if metric.kind == .temperature {
            switch metric.title {
            case TemperatureSource.battery.dashboardTitle:
                return string(.temperatureDashboardBattery, bundle: bundle)
            case TemperatureSource.smc.dashboardTitle:
                return string(.temperatureDashboardCPU, bundle: bundle)
            default:
                break
            }
        }

        return metricTitle(for: metric.kind, bundle: bundle)
    }

    static func dashboardMetricTitle(for metric: DashboardMetric, bundle: Bundle? = nil) -> String {
        switch metric.titleRole {
        case .metric(let kind):
            return metricTitle(for: kind, bundle: bundle)
        case .temperature(let source):
            switch source {
            case .smc:
                return string(.temperatureDashboardCPU, bundle: bundle)
            case .battery:
                return string(.temperatureDashboardBattery, bundle: bundle)
            }
        }
    }

    static func metricDetail(_ detail: String, bundle: Bundle? = nil) -> String {
        switch detail {
        case "Charging":
            return string(.metricBatteryCharging, bundle: bundle)
        case "On Battery":
            return string(.metricBatteryOnBattery, bundle: bundle)
        default:
            return detail
        }
    }

    static func dashboardMetricDetail(for metric: DashboardMetric, bundle: Bundle? = nil) -> String? {
        guard let detailRole = metric.detailRole else {
            return metric.detail
        }

        switch detailRole {
        case .batteryCharging:
            return string(.metricBatteryCharging, bundle: bundle)
        case .batteryOnBattery:
            return string(.metricBatteryOnBattery, bundle: bundle)
        case .raw(let value):
            return value
        }
    }

    static func storageAccessibilityValue(for metrics: [DashboardMetric], bundle: Bundle? = nil) -> String {
        let targetBundle = bundle ?? configuredBundle()
        let separator = locale(for: targetBundle).identifier.hasPrefix("zh") ? "，" : ", "
        return metrics
            .map { metric in
                let title = dashboardMetricTitle(for: metric, bundle: targetBundle)
                let value = dashboardMetricDetail(for: metric, bundle: targetBundle) ?? metric.value
                return "\(title) \(value)"
            }
            .joined(separator: separator)
    }

    static func formattedTime(_ date: Date, includesSeconds: Bool = false, bundle: Bundle? = nil) -> String {
        var format = Date.FormatStyle.dateTime.hour().minute()
        if includesSeconds {
            format = format.second()
        }
        return date.formatted(format.locale(locale(for: bundle ?? configuredBundle())))
    }

    static func chartAxisLabel(for kind: MetricKind, value: Double, bundle: Bundle? = nil) -> String {
        switch kind {
        case .cpu, .gpu, .disk, .swap, .memory, .vram, .battery:
            return DashboardMetricTextFormatter.formatPercent(value)
        case .temperature:
            return string(.chartTemperatureAxis, value, bundle: bundle)
        case .fan:
            return string(.chartFanAxis, Int(value.rounded()), bundle: bundle)
        case .network:
            return DashboardMetricTextFormatter.formatRate(abs(value))
        }
    }

    static func chartPrimaryReadout(for kind: MetricKind, sample: DashboardTrendSample, bundle: Bundle? = nil) -> String {
        switch kind {
        case .network:
            return "\(string(.networkUpload, bundle: bundle)) \(DashboardMetricTextFormatter.formatRate(sample.secondaryValue ?? 0))"
        case .temperature:
            return string(.chartTemperatureReadout, sample.primaryValue, bundle: bundle)
        case .fan:
            return string(.chartFanReadout, Int(sample.primaryValue.rounded()), bundle: bundle)
        default:
            return DashboardMetricTextFormatter.formatPercent(sample.primaryValue)
        }
    }

    static func chartSecondaryReadout(for kind: MetricKind, sample: DashboardTrendSample, bundle: Bundle? = nil) -> String? {
        guard kind == .network else {
            return nil
        }

        return "\(string(.networkDownload, bundle: bundle)) \(DashboardMetricTextFormatter.formatRate(sample.primaryValue))"
    }

    static func temperatureSourceTitle(for source: TemperatureSource, bundle: Bundle? = nil) -> String {
        switch source {
        case .smc:
            return string(.temperatureSourceCPUSMC, bundle: bundle)
        case .battery:
            return string(.temperatureSourceBattery, bundle: bundle)
        }
    }

    static func languageTitle(for language: AppLanguage, bundle: Bundle? = nil) -> String {
        guard let identifier = language.preferredLanguageIdentifier else {
            return string(.languageSystem, bundle: bundle)
        }

        return displayName(forLanguageIdentifier: identifier)
    }

    static func updateChannelTitle(for channel: UpdateChannel, bundle: Bundle? = nil) -> String {
        switch channel {
        case .alpha:
            return string(.updateChannelAlpha, bundle: bundle)
        case .beta:
            return string(.updateChannelBeta, bundle: bundle)
        case .release:
            return string(.updateChannelRelease, bundle: bundle)
        }
    }

    static func diskCleanupCategoryTitle(for kind: DiskCleanupCategoryKind, bundle: Bundle? = nil) -> String {
        switch kind {
        case .userCaches:
            return string(.diskCleanupCategoryUserCaches, bundle: bundle)
        case .trash:
            return string(.diskCleanupCategoryTrash, bundle: bundle)
        case .userLogs:
            return string(.diskCleanupCategoryUserLogs, bundle: bundle)
        }
    }

    static func memorySegmentTitle(for kind: RAMSegmentBarComponent.Kind, bundle: Bundle? = nil) -> String {
        switch kind {
        case .active:
            return string(.memorySegmentActive, bundle: bundle)
        case .compressed:
            return string(.memorySegmentCompressed, bundle: bundle)
        case .wired:
            return string(.memorySegmentWired, bundle: bundle)
        case .other:
            return string(.memorySegmentOther, bundle: bundle)
        }
    }

    static func memorySegmentTooltip(
        title: String,
        memory: String,
        percent: String,
        bundle: Bundle? = nil
    ) -> String {
        string(.memorySegmentTooltip, title, memory, percent, bundle: bundle)
    }

    static func memoryChartAccessibilityLabel(
        pressurePercent: Int,
        usedMemory: String,
        totalMemory: String,
        bundle: Bundle? = nil
    ) -> String {
        string(.memoryChartAccessibility, pressurePercent, usedMemory, totalMemory, bundle: bundle)
    }

    static func displayName(forLanguageIdentifier identifier: String) -> String {
        guard let languageBundle = bundle(forLanguageIdentifier: identifier) else {
            return identifier
        }

        let value = languageBundle.localizedString(
            forKey: Key.languageSelfName.rawValue,
            value: nil,
            table: nil
        )
        return value == Key.languageSelfName.rawValue ? identifier : value
    }

    private static func locale(for bundle: Bundle) -> Locale {
        if bundle.bundleURL.pathExtension == "lproj" {
            let identifier = canonicalLanguageIdentifier(
                bundle.bundleURL.deletingPathExtension().lastPathComponent
            )
            return Locale(identifier: identifier)
        }

        if let identifier = bundle.preferredLocalizations.first {
            return Locale(identifier: identifier)
        }

        if let identifier = bundle.localizations.first {
            return Locale(identifier: identifier)
        }

        return .current
    }

    private static func configuredBundle() -> Bundle {
        preferredLanguageLock.lock()
        let preferredLanguageIdentifier = self.preferredLanguageIdentifier
        preferredLanguageLock.unlock()

        guard let preferredLanguageIdentifier,
              let overrideBundle = bundle(forLanguageIdentifier: preferredLanguageIdentifier) else {
            return bundle
        }

        return overrideBundle
    }
}
