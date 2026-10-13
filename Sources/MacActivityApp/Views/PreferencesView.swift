import SwiftUI
import MacActivityCore

enum PreferencesCategory: String, CaseIterable, Hashable {
    case general
    case menuBar
    case monitoring
    case cleanup
    case aboutUpdates

    var titleKey: AppLocalization.Key {
        switch self {
        case .general: .preferencesCategoryGeneral
        case .menuBar: .preferencesCategoryMenuBar
        case .monitoring: .preferencesCategoryMonitoring
        case .cleanup: .preferencesCategoryCleanup
        case .aboutUpdates: .preferencesCategoryAboutUpdates
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .monitoring: "gauge"
        case .cleanup: "externaldrive"
        case .aboutUpdates: "info.circle"
        }
    }
}

@MainActor
final class PreferencesViewState: ObservableObject {
    @Published var selectedCategory: PreferencesCategory
    @Published var hoveredCategory: PreferencesCategory?

    init(selectedCategory: PreferencesCategory = .general) {
        self.selectedCategory = selectedCategory
    }
}

struct PreferencesView: View {
    @ObservedObject var preferencesController: PreferencesController
    @ObservedObject private var localizationController = AppLocalizationController.shared
    @ObservedObject var viewState: PreferencesViewState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let versionInfo: PreferencesVersionInfo
    private let checkForUpdates: () -> Void

    init(
        preferencesController: PreferencesController,
        versionInfo: PreferencesVersionInfo = .current(),
        viewState: PreferencesViewState? = nil,
        checkForUpdates: @escaping () -> Void
    ) {
        self.preferencesController = preferencesController
        self.versionInfo = versionInfo
        self.viewState = viewState ?? PreferencesViewState()
        self.checkForUpdates = checkForUpdates
    }

    private var metricRows: [MetricKind] {
        MetricKind.summaryOrder
    }

