import Foundation
import MacActivityCore

enum AppLocalization {
    private static let preferredLanguageLock = NSLock()
    nonisolated(unsafe) private static var preferredLanguageIdentifier: String?

    enum Key: String {
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

    static func bundle(forLanguageIdentifier languageIdentifier: String) -> Bundle? {
        let candidates = [
            languageIdentifier,
            languageIdentifier.lowercased(),
        ]

        guard let path = candidates.lazy.compactMap({ bundle.path(forResource: $0, ofType: "lproj") }).first else {
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

    static func temperatureSourceTitle(for source: TemperatureSource, bundle: Bundle? = nil) -> String {
        switch source {
        case .smc:
            return string(.temperatureSourceCPUSMC, bundle: bundle)
        case .battery:
            return string(.temperatureSourceBattery, bundle: bundle)
        }
    }

    static func languageTitle(for language: AppLanguage, bundle: Bundle? = nil) -> String {
        switch language {
        case .system:
            return string(.languageSystem, bundle: bundle)
        case .english:
            return string(.languageEnglish, bundle: bundle)
        case .simplifiedChinese:
            return string(.languageSimplifiedChinese, bundle: bundle)
        }
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

    private static func locale(for bundle: Bundle) -> Locale {
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
