import SwiftUI
import MacActivityCore

struct PreferencesView: View {
    @ObservedObject var preferencesController: PreferencesController
    @ObservedObject var metricsStore: MetricsStore

    private var metricRows: [MetricKind] {
        MetricKind.summaryOrder.filter(shouldDisplayMetric)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(
                    "Show menu bar item",
                    isOn: Binding(
                        get: { preferencesController.state.isMenuBarEnabled },
                        set: { preferencesController.setMenuBarEnabled($0) }
                    )
                )

                Text("If disabled, the app stays reachable from the Dock until you re-enable the menu bar item.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { preferencesController.state.launchAtLoginEnabled },
                        set: { preferencesController.setLaunchAtLoginEnabled($0) }
                    )
                )

                Text("Menu bar metrics")
                    .font(.headline)

                Text("Metrics always render in the fixed MVP order.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(metricRows, id: \.self) { metric in
                    Toggle(
                        metric.title,
                        isOn: Binding(
                            get: {
                                preferencesController.state.selectedSummaryMetrics.contains(metric)
                            },
                            set: { isSelected in
                                var nextSelection = Set(preferencesController.state.selectedSummaryMetrics)
                                if isSelected {
                                    nextSelection.insert(metric)
                                } else {
                                    nextSelection.remove(metric)
                                }
                                preferencesController.setSummarySelection(nextSelection)
                            }
                        )
                    )
                }

                if let error = preferencesController.launchAtLoginError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func shouldDisplayMetric(_ metric: MetricKind) -> Bool {
        switch metric {
        case .temperature:
            return metricsStore.snapshot.temperature != nil
        case .fan:
            return metricsStore.snapshot.fan != nil
        default:
            return true
        }
    }
}