    var localizationRefreshID: String {
        localizationController.preferredLanguageIdentifier ?? "system"
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: sidebarSelection) {
                    ForEach(PreferencesCategory.allCases.filter { $0 != .aboutUpdates }, id: \.self) { category in
                        sidebarRow(category)
                    }
                }
                List(selection: sidebarSelection) {
                    sidebarRow(.aboutUpdates)
                }
                .frame(height: 52)
                .scrollDisabled(true)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: viewState.selectedCategory.systemImage)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)

                    Text(AppLocalization.string(viewState.selectedCategory.titleKey))
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 8)

                Form {
                    selectedPage
                }
                .formStyle(.grouped)
                .toggleStyle(.switch)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebarSelection: Binding<PreferencesCategory?> {
        Binding(
            get: { viewState.selectedCategory },
            set: { category in
                guard let category else { return }
                // Native lists can report selection while SwiftUI is updating their views.
                DispatchQueue.main.async { [viewState] in
                    guard viewState.selectedCategory != category else { return }
                    viewState.selectedCategory = category
                }
            }
        )
    }

    private func sidebarRow(_ category: PreferencesCategory) -> some View {
        let isSelected = viewState.selectedCategory == category
        let isHovered = viewState.hoveredCategory == category
        let isHighlighted = isSelected || isHovered
        return Label(AppLocalization.string(category.titleKey), systemImage: category.systemImage)
            .foregroundStyle(isSelected ? Color.blue : Color.primary)
            .fontWeight(isSelected ? .semibold : .regular)
            .listItemTint(isSelected ? Color.blue : Color.primary)
            .background(SidebarSelectionHighlight().allowsHitTesting(false))
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .opacity(isHighlighted ? 1 : 0)
                    .padding(.horizontal, 10)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.14),
                        value: isHovered
                    )
            )
            .onHover { isHovering in
                if isHovering {
                    viewState.hoveredCategory = category
                } else if viewState.hoveredCategory == category {
                    viewState.hoveredCategory = nil
                }
            }
            .tag(category)
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch viewState.selectedCategory {
        case .general: generalPage
        case .menuBar: menuBarPage
        case .monitoring: monitoringPage
        case .cleanup: cleanupPage
        case .aboutUpdates: aboutUpdatesPage
        }
    }

    private var generalPage: some View {
        Group {
            Section {
                Toggle(
                    AppLocalization.string(.preferencesLaunchAtLogin),
                    isOn: Binding(
                        get: { preferencesController.state.launchAtLoginEnabled },
                        set: { preferencesController.setLaunchAtLoginEnabled($0) }
                    )
                )
                if let error = preferencesController.launchAtLoginError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
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
                        Text(AppLocalization.languageTitle(for: language)).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .id("language-\(localizationRefreshID)")
            } footer: {
                Text(AppLocalization.string(.preferencesLanguageHelp))
            }
        }
    }

    private var menuBarPage: some View {
        Section {
            ForEach(metricRows, id: \.self) { metric in
                Toggle(
                    AppLocalization.metricTitle(for: metric),
                    isOn: Binding(
                        get: { preferencesController.state.selectedSummaryMetrics.contains(metric) },
                        set: { isSelected in
                            var selection = Set(preferencesController.state.selectedSummaryMetrics)
                            if isSelected {
                                selection.insert(metric)
                            } else {
                                selection.remove(metric)
                            }
                            preferencesController.setSummarySelection(selection)
                        }
                    )
                )
            }
        } header: {
            Text(AppLocalization.string(.preferencesMenuBarMetrics))
        } footer: {
            Text(AppLocalization.string(.preferencesMetricsFixedOrder))
        }
    }

    private var monitoringPage: some View {
        Group {
            Section {
                Picker(
                    AppLocalization.string(.preferencesTemperatureSource),
                    selection: Binding(
                        get: { preferencesController.state.temperatureSource },
                        set: { preferencesController.setTemperatureSource($0) }
                    )
                ) {
                    ForEach(TemperatureSource.allCases, id: \.self) { source in
                        Text(AppLocalization.temperatureSourceTitle(for: source)).tag(source)
                    }
                }
                .pickerStyle(.menu)
                .id("temperature-\(localizationRefreshID)")
            } footer: {
                Text(AppLocalization.string(.preferencesTemperatureHelp))
            }

            Section {
                Toggle(
                    AppLocalization.string(.preferencesHardwareBatteryPercentage),
                    isOn: Binding(
                        get: { preferencesController.state.showsHardwareBatteryPercentage },
                        set: { preferencesController.setShowsHardwareBatteryPercentage($0) }
                    )
                )
            } footer: {
                Text(AppLocalization.string(.preferencesHardwareBatteryPercentageHelp))
            }

            Section {
                Toggle(
                    AppLocalization.string(.preferencesProcessApplicationIdentifier),
                    isOn: Binding(
                        get: { preferencesController.state.showsProcessApplicationIdentifier },
                        set: { preferencesController.setShowsProcessApplicationIdentifier($0) }
                    )
                )
            }

            Section {
                Picker(
                    AppLocalization.string(.preferencesEnergyImpactAppScope),
                    selection: Binding(
                        get: { preferencesController.state.energyImpactAppScope },
                        set: { preferencesController.setEnergyImpactAppScope($0) }
                    )
                ) {
                    ForEach(EnergyImpactAppScope.allCases, id: \.rawValue) { scope in
                        Text(AppLocalization.energyImpactScopeTitle(for: scope)).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .id("energy-impact-scope-\(localizationRefreshID)")
            }
        }
    }

    private var cleanupPage: some View {
        Section {
            ForEach(AppPreferences.diskCleanupCategoryOrder, id: \.self) { category in
                Toggle(
                    AppLocalization.diskCleanupCategoryTitle(for: category),
                    isOn: Binding(
                        get: { preferencesController.state.diskCleanupCategories.contains(category) },
                        set: { preferencesController.setDiskCleanupCategory(category, isSelected: $0) }
                    )
                )
            }
        } header: {
            Text(AppLocalization.string(.preferencesDiskCleanupScope))
        } footer: {
            Text(AppLocalization.string(.preferencesDiskCleanupHelp))
        }
    }

    private var aboutUpdatesPage: some View {
        Section {
            LabeledContent(AppLocalization.string(.preferencesCurrentVersion)) {
                Text(versionInfo.displayText).monospacedDigit()
            }

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
            .pickerStyle(.menu)
            .id("update-channel-\(localizationRefreshID)")

            Button(AppLocalization.string(.preferencesCheckForUpdates), action: checkForUpdates)
        }
    }

    @ViewBuilder
    func updateChannelOption(for channel: UpdateChannel) -> some View {
        Text(AppLocalization.updateChannelTitle(for: channel))
            .tag(channel)
    }
}

// List's native mouse-down highlight precedes its SwiftUI selection binding.
// Keep native selection, but let the shared gray row background own its appearance.
private struct SidebarSelectionHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionView { SelectionView() }

    func updateNSView(_ view: SelectionView, context: Context) {
        view.disableNativeHighlight()
    }

    final class SelectionView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disableNativeHighlight()
        }

        func disableNativeHighlight() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = view.superview
            }
        }
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
