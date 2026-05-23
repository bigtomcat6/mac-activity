import SwiftUI
import MacActivityCore

struct PreferencesView: View {
    @ObservedObject var preferencesController: PreferencesController

    private var metricRows: [MetricKind] {
        MetricKind.summaryOrder
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { preferencesController.state.launchAtLoginEnabled },
                        set: { preferencesController.setLaunchAtLoginEnabled($0) }
                    )
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature source")
                        .font(.headline)

                    Picker(
                        "Temperature source",
                        selection: Binding(
                            get: { preferencesController.state.temperatureSource },
                            set: { preferencesController.setTemperatureSource($0) }
                        )
                    ) {
                        ForEach(TemperatureSource.allCases, id: \.self) { source in
                            Text(source.preferencesTitle)
                                .tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Controls the Temperature metric in the status bar and dashboard.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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
}
