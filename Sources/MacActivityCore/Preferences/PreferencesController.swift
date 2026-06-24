import Combine
import Foundation

@MainActor
public final class PreferencesController: ObservableObject {
    @Published public private(set) var state: AppPreferences
    @Published public private(set) var launchAtLoginError: String?

    private let store: PreferencesStoring
    private let launchService: LaunchAtLoginServicing

    public init(
        store: PreferencesStoring,
        launchService: LaunchAtLoginServicing
    ) {
        self.store = store
        self.launchService = launchService
        self.state = store.load()
        self.launchAtLoginError = nil
    }

    public func setLaunchAtLoginEnabled(_ enabled: Bool) {
        state.launchAtLoginEnabled = enabled
        do {
            try launchService.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }

        try? store.save(state)
    }

    public func setSummarySelection(_ kinds: Set<MetricKind>) {
        state.selectedSummaryMetrics = MetricKind.summaryOrder.filter { kinds.contains($0) }
        try? store.save(state)
    }

    public func setTemperatureSource(_ source: TemperatureSource) {
        state.temperatureSource = source
        try? store.save(state)
    }

    public func setShowsHardwareBatteryPercentage(_ showsHardwareBatteryPercentage: Bool) {
        state.showsHardwareBatteryPercentage = showsHardwareBatteryPercentage
        try? store.save(state)
    }

    public func setUpdateChannel(_ updateChannel: UpdateChannel) {
        state.updateChannel = updateChannel
        try? store.save(state)
    }

    public func setPreferredLanguageIdentifier(_ preferredLanguageIdentifier: String?) {
        state.preferredLanguageIdentifier = preferredLanguageIdentifier
        try? store.save(state)
    }

    public func setDiskCleanupCategory(_ kind: DiskCleanupCategoryKind, isSelected: Bool) {
        var selectedCategories = Set(state.diskCleanupCategories)
        if isSelected {
            selectedCategories.insert(kind)
        } else {
            selectedCategories.remove(kind)
        }

        state.diskCleanupCategories = AppPreferences.orderedDiskCleanupCategories(from: selectedCategories)
        try? store.save(state)
    }
}
