import SwiftUI
import MacActivityCore

struct PreferencesView: View {
    @ObservedObject var preferencesController: PreferencesController
    @ObservedObject private var localizationController = AppLocalizationController.shared

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
                    Text(AppLocalization.string(.preferencesLanguage))
                        .font(.headline)

                    Picker(
                        AppLocalization.string(.preferencesLanguage),
                        selection: Binding(
                            get: {
                                AppLanguage(
                                    preferredLanguageIdentifier: preferencesController.state.preferredLanguageIdentifier
                                )
                            },
                            set: { language in
                                preferencesController.setPreferredLanguageIdentifier(language.preferredLanguageIdentifier)
                            }
                        )
                    ) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(AppLocalization.languageTitle(for: language))
                                .tag(language)
                        }
                    }
                    .pickerStyle(.menu)

                    Text(AppLocalization.string(.preferencesLanguageHelp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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
