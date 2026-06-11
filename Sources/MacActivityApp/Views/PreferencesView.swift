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
                    AppLocalization.string(.preferencesLaunchAtLogin),
                    isOn: Binding(
                        get: { preferencesController.state.launchAtLoginEnabled },
                        set: { preferencesController.setLaunchAtLoginEnabled($0) }
                    )
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.string(.preferencesTemperatureSource))
                        .font(.headline)

                    Picker(
                        AppLocalization.string(.preferencesTemperatureSource),
                        selection: Binding(
                            get: { preferencesController.state.temperatureSource },
                            set: { preferencesController.setTemperatureSource($0) }
                        )
                    ) {
                        ForEach(TemperatureSource.allCases, id: \.self) { source in
                            Text(AppLocalization.temperatureSourceTitle(for: source))
                                .tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(AppLocalization.string(.preferencesTemperatureHelp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.string(.preferencesDiskCleanupScope))
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(AppPreferences.diskCleanupCategoryOrder, id: \.self) { category in
                            Toggle(
                                AppLocalization.diskCleanupCategoryTitle(for: category),
                                isOn: Binding(
                                    get: { preferencesController.state.diskCleanupCategories.contains(category) },
                                    set: { preferencesController.setDiskCleanupCategory(category, isSelected: $0) }
                                )
                            )
                        }
                    }

                    Text(AppLocalization.string(.preferencesDiskCleanupHelp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(AppLocalization.string(.preferencesMenuBarMetrics))
                    .font(.headline)

                Text(AppLocalization.string(.preferencesMetricsFixedOrder))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(metricRows, id: \.self) { metric in
                    Toggle(
                        AppLocalization.metricTitle(for: metric),
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
