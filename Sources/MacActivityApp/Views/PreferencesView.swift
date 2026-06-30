import SwiftUI
import MacActivityCore

@MainActor
final class PreferencesViewState: ObservableObject {
    @Published var isUpdateChannelExpanded: Bool

    init(isUpdateChannelExpanded: Bool = false) {
        self.isUpdateChannelExpanded = isUpdateChannelExpanded
    }

    func collapseUpdateChannel() {
        isUpdateChannelExpanded = false
    }
}

struct PreferencesView: View {
    @ObservedObject var preferencesController: PreferencesController
    @ObservedObject private var localizationController = AppLocalizationController.shared
    @ObservedObject private var viewState: PreferencesViewState

    private let versionInfo: PreferencesVersionInfo
    private let checkForUpdates: () -> Void

    init(
        preferencesController: PreferencesController,
        versionInfo: PreferencesVersionInfo = .current(),
        viewState: PreferencesViewState? = nil,
        isUpdateChannelExpanded: Bool = false,
        checkForUpdates: @escaping () -> Void
    ) {
        self.preferencesController = preferencesController
        self.versionInfo = versionInfo
        self.viewState = viewState ?? PreferencesViewState(isUpdateChannelExpanded: isUpdateChannelExpanded)
        self.checkForUpdates = checkForUpdates
    }

    private var metricRows: [MetricKind] {
        MetricKind.summaryOrder
    }

    var localizationRefreshID: String {
        localizationController.preferredLanguageIdentifier ?? "system"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                updateHeader

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
                        ForEach(AppLanguage.supportedLanguages()) { language in
                            Text(AppLocalization.languageTitle(for: language))
                                .tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    .id("language-\(localizationRefreshID)")

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
                    .id("temperature-\(localizationRefreshID)")

                    Text(AppLocalization.string(.preferencesTemperatureHelp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        AppLocalization.string(.preferencesHardwareBatteryPercentage),
                        isOn: Binding(
                            get: { preferencesController.state.showsHardwareBatteryPercentage },
                            set: { preferencesController.setShowsHardwareBatteryPercentage($0) }
                        )
                    )

                    Text(AppLocalization.string(.preferencesHardwareBatteryPercentageHelp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    AppLocalization.string(.preferencesProcessApplicationIdentifier),
                    isOn: Binding(
                        get: { preferencesController.state.showsProcessApplicationIdentifier },
                        set: { preferencesController.setShowsProcessApplicationIdentifier($0) }
                    )
                )

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

    private var updateHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(AppLocalization.string(.preferencesCurrentVersion))
                    .foregroundStyle(.secondary)

                Text(versionInfo.displayText)
                    .monospacedDigit()

                Button {
                    toggleUpdateChannelExpanded()
                } label: {
                    Image(systemName: viewState.isUpdateChannelExpanded ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .help(
                    AppLocalization.string(
                        viewState.isUpdateChannelExpanded ? .preferencesHideUpdateChannel : .preferencesShowUpdateChannel
                    )
                )
                .accessibilityLabel(
                    AppLocalization.string(
                        viewState.isUpdateChannelExpanded ? .preferencesHideUpdateChannel : .preferencesShowUpdateChannel
                    )
                )

                Spacer(minLength: 12)

                Button(AppLocalization.string(.preferencesCheckForUpdates), action: checkForUpdates)
            }

            if viewState.isUpdateChannelExpanded {
                HStack(spacing: 8) {
                    Text(AppLocalization.string(.preferencesUpdateChannel))

                    Picker(
                        AppLocalization.string(.preferencesUpdateChannel),
                        selection: Binding(
                            get: { preferencesController.state.updateChannel },
                            set: { preferencesController.setUpdateChannel($0) }
                        )
                    ) {
                        ForEach(UpdateChannel.allCases, id: \.self) { channel in
                            updateChannelOption(for: channel)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .id("update-channel-\(localizationRefreshID)")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    func toggleUpdateChannelExpanded() {
        withAnimation(.easeInOut(duration: 0.16)) {
            viewState.isUpdateChannelExpanded.toggle()
        }
    }

    @ViewBuilder
    func updateChannelOption(for channel: UpdateChannel) -> some View {
        Text(AppLocalization.updateChannelTitle(for: channel))
            .tag(channel)
    }
}

struct PreferencesVersionInfo: Equatable {
    var shortVersion: String
    var build: String?

    var displayText: String {
        let trimmedBuild = build?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedBuild, trimmedBuild.isEmpty == false else {
            return shortVersion
        }

        return "\(shortVersion) (\(trimmedBuild))"
    }

    static func current(bundle: Bundle = .main) -> PreferencesVersionInfo {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let releaseTag = cleanInfoValue("MacActivityReleaseTag", in: bundle),
           releaseTag != "v\(shortVersion)" {
            return PreferencesVersionInfo(shortVersion: releaseTag, build: nil)
        }

        return PreferencesVersionInfo(shortVersion: shortVersion, build: build)
    }

    private static func cleanInfoValue(_ key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }

        return trimmed
    }
}
