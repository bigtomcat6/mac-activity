import Combine
import Foundation

@MainActor
public final class StatusSummaryModel: ObservableObject {
    @Published public private(set) var summaryText: String
    @Published public private(set) var summaryItems: [StatusSummaryItem]
    private var cancellables: Set<AnyCancellable> = []

    public init(
        store: MetricsStore,
        preferences: PreferencesController,
        formatter: some SummaryFormatting = SummaryFormatter()
    ) {
        let initialSummaryText = formatter.render(
            snapshot: store.snapshot,
            selectedMetrics: preferences.state.selectedSummaryMetrics,
            preferredTemperatureSource: preferences.state.temperatureSource
        )
        let initialSummaryItems = formatter.renderStatusItems(
            snapshot: store.snapshot,
            selectedMetrics: preferences.state.selectedSummaryMetrics,
            preferredTemperatureSource: preferences.state.temperatureSource
        )
        self.summaryText = initialSummaryText
        self.summaryItems = initialSummaryItems

        Publishers.CombineLatest(store.$snapshot, preferences.$state)
            .map { snapshot, state in
                StatusSummaryPresentation(
                    text: formatter.render(
                        snapshot: snapshot,
                        selectedMetrics: state.selectedSummaryMetrics,
                        preferredTemperatureSource: state.temperatureSource
                    ),
                    items: formatter.renderStatusItems(
                        snapshot: snapshot,
                        selectedMetrics: state.selectedSummaryMetrics,
                        preferredTemperatureSource: state.temperatureSource
                    )
                )
            }
            .removeDuplicates()
            .sink { [weak self] presentation in
                self?.summaryText = presentation.text
                self?.summaryItems = presentation.items
            }
            .store(in: &cancellables)
    }
}

private struct StatusSummaryPresentation: Equatable {
    var text: String
    var items: [StatusSummaryItem]
}
