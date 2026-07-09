import SwiftUI
import MacActivityCore

enum DashboardMotion {
    static let hoverDuration: Double = 0.14
    static let sampleDuration: Double = 0.32
    static let domainDuration: Double = 0.38
    static let valueDuration: Double = 0.42

    static var focusPaletteAnimation: Animation? { nil }
    static var hoverAnimation: Animation { .easeInOut(duration: hoverDuration) }
    static var sampleAnimation: Animation { .smooth(duration: sampleDuration) }
    static var domainAnimation: Animation { .smooth(duration: domainDuration) }
    static var valueAnimation: Animation { .easeOut(duration: valueDuration) }
}

enum DashboardCardLayout {
    static let compactChartHeight: CGFloat = 60
    static let compactChartMinHeight: CGFloat = 116
    static let compactChartInsets = EdgeInsets(top: 8, leading: 8, bottom: 6, trailing: 8)
    static let regularCardInsets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    static let cardChromeMaxHeight = CGFloat.infinity

    static func usesCompactHoverLayout(for chartHeight: CGFloat) -> Bool {
        chartHeight <= 64
    }

    static func chartHeightBehavior(for kind: MetricKind) -> DashboardChartHeightBehavior {
        switch kind {
        case .memory, .network:
            .fillsRemainingHeight
        default:
            .fixed(compactChartHeight)
        }
    }
}

enum DashboardChartHeightBehavior: Equatable {
    case fixed(CGFloat)
    case fillsRemainingHeight
}

enum DashboardOverviewSlot: Equatable {
    case usage
    case storage
    case metric(MetricKind)
}

enum DashboardStorageCardContent: Hashable {
    case details
    case bar
}

struct DashboardStorageUsageSegment: Equatable, Identifiable, Sendable {
    var kind: MetricKind
    var startProgress: Double
    var widthProgress: Double

    var id: MetricKind { kind }
}

struct DashboardStorageUsageLabel: Equatable, Identifiable, Sendable {
    var kind: MetricKind
    var startProgress: Double
    var rowIndex: Int
    var rowCount: Int = 2
    var endProgress: Double?

    var id: MetricKind { kind }
}

enum DashboardOverviewLayout {
    static let sectionSpacing: CGFloat = 12
    static let topRowColumns = [GridItem(.flexible()), GridItem(.flexible())]
    static let secondRowColumns = [
        GridItem(.flexible(minimum: 0), spacing: 12),
        GridItem(.flexible(minimum: 0), spacing: 12)
    ]
    static let topSplitCardHeight = compactTrendCardHeight
    static let topRowHeight = topSplitCardHeight * 2 + sectionSpacing
    static let usageLabelColumnWidth: CGFloat = 54
    static let usageValueColumnWidth: CGFloat = 44
    static let usageRowSpacing: CGFloat = 10
    static let usageBarHeight: CGFloat = 8
    static let usageContentMaxWidth = CGFloat.infinity
    static let usageCardContentAlignment: Alignment = .center
    static let storageContentMaxWidth: CGFloat = 180
    static let storageContentSpacing: CGFloat = 0
    static let storageBarHeight: CGFloat = usageBarHeight
    static let storageDetailRowCount = 2
    static let storageDetailRowHeight: CGFloat = 14
    static let storageDetailRowSpacing: CGFloat = 2
    static let storageDetailBarSpacing: CGFloat = 4
    static let storageDetailMarkerWidth: CGFloat = 1
    static let storageDetailIconCenterOffset: CGFloat = 7
    static let storageSwapMinimumVisibleWidth = 0.02
    static let storageDetailMarkerOpacity: Double = 0.28
    static let storageTrailingFallbackMinWidth: CGFloat = 92
    static let storageDetailContentAlignment: Alignment = .leading
    static let storageDetailTextAlignment: TextAlignment = .leading
    static let storageDetailSpacing: CGFloat = 4
    static let metricTitleIconSpacing: CGFloat = 4
    static let storageDetailAreaHeight = storageDetailRowHeight * CGFloat(storageDetailRowCount) + storageDetailRowSpacing + storageDetailBarSpacing
    static let storageCardContentOrder: [DashboardStorageCardContent] = [.details, .bar]
    static let compactTrendChartHeight: CGFloat = 44
    static let compactFanTrendChartHeight: CGFloat = 32
    static let compactTrendRestTextChartSpacing: CGFloat = 12
    static let compactTrendCardHeight: CGFloat = 64
    static let secondRowHeight = compactTrendCardHeight * 2 + sectionSpacing
    static let slimTrendCardHeight = (
        DashboardCardLayout.compactChartHeight
        + DashboardCardLayout.compactChartInsets.top
        + DashboardCardLayout.compactChartInsets.bottom
    )
    static let batteryRowHeight = slimTrendCardHeight

    static func metricsByKind(_ metrics: [DashboardMetric]) -> [MetricKind: DashboardMetric] {
        Dictionary(uniqueKeysWithValues: metrics.map { ($0.kind, $0) })
    }

    static func topRowSlots(for metrics: [DashboardMetric]) -> [DashboardOverviewSlot] {
        let byKind = metricsByKind(metrics)
        var slots: [DashboardOverviewSlot] = []
        if hasComputeUsageMetric(in: byKind) { slots.append(.usage) }
        if hasStorageUsageMetric(in: byKind) { slots.append(.storage) }
        if byKind[.memory] != nil { slots.append(.metric(.memory)) }
        return slots
    }

    static func secondRowLeadingSlot(for metrics: [DashboardMetric]) -> DashboardOverviewSlot? {
        metricsByKind(metrics)[.network] == nil ? nil : .metric(.network)
    }

    static func secondRowTrailingSlots(for metrics: [DashboardMetric]) -> [DashboardOverviewSlot] {
        let byKind = metricsByKind(metrics)
        return [MetricKind.temperature, .fan].compactMap { kind in
            byKind[kind] == nil ? nil : .metric(kind)
        }
    }

    static func thirdRowSlots(for metrics: [DashboardMetric]) -> [DashboardOverviewSlot] {
        metricsByKind(metrics)[.battery] == nil ? [] : [.metric(.battery)]
    }

    static func hasUsageMetric(in metricsByKind: [MetricKind: DashboardMetric]) -> Bool {
        hasComputeUsageMetric(in: metricsByKind) || hasStorageUsageMetric(in: metricsByKind)
    }

    static func hasComputeUsageMetric(in metricsByKind: [MetricKind: DashboardMetric]) -> Bool {
        !computeUsageMetricKinds(in: metricsByKind).isEmpty
    }

    static func hasStorageUsageMetric(in metricsByKind: [MetricKind: DashboardMetric]) -> Bool {
        !storageUsageMetricKinds(in: metricsByKind).isEmpty
    }

    static func computeUsageMetricKinds(in metricsByKind: [MetricKind: DashboardMetric]) -> [MetricKind] {
        [.cpu, .gpu].filter { metricsByKind[$0] != nil }
    }

    static func storageUsageMetricKinds(in metricsByKind: [MetricKind: DashboardMetric]) -> [MetricKind] {
        [.disk, .swap].filter { kind in
            guard let metric = metricsByKind[kind] else { return false }
            return isVisibleStorageMetric(metric)
        }
    }

    static func storageDetailIconName(for kind: MetricKind) -> String? {
        switch kind {
        case .disk, .swap:
            return metricIconName(for: kind)
        default:
            return nil
        }
    }

    static func metricIconName(for kind: MetricKind) -> String? {
        switch kind {
        case .cpu:
            return "cpu"
        case .gpu:
            return "display"
        case .disk:
            return "externaldrive"
        case .swap:
            return "memorychip"
        case .memory:
            return "memorychip"
        case .vram:
            return nil
        case .network:
            return "network"
        case .battery:
            return "battery.100"
        case .temperature:
            return "thermometer"
        case .fan:
            return "fanblades"
        }
    }

    static func storageDetailValue(for metric: DashboardMetric) -> String {
        if metric.kind == .swap, let usedBytes = metric.usedBytes {
            return DashboardMetricTextFormatter.formatBytes(usedBytes)
        }
        return AppLocalization.dashboardMetricDetail(for: metric) ?? metric.value
    }

    static func usageProgress(for value: String) -> Double {
        let percentText = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%", with: "")
        guard let percent = Double(percentText) else { return 0 }
        return clampedProgress(percent / 100)
    }

    static func usageProgress(for metric: DashboardMetric) -> Double {
        if let progress = metric.progress {
            return clampedProgress(progress)
        }
        return usageProgress(for: metric.value)
    }

    static func storageUsageSegments(for metrics: [DashboardMetric]) -> [DashboardStorageUsageSegment] {
        let visibleMetrics = visibleStorageUsageMetrics(in: metrics)
        guard let diskTotalBytes = metrics.first(where: { $0.kind == .disk })?.totalBytes,
              diskTotalBytes > 0 else {
            return equalSlotStorageUsageSegments(for: visibleMetrics)
        }

        let diskEndProgress = visibleMetrics
            .first { $0.kind == .disk }
            .map { storageWidthProgress(for: $0, diskTotalBytes: diskTotalBytes) } ?? 0
        return visibleMetrics.map { metric in
            let widthProgress = storageWidthProgress(
                for: metric,
                diskTotalBytes: diskTotalBytes,
                diskEndProgress: diskEndProgress
            )
            let segment = DashboardStorageUsageSegment(
                kind: metric.kind,
                startProgress: storageStartProgress(
                    for: metric,
                    widthProgress: widthProgress,
                    diskEndProgress: diskEndProgress
                ),
                widthProgress: widthProgress
            )
            return segment
        }
    }

    static func storageUsageLabels(for metrics: [DashboardMetric]) -> [DashboardStorageUsageLabel] {
        let segments = storageUsageSegments(for: metrics)
        return segments.enumerated().map { index, segment in
            DashboardStorageUsageLabel(
                kind: segment.kind,
                startProgress: segment.startProgress,
                rowIndex: index,
                rowCount: segments.count,
                endProgress: clampedProgress(segment.startProgress + segment.widthProgress)
            )
        }
    }

    static func visibleStorageUsageMetrics(in metrics: [DashboardMetric]) -> [DashboardMetric] {
        metrics.filter(isVisibleStorageMetric)
    }

    static func storageDetailHeight(for metrics: [DashboardMetric]) -> CGFloat {
        storageDetailHeight(rowCount: storageUsageLabels(for: metrics).count)
    }

    static func storageConnectorYPosition(for label: DashboardStorageUsageLabel) -> CGFloat {
        CGFloat(label.rowIndex) * (storageDetailRowHeight + storageDetailRowSpacing) + storageDetailRowHeight
    }

    static func storageConnectorHeight(for label: DashboardStorageUsageLabel) -> CGFloat {
        max(0, storageDetailHeight(rowCount: label.rowCount) - storageConnectorYPosition(for: label))
    }

    static func storageDetailUsesTrailingFallback(for label: DashboardStorageUsageLabel, containerWidth: CGFloat) -> Bool {
        label.kind == .swap
            && containerWidth - storageDetailNormalRowXPosition(for: label, containerWidth: containerWidth)
                < storageTrailingFallbackMinWidth
    }

    static func storageDetailRowXPosition(for label: DashboardStorageUsageLabel, containerWidth: CGFloat) -> CGFloat {
        storageDetailUsesTrailingFallback(for: label, containerWidth: containerWidth)
            ? 0
            : storageDetailRowAnchorXPosition(for: label, containerWidth: containerWidth)
    }

    static func storageDetailRowWidth(for label: DashboardStorageUsageLabel, containerWidth: CGFloat) -> CGFloat {
        if storageDetailUsesTrailingFallback(for: label, containerWidth: containerWidth) {
            return storageDetailTrailingFallbackRowWidth(for: label, containerWidth: containerWidth)
        }
        return max(0, containerWidth - storageDetailNormalRowXPosition(for: label, containerWidth: containerWidth))
    }

    static func storageDetailRowAlignment(for label: DashboardStorageUsageLabel, containerWidth: CGFloat) -> Alignment {
        storageDetailUsesTrailingFallback(for: label, containerWidth: containerWidth) ? .trailing : .leading
    }

    static func storageDetailRowTextAlignment(for label: DashboardStorageUsageLabel, containerWidth: CGFloat) -> TextAlignment {
        storageDetailUsesTrailingFallback(for: label, containerWidth: containerWidth) ? .trailing : storageDetailTextAlignment
    }

    static func storageDetailMarkerXPosition(for label: DashboardStorageUsageLabel, containerWidth: CGFloat) -> CGFloat {
        return min(
            max(storageDetailIconCenterXPosition(for: label, containerWidth: containerWidth), 0),
            max(0, containerWidth - storageDetailMarkerWidth)
        )
    }

    static func storageDetailRowAnchorXPosition(for label: DashboardStorageUsageLabel, containerWidth: CGFloat) -> CGFloat {
        storageDetailNormalRowXPosition(for: label, containerWidth: containerWidth)
    }

    private static func storageDetailNormalRowXPosition(
        for label: DashboardStorageUsageLabel,
        containerWidth: CGFloat
    ) -> CGFloat {
        let iconCenterX = storageDetailIconCenterXPosition(for: label, containerWidth: containerWidth)
        let iconOffset = storageDetailIconName(for: label.kind) == nil ? 0 : storageDetailIconCenterOffset
        return min(max(iconCenterX - iconOffset, 0), containerWidth)
    }

    private static func storageDetailTrailingFallbackRowWidth(
        for label: DashboardStorageUsageLabel,
        containerWidth: CGFloat
    ) -> CGFloat {
        min(
            containerWidth,
            max(0, storageDetailIconCenterXPosition(for: label, containerWidth: containerWidth) + storageDetailIconCenterOffset)
        )
    }

    private static func storageDetailIconCenterXPosition(
        for label: DashboardStorageUsageLabel,
        containerWidth: CGFloat
    ) -> CGFloat {
        let progressX = min(max(CGFloat(storageDetailAnchorProgress(for: label)) * containerWidth, 0), containerWidth)
        let iconOffset = storageDetailIconName(for: label.kind) == nil ? 0 : storageDetailIconCenterOffset
        guard label.kind == .swap, label.endProgress != nil else {
            return progressX + iconOffset
        }
        return progressX
    }

    private static func storageDetailAnchorProgress(for label: DashboardStorageUsageLabel) -> Double {
        guard label.kind == .swap, let endProgress = label.endProgress else {
            return label.startProgress
        }
        return clampedProgress((label.startProgress + endProgress) / 2)
    }

    private static func equalSlotStorageUsageSegments(for metrics: [DashboardMetric]) -> [DashboardStorageUsageSegment] {
        let segmentCount = max(metrics.count, 1)
        let segmentWidth = 1 / Double(segmentCount)
        return metrics.enumerated().map { index, metric in
            DashboardStorageUsageSegment(
                kind: metric.kind,
                startProgress: segmentWidth * Double(index),
                widthProgress: segmentWidth * usageProgress(for: metric)
            )
        }
    }

    private static func isVisibleStorageMetric(_ metric: DashboardMetric) -> Bool {
        guard metric.kind == .swap else { return true }
        if let usedBytes = metric.usedBytes {
            return usedBytes > 0
        }
        return usageProgress(for: metric) > 0
    }

    private static func storageDetailHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return storageDetailRowHeight * CGFloat(rowCount)
            + storageDetailRowSpacing * CGFloat(max(0, rowCount - 1))
            + storageDetailBarSpacing
    }

    private static func storageWidthProgress(
        for metric: DashboardMetric,
        diskTotalBytes: UInt64,
        diskEndProgress: Double? = nil
    ) -> Double {
        guard let usedBytes = metric.usedBytes else { return usageProgress(for: metric) }
        let widthProgress = Double(usedBytes) / Double(diskTotalBytes)
        guard metric.kind == .swap else {
            return clampedProgress(widthProgress)
        }
        let visibleWidthProgress = max(widthProgress, storageSwapMinimumVisibleWidth)
        return clampedProgress(min(visibleWidthProgress, diskEndProgress ?? 1))
    }

    private static func storageStartProgress(
        for metric: DashboardMetric,
        widthProgress: Double,
        diskEndProgress: Double
    ) -> Double {
        guard metric.kind == .swap else { return 0 }
        return clampedProgress(diskEndProgress - widthProgress)
    }

    private static func clampedProgress(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }

    static let usageHeaderTitle: String? = nil

    static func trendReadoutUsesIntrinsicWidth(for kind: MetricKind) -> Bool {
        switch kind {
        case .temperature, .fan, .battery:
            return true
        default:
            return false
        }
    }

    static func overviewCardShowsTitleText(for kind: MetricKind) -> Bool {
        switch kind {
        case .memory, .network, .battery:
            return false
        default:
            return true
        }
    }

    static func compactTrendShowsReadout(
        for kind: MetricKind,
        isHovered: Bool
    ) -> Bool {
        switch kind {
        case .temperature, .fan:
            return !isHovered
        default:
            return true
        }
    }

    static func compactTrendTextChartSpacing(
        for kind: MetricKind,
        isHovered: Bool
    ) -> CGFloat {
        compactTrendShowsReadout(for: kind, isHovered: isHovered)
        ? compactTrendRestTextChartSpacing
        : 0
    }

    static func showsTrendYAxisLabels(
        for kind: MetricKind,
        isCompactOverviewChart: Bool
    ) -> Bool {
        if kind == .network || isCompactOverviewChart {
            return false
        }

        return true
    }

    static func compactTrendUsesDualFanReadout(for metric: DashboardMetric) -> Bool {
        metric.kind == .fan && metric.secondaryText != nil
    }

    static func compactTrendUsesTopFanReadout(for metric: DashboardMetric) -> Bool {
        compactTrendUsesDualFanReadout(for: metric)
    }

    static func compactTrendUsesTopReadout(for metric: DashboardMetric) -> Bool {
        metric.kind == .temperature || compactTrendUsesTopFanReadout(for: metric)
    }

    static func compactTrendShowsTopReadout(for metric: DashboardMetric, isHovered: Bool) -> Bool {
        compactTrendUsesTopReadout(for: metric)
        && compactTrendShowsReadout(for: metric.kind, isHovered: isHovered)
    }

    static func compactTrendReadoutTitle(for metric: DashboardMetric) -> String {
        if case .temperature(let source) = metric.titleRole {
            switch source {
            case .smc:
                return "CPU"
            case .battery:
                return AppLocalization.temperatureSourceTitle(for: .battery)
            }
        }

        return AppLocalization.dashboardMetricTitle(for: metric)
    }

    static func trendChartHeight(for metric: DashboardMetric, isHovered: Bool = false) -> CGFloat {
        compactTrendUsesTopReadout(for: metric) && !isHovered
        ? compactFanTrendChartHeight
        : compactTrendChartHeight
    }

    static func fanReadoutValues(for metric: DashboardMetric) -> [String] {
        guard compactTrendUsesDualFanReadout(for: metric), let secondaryText = metric.secondaryText else {
            return [metric.value]
        }

        return [metric.value, secondaryText]
    }
}

enum DashboardFooterChrome {
    static let backgroundOpacity = ActiveCleanupChrome.backgroundOpacity
    static let preferencesSystemImage = "gearshape"
    static let quitSystemImage = "power"
}

enum DashboardOverviewChrome {
    static let usageFillOpacity = 0.82
    static let valueStripOpacity = 0.14
    static let inactiveEmphasisFill = ActiveCleanupChrome.inactiveProgressFill
    static let inactiveChartPrimaryStroke = Color.black.opacity(0.56)
    static let inactiveChartSecondaryStroke = Color.black.opacity(0.42)
    static let inactiveChartAreaTop = Color.black.opacity(0.14)
    static let inactiveChartAreaBottom = Color.black.opacity(0.04)
    static let inactiveChartEmptyStroke = Color.black.opacity(0.34)
    static let inactiveMemorySegmentFill = Color.black.opacity(0.38)

    static func emphasisFillColor(
        baseColor: Color,
        opacity: Double,
        appearsActive: Bool
    ) -> Color {
        appearsActive ? baseColor.opacity(opacity) : inactiveEmphasisFill
    }

    static func chartSecondaryStrokeColor(
        baseColor: Color,
        appearsActive: Bool
    ) -> Color {
        appearsActive ? baseColor.opacity(0.9) : inactiveChartSecondaryStroke
    }

    static func chartAreaGradient(
        baseColor: Color,
        appearsActive: Bool
    ) -> LinearGradient {
        let colors = appearsActive
            ? [
                baseColor.opacity(0.16),
                baseColor.opacity(0.02)
            ]
            : [
                inactiveChartAreaTop,
                inactiveChartAreaBottom
            ]
        return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
    }

    static func chartPrimaryLineGradient(
        baseColor: Color,
        appearsActive: Bool
    ) -> LinearGradient {
        let colors = appearsActive
            ? [
                baseColor.opacity(0.92),
                baseColor.opacity(0.62)
            ]
            : [
                inactiveChartPrimaryStroke,
                inactiveChartSecondaryStroke
            ]
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    static func chartSelectionPointColor(
        baseColor: Color,
        appearsActive: Bool
    ) -> Color {
        appearsActive ? baseColor : inactiveChartPrimaryStroke
    }

    static func chartEmptyStrokeColor(
        baseColor: Color,
        appearsActive: Bool
    ) -> Color {
        appearsActive ? baseColor.opacity(0.35) : inactiveChartEmptyStroke
    }

    static func memorySegmentColor(
        for kind: RAMSegmentBarComponent.Kind,
        appearsActive: Bool
    ) -> Color {
        guard appearsActive else {
            switch kind {
            case .active:
                return inactiveMemorySegmentFill
            case .compressed:
                return Color.black.opacity(0.33)
            case .wired:
                return Color.black.opacity(0.28)
            case .other:
                return Color.black.opacity(0.24)
            }
        }

        switch kind {
        case .active:
            return Color.blue.opacity(0.88)
        case .compressed:
            return Color.purple.opacity(0.82)
        case .wired:
            return Color.teal.opacity(0.82)
        case .other:
            return Color.indigo.opacity(0.68)
        }
    }
}

enum DashboardTab: CaseIterable, Identifiable {
    case overview
    case actives
    case energyImpact

    var id: Self { self }

    var title: String {
        switch self {
        case .overview:
            return AppLocalization.string(.dashboardTabOverview)
        case .actives:
            return AppLocalization.string(.dashboardTabActives)
        case .energyImpact:
            return AppLocalization.string(.dashboardTabEnergyImpact)
        }
    }
}

struct DashboardView: View {
    @ObservedObject var dashboardModel: DashboardModel
    @ObservedObject private var localizationController = AppLocalizationController.shared
    @ObservedObject var preferencesController: PreferencesController
    @StateObject private var activeCleanupModel = ActiveCleanupModel()
    @StateObject private var energyImpactModel = EnergyImpactModel()
    @State private var selectedTab: DashboardTab = .overview
    @State private var activesRefreshTrigger = 0
    @State private var energyImpactRefreshTrigger = 0
    let openPreferences: () -> Void
    let quitApplication: () -> Void
    let onPreferredContentSizeChange: (DashboardTab, [DashboardMetric]) -> Void

    init(
        dashboardModel: DashboardModel,
        preferencesController: PreferencesController,
        openPreferences: @escaping () -> Void,
        quitApplication: @escaping () -> Void,
        initialSelectedTab: DashboardTab = .overview,
        onPreferredContentSizeChange: @escaping (DashboardTab, [DashboardMetric]) -> Void = { _, _ in }
    ) {
        self.dashboardModel = dashboardModel
        self.preferencesController = preferencesController
        self.openPreferences = openPreferences
        self.quitApplication = quitApplication
        self.onPreferredContentSizeChange = onPreferredContentSizeChange
        self._selectedTab = State(initialValue: initialSelectedTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DashboardHeaderChrome.horizontalPadding)
                .padding(.top, DashboardHeaderChrome.topPadding)
                .padding(.bottom, DashboardHeaderChrome.bottomPadding)

            Divider()

            ScrollView {
                switch selectedTab {
                case .overview:
                    overviewContent
                case .actives:
                    activesContent
                case .energyImpact:
                    energyImpactContent
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button(action: openPreferences) {
                    Label(
                        AppLocalization.string(.preferences),
                        systemImage: DashboardFooterChrome.preferencesSystemImage
                    )
                }
                Spacer(minLength: 12)
                Button(action: quitApplication) {
                    Label(
                        AppLocalization.string(.quit),
                        systemImage: DashboardFooterChrome.quitSystemImage
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(.quaternary.opacity(DashboardFooterChrome.backgroundOpacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            applyDiskCleanupCategories(preferencesController.state.diskCleanupCategories, refreshActives: false)
            reportPreferredContentSize()
        }
        .onChange(of: preferencesController.state.diskCleanupCategories) { newCategories in
            applyDiskCleanupCategories(newCategories, refreshActives: true)
        }
        .onChange(of: dashboardModel.metrics) { _ in
            reportPreferredContentSize()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DashboardHeaderChrome.titlePickerSpacing) {
            Text(AppLocalization.string(.appName))
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: DashboardHeaderChrome.titlePickerSpacing)

            tabPicker
                .frame(minWidth: DashboardHeaderChrome.tabPickerMinWidth, alignment: .trailing)
        }
    }

    private var tabPicker: some View {
        Picker(AppLocalization.string(.dashboardSection), selection: selectedTabBinding) {
            ForEach(DashboardTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var overviewContent: some View {
        OverviewDashboardContent(metrics: dashboardModel.metrics)
            .padding(18)
    }

    private var activesContent: some View {
        ActiveCleanReleaseView(
            model: activeCleanupModel,
            refreshTrigger: activesRefreshTrigger,
            usedMemoryBytes: Self.currentUsedMemoryBytes(in: dashboardModel.metrics) ?? 0,
            showsApplicationIdentifier: preferencesController.state.showsProcessApplicationIdentifier
        )
            .padding(18)
    }

    private var energyImpactContent: some View {
        EnergyImpactView(
            model: energyImpactModel,
            refreshTrigger: energyImpactRefreshTrigger,
            showsApplicationIdentifier: preferencesController.state.showsProcessApplicationIdentifier
        )
        .padding(18)
    }

    private var selectedTabBinding: Binding<DashboardTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                selectedTab = newValue
                activesRefreshTrigger = Self.activesRefreshTrigger(
                    afterSelecting: newValue,
                    currentTrigger: activesRefreshTrigger
                )
                energyImpactRefreshTrigger = Self.energyImpactRefreshTrigger(
                    afterSelecting: newValue,
                    currentTrigger: energyImpactRefreshTrigger
                )
                reportPreferredContentSize(for: newValue)
            }
        )
    }

    static func activesRefreshTrigger(afterSelecting selectedTab: DashboardTab, currentTrigger: Int) -> Int {
        selectedTab == .actives ? currentTrigger + 1 : currentTrigger
    }

    static func energyImpactRefreshTrigger(afterSelecting selectedTab: DashboardTab, currentTrigger: Int) -> Int {
        selectedTab == .energyImpact ? currentTrigger + 1 : currentTrigger
    }

    static func currentUsedMemoryBytes(in metrics: [DashboardMetric]) -> UInt64? {
        metrics.first { $0.kind == .memory }?.memoryTrend?.samples.last?.usedBytes
    }

    private func applyDiskCleanupCategories(_ categories: [DiskCleanupCategoryKind], refreshActives: Bool) {
        activeCleanupModel.setDiskCleanupCategories(categories)
        if refreshActives && selectedTab == .actives {
            activesRefreshTrigger += 1
        }
    }

    private func reportPreferredContentSize(for tab: DashboardTab? = nil) {
        onPreferredContentSizeChange(tab ?? selectedTab, dashboardModel.metrics)
    }
}

private struct OverviewDashboardContent: View {
    let metrics: [DashboardMetric]

    private var metricsByKind: [MetricKind: DashboardMetric] {
        DashboardOverviewLayout.metricsByKind(metrics)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: DashboardOverviewLayout.sectionSpacing) {
            if metrics.isEmpty {
                emptyState
            } else {
                topRegion
                secondRegion
                batteryRegion
            }
        }
    }

    private var hasSecondRegion: Bool {
        metricsByKind[.network] != nil || metricsByKind[.temperature] != nil || metricsByKind[.fan] != nil
    }

    private var hasTopRegion: Bool {
        DashboardOverviewLayout.hasUsageMetric(in: metricsByKind) || metricsByKind[.memory] != nil
    }

    private var computeUsageMetrics: [DashboardMetric] {
        DashboardOverviewLayout.computeUsageMetricKinds(in: metricsByKind).compactMap { metricsByKind[$0] }
    }

    private var storageUsageMetrics: [DashboardMetric] {
        DashboardOverviewLayout.storageUsageMetricKinds(in: metricsByKind).compactMap { metricsByKind[$0] }
    }

    @ViewBuilder
    private var topRegion: some View {
        if hasTopRegion {
            LazyVGrid(columns: DashboardOverviewLayout.topRowColumns, spacing: DashboardOverviewLayout.sectionSpacing) {
                if !computeUsageMetrics.isEmpty || !storageUsageMetrics.isEmpty {
                    VStack(spacing: DashboardOverviewLayout.sectionSpacing) {
                        if !computeUsageMetrics.isEmpty {
                            ResourceUsageCard(metrics: computeUsageMetrics)
                                .frame(
                                    height: storageUsageMetrics.isEmpty
                                        ? DashboardOverviewLayout.topRowHeight
                                        : DashboardOverviewLayout.topSplitCardHeight
                                )
                        }
                        if !storageUsageMetrics.isEmpty {
                            StorageUsageCard(metrics: storageUsageMetrics)
                                .frame(
                                    height: computeUsageMetrics.isEmpty
                                        ? DashboardOverviewLayout.topRowHeight
                                        : DashboardOverviewLayout.topSplitCardHeight
                                )
                        }
                    }
                    .frame(height: DashboardOverviewLayout.topRowHeight, alignment: .top)
                }
                if let memory = metricsByKind[.memory] {
                    MetricCard(metric: memory)
                        .frame(height: DashboardOverviewLayout.topRowHeight)
                }
            }
            .frame(height: DashboardOverviewLayout.topRowHeight)
        }
    }

    @ViewBuilder
    private var secondRegion: some View {
        if hasSecondRegion {
            LazyVGrid(columns: DashboardOverviewLayout.secondRowColumns, spacing: DashboardOverviewLayout.sectionSpacing) {
                if let network = metricsByKind[.network] {
                    MetricCard(metric: network)
                        .frame(height: DashboardOverviewLayout.secondRowHeight)
                }
                if metricsByKind[.temperature] != nil || metricsByKind[.fan] != nil {
                    VStack(spacing: DashboardOverviewLayout.sectionSpacing) {
                        if let temperature = metricsByKind[.temperature] {
                            CompactTrendMetricCard(metric: temperature)
                                .frame(height: DashboardOverviewLayout.compactTrendCardHeight)
                        }
                        if let fan = metricsByKind[.fan] {
                            CompactTrendMetricCard(metric: fan)
                                .frame(height: DashboardOverviewLayout.compactTrendCardHeight)
                        }
                    }
                    .frame(height: DashboardOverviewLayout.secondRowHeight, alignment: .top)
                }
            }
            .frame(height: DashboardOverviewLayout.secondRowHeight)
        }
    }

    @ViewBuilder
    private var batteryRegion: some View {
        if let battery = metricsByKind[.battery] {
            SlimTrendMetricCard(metric: battery)
                .frame(height: DashboardOverviewLayout.batteryRowHeight)
        }
    }

    private var emptyState: some View {
        Text(AppLocalization.string(.dashboardWaitingFirstMetricSample))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(18)
            .dashboardCardChrome()
    }
}

struct RAMSegmentBarsLayout {
    private static let bucketDuration: TimeInterval = 60

    static func displaySampleBudget(for containerSize: CGSize) -> Int {
        guard containerSize.width > 0 else { return 1 }
        return min(96, max(12, Int((containerSize.width / 5).rounded())))
    }

    static func displaySlots(
        for samples: [DashboardMemoryTrendSample],
        containerSize: CGSize,
        referenceDate: Date
    ) -> [RAMSegmentBarSlot] {
        let slotCount = displaySampleBudget(for: containerSize)
        let visibleSamples = samples
            .filter { $0.timestamp <= referenceDate }
            .sorted { $0.timestamp < $1.timestamp }
        let latestBucketStart = bucketStart(containing: referenceDate)

        guard let oldestSample = visibleSamples.first else {
            return placeholderSlots(for: [latestBucketStart], slotCount: slotCount)
        }

        let bucketStarts = bucketStarts(
            from: bucketStart(containing: oldestSample.timestamp),
            through: latestBucketStart
        )
        let samplesByBucket = groupedSamplesByBucket(visibleSamples)
        let averagedSamplesByBucket = Dictionary(
            uniqueKeysWithValues: samplesByBucket.compactMap { bucketStart, samples -> (Date, DashboardMemoryTrendSample)? in
                guard let sample = averagedSample(samples, bucketStart: bucketStart) else {
                    return nil
                }

                return (bucketStart, sample)
            }
        )
        let latestSample = samplesByBucket[latestBucketStart]?.max { $0.timestamp < $1.timestamp }

        let placeholderSlots = placeholderSlots(for: bucketStarts, slotCount: slotCount)
        let sampledSlots = bucketStarts.compactMap { bucketStart -> RAMSegmentBarSlot? in
            if bucketStart == latestBucketStart {
                guard let latestSample else { return nil }
                return RAMSegmentBarSlot(
                    bucketStart: latestBucketStart,
                    sample: latestSample,
                    valueSemantics: .latestSample
                )
            }

            guard let sample = averagedSamplesByBucket[bucketStart] else { return nil }
            return RAMSegmentBarSlot(bucketStart: bucketStart, sample: sample)
        }

        guard !sampledSlots.isEmpty else { return placeholderSlots }

        let compactedSlots = compactedSampleSlots(sampledSlots, slotCount: slotCount)
        let leadingPlaceholderCount = max(0, slotCount - compactedSlots.count)
        return Array(placeholderSlots.prefix(leadingPlaceholderCount)) + compactedSlots
    }

    static func tooltipTimeLabel(for slot: RAMSegmentBarSlot) -> String {
        switch slot.valueSemantics {
        case .latestSample:
            guard let timestamp = slot.sample?.timestamp else {
                return bucketEndLabel(startingAt: slot.bucketStart)
            }
            return AppLocalization.formattedTime(timestamp, includesSeconds: true)
        case .minuteAverage:
            return bucketEndLabel(startingAt: slot.bucketStart)
        }
    }

    static func accessibilityLabel(for sample: DashboardMemoryTrendSample?) -> String {
        guard let sample else {
            return AppLocalization.string(.memoryChartCollectingSamples)
        }

        return AppLocalization.memoryChartAccessibilityLabel(
            pressurePercent: Int(sample.pressurePercent.rounded()),
            usedMemory: DashboardMetricTextFormatter.formatMemoryGB(sample.usedBytes),
            totalMemory: DashboardMetricTextFormatter.formatMemoryGB(sample.totalBytes)
        )
    }

    private static func bucketEndLabel(startingAt bucketStart: Date) -> String {
        let bucketEnd = bucketStart.addingTimeInterval(bucketDuration)
        return AppLocalization.formattedTime(bucketEnd)
    }

    private static func bucketStart(containing date: Date) -> Date {
        let bucketInterval = floor(date.timeIntervalSinceReferenceDate / bucketDuration) * bucketDuration
        return Date(timeIntervalSinceReferenceDate: bucketInterval)
    }

    private static func bucketStarts(from start: Date, through end: Date) -> [Date] {
        let bucketCount = max(1, Int(end.timeIntervalSince(start) / bucketDuration) + 1)
        return (0..<bucketCount).map { index in
            start.addingTimeInterval(TimeInterval(index) * bucketDuration)
        }
    }

    private static func placeholderSlots(for bucketStarts: [Date], slotCount: Int) -> [RAMSegmentBarSlot] {
        guard !bucketStarts.isEmpty else { return [] }
        return (0..<slotCount).map { slotIndex in
            let bucketIndex = bucketIndex(
                forSlotIndex: slotIndex,
                slotCount: slotCount,
                bucketCount: bucketStarts.count
            )
            return RAMSegmentBarSlot(bucketStart: bucketStarts[bucketIndex], sample: nil)
        }
    }

    private static func groupedSamplesByBucket(
        _ samples: [DashboardMemoryTrendSample]
    ) -> [Date: [DashboardMemoryTrendSample]] {
        var samplesByBucket: [Date: [DashboardMemoryTrendSample]] = [:]
        for sample in samples {
            samplesByBucket[bucketStart(containing: sample.timestamp), default: []].append(sample)
        }

        return samplesByBucket
    }

    private static func bucketIndex(forSlotIndex slotIndex: Int, slotCount: Int, bucketCount: Int) -> Int {
        guard bucketCount > 1 else { return 0 }
        guard slotCount > 1 else { return bucketCount - 1 }
        return min(bucketCount - 1, slotIndex * bucketCount / slotCount)
    }

    static func compactedSampleSlots(
        _ slots: [RAMSegmentBarSlot],
        slotCount: Int
    ) -> [RAMSegmentBarSlot] {
        guard slots.count > slotCount else { return slots }

        return (0..<slotCount).compactMap { slotIndex in
            let startIndex = slotIndex * slots.count / slotCount
            let endIndex = min(slots.count, (slotIndex + 1) * slots.count / slotCount)
            let bucketSlots = Array(slots[startIndex..<endIndex])

            if slotIndex == slotCount - 1,
               bucketSlots.last?.valueSemantics == .latestSample {
                return bucketSlots.last
            }

            guard let bucketStart = bucketSlots.first?.bucketStart,
                  let sample = averagedSample(bucketSlots.compactMap(\.sample), bucketStart: bucketStart) else {
                return nil
            }

            return RAMSegmentBarSlot(bucketStart: bucketStart, sample: sample)
        }
    }

    private static func averagedSample(
        _ samples: [DashboardMemoryTrendSample],
        bucketStart: Date
    ) -> DashboardMemoryTrendSample? {
        guard !samples.isEmpty else { return nil }

        let usedBytes = averageBytes(samples, \.usedBytes)
        let totalBytes = averageBytes(samples, \.totalBytes)
        let pressurePercent = totalBytes > 0
            ? Double(usedBytes) / Double(totalBytes) * 100
            : averagePressurePercent(samples)

        return DashboardMemoryTrendSample(
            timestamp: bucketStart,
            pressurePercent: min(max(pressurePercent, 0), 100),
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            breakdown: MemoryBreakdown(
                wiredBytes: averageBreakdownBytes(samples, \.wiredBytes),
                activeBytes: averageBreakdownBytes(samples, \.activeBytes),
                compressedBytes: averageBreakdownBytes(samples, \.compressedBytes),
                cachedBytes: averageBreakdownBytes(samples, \.cachedBytes),
                availableBytes: averageBreakdownBytes(samples, \.availableBytes)
            )
        )
    }

    private static func averageBytes(
        _ samples: [DashboardMemoryTrendSample],
        _ keyPath: KeyPath<DashboardMemoryTrendSample, UInt64>
    ) -> UInt64 {
        UInt64((Double(samples.reduce(UInt64(0)) { $0 + $1[keyPath: keyPath] }) / Double(samples.count)).rounded())
    }

    private static func averageBreakdownBytes(
        _ samples: [DashboardMemoryTrendSample],
        _ keyPath: KeyPath<MemoryBreakdown, UInt64>
    ) -> UInt64 {
        UInt64((Double(samples.reduce(UInt64(0)) { $0 + $1.breakdown[keyPath: keyPath] }) / Double(samples.count)).rounded())
    }

    private static func averagePressurePercent(_ samples: [DashboardMemoryTrendSample]) -> Double {
        samples.reduce(0) { $0 + $1.pressurePercent } / Double(samples.count)
    }

    static func displaySegments(for sample: DashboardMemoryTrendSample) -> [RAMSegmentBarComponent] {
        let usedBytes = min(sample.usedBytes, sample.totalBytes)
        guard usedBytes > 0 else { return [] }

        let rawSegments = [
            RAMSegmentBarComponent(kind: .active, bytes: sample.breakdown.activeBytes),
            RAMSegmentBarComponent(kind: .compressed, bytes: sample.breakdown.compressedBytes),
            RAMSegmentBarComponent(kind: .wired, bytes: sample.breakdown.wiredBytes)
        ].filter { $0.bytes > 0 }

        let rawTotal = rawSegments.reduce(UInt64(0)) { $0 + $1.bytes }
        guard rawTotal > 0 else {
            return [RAMSegmentBarComponent(kind: .active, bytes: usedBytes)]
        }

        let scaledSegments: [RAMSegmentBarComponent]
        if rawTotal > usedBytes {
            let scale = Double(usedBytes) / Double(rawTotal)
            scaledSegments = rawSegments.compactMap { segment in
                let scaledBytes = UInt64((Double(segment.bytes) * scale).rounded())
                guard scaledBytes > 0 else { return nil }
                return RAMSegmentBarComponent(kind: segment.kind, bytes: scaledBytes)
            }
        } else {
            scaledSegments = rawSegments
        }

        let scaledTotal = scaledSegments.reduce(UInt64(0)) { $0 + $1.bytes }
        if scaledTotal > usedBytes {
            return cappedSegments(scaledSegments, to: usedBytes)
        }

        guard scaledTotal < usedBytes else { return scaledSegments }

        return scaledSegments + [RAMSegmentBarComponent(kind: .other, bytes: usedBytes - scaledTotal)]
    }

    static func percentage(for segment: RAMSegmentBarComponent, in sample: DashboardMemoryTrendSample) -> Double {
        guard sample.totalBytes > 0 else { return 0 }
        return Double(segment.bytes) / Double(sample.totalBytes) * 100
    }

    static func barWidth(slotCount: Int, containerWidth: CGFloat) -> CGFloat {
        guard slotCount > 0 else { return 0 }
        let spacing = spacing(slotCount: slotCount)
        let rawWidth = (containerWidth - CGFloat(max(0, slotCount - 1)) * spacing) / CGFloat(slotCount)
        return min(8, max(2, rawWidth))
    }

    static func spacing(slotCount: Int) -> CGFloat {
        slotCount > 32 ? 2 : 3
    }

    private static func cappedSegments(_ segments: [RAMSegmentBarComponent], to usedBytes: UInt64) -> [RAMSegmentBarComponent] {
        guard usedBytes > 0 else { return [] }
        var remainingBytes = usedBytes
        var capped: [RAMSegmentBarComponent] = []
        for segment in segments {
            guard remainingBytes > 0 else { break }
            let bytes = min(segment.bytes, remainingBytes)
            capped.append(RAMSegmentBarComponent(kind: segment.kind, bytes: bytes))
            remainingBytes -= bytes
        }
        return capped
    }
}

struct RAMSegmentBarSlot: Equatable, Sendable {
    enum ValueSemantics: Equatable, Sendable {
        case minuteAverage
        case latestSample
    }

    var bucketStart: Date
    var sample: DashboardMemoryTrendSample?
    var valueSemantics: ValueSemantics = .minuteAverage
}

struct RAMSegmentBarComponent: Equatable, Sendable, Identifiable {
    enum Kind: String, Equatable, Sendable {
        case active
        case compressed
        case wired
        case other

        var title: String {
            switch self {
            case .active:
                return "Active"
            case .compressed:
                return "Compressed"
            case .wired:
                return "Wired"
            case .other:
                return "Other"
            }
        }
    }

    var kind: Kind
    var bytes: UInt64

    var id: Kind { kind }
}

struct RAMSegmentBars: View {
    let trend: DashboardMemoryTrend
    @State private var hoveredSlotIndex: Int?

    init(trend: DashboardMemoryTrend, hoveredSlotIndex: Int? = nil) {
        self.trend = trend
        self._hoveredSlotIndex = State(initialValue: hoveredSlotIndex)
    }

    var body: some View {
        GeometryReader { proxy in
            let referenceDate = Date.now
            let slots = RAMSegmentBarsLayout.displaySlots(
                for: trend.samples,
                containerSize: proxy.size,
                referenceDate: referenceDate
            )
            let barWidth = RAMSegmentBarsLayout.barWidth(slotCount: slots.count, containerWidth: proxy.size.width)
            let spacing = RAMSegmentBarsLayout.spacing(slotCount: slots.count)
            let hoveredSlot = hoveredSlotIndex.flatMap { index in
                slots.indices.contains(index) ? slots[index] : nil
            }

            ZStack(alignment: .topLeading) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                        RAMSegmentBar(sample: slot.sample)
                            .frame(width: barWidth, height: proxy.size.height)
                            .onHover { isHovering in
                                if isHovering, slot.sample != nil {
                                    hoveredSlotIndex = index
                                } else if hoveredSlotIndex == index {
                                    hoveredSlotIndex = nil
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .animation(DashboardMotion.valueAnimation, value: slots)

                if let hoveredSlot, hoveredSlot.sample != nil, let hoveredSlotIndex {
                    RAMSegmentTooltip(slot: hoveredSlot)
                        .fixedSize()
                        .position(tooltipPosition(
                            slotIndex: hoveredSlotIndex,
                            slotCount: slots.count,
                            barWidth: barWidth,
                            spacing: spacing,
                            containerSize: proxy.size
                        ))
                        .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RAMSegmentBarsLayout.accessibilityLabel(for: slots.compactMap(\.sample).last))
        }
    }

    private func tooltipPosition(
        slotIndex: Int,
        slotCount: Int,
        barWidth: CGFloat,
        spacing: CGFloat,
        containerSize: CGSize
    ) -> CGPoint {
        let totalWidth = CGFloat(slotCount) * barWidth + CGFloat(max(0, slotCount - 1)) * spacing
        let startX = max(0, (containerSize.width - totalWidth) / 2)
        let rawX = startX + CGFloat(slotIndex) * (barWidth + spacing) + barWidth / 2
        return CGPoint(
            x: min(max(rawX, 78), max(78, containerSize.width - 78)),
            y: 20
        )
    }

}

private struct RAMSegmentBar: View {
    @Environment(\.appearsActive) private var appearsActive
    let sample: DashboardMemoryTrendSample?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.primary.opacity(0.08))

                if let sample, sample.usedBytes > 0, sample.totalBytes > 0 {
                    let segments = RAMSegmentBarsLayout.displaySegments(for: sample)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ForEach(Array(segments.reversed())) { segment in
                            Rectangle()
                                .fill(
                                    DashboardOverviewChrome.memorySegmentColor(
                                        for: segment.kind,
                                        appearsActive: appearsActive
                                    )
                                )
                                .frame(height: barHeight(for: segment, sample: sample, containerHeight: proxy.size.height))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
            .animation(DashboardMotion.valueAnimation, value: sample)
        }
    }

    private func barHeight(for segment: RAMSegmentBarComponent, sample: DashboardMemoryTrendSample, containerHeight: CGFloat) -> CGFloat {
        let ratio = min(max(CGFloat(Double(segment.bytes) / Double(sample.totalBytes)), 0), 1)
        return max(1, ratio * containerHeight)
    }
}

private struct RAMSegmentLegend: View {
    @Environment(\.appearsActive) private var appearsActive
    let sample: DashboardMemoryTrendSample

    var body: some View {
        let segments = RAMSegmentBarsLayout.displaySegments(for: sample)
        HStack(spacing: 8) {
            ForEach(segments) { segment in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            DashboardOverviewChrome.memorySegmentColor(
                                for: segment.kind,
                                appearsActive: appearsActive
                            )
                        )
                        .frame(width: 7, height: 7)
                    Text(DashboardMetricTextFormatter.formatPercent(RAMSegmentBarsLayout.percentage(for: segment, in: sample)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RAMSegmentTooltip: View {
    @Environment(\.appearsActive) private var appearsActive
    let slot: RAMSegmentBarSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RAMSegmentBarsLayout.tooltipTimeLabel(for: slot))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let sample = slot.sample {
                ForEach(RAMSegmentBarsLayout.displaySegments(for: sample)) { segment in
                    HStack(spacing: 5) {
                        let title = AppLocalization.memorySegmentTitle(for: segment.kind)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(
                                DashboardOverviewChrome.memorySegmentColor(
                                    for: segment.kind,
                                    appearsActive: appearsActive
                                )
                            )
                            .frame(width: 8, height: 8)
                        Text(
                            AppLocalization.memorySegmentTooltip(
                                title: title,
                                memory: DashboardMetricTextFormatter.formatMemoryGB(segment.bytes),
                                percent: DashboardMetricTextFormatter.formatPercent(
                                    RAMSegmentBarsLayout.percentage(for: segment, in: sample)
                                )
                            )
                        )
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(radius: 4, y: 2)
    }
}

enum DashboardMetricColor {
    static func color(for kind: MetricKind) -> Color {
        switch kind {
        case .cpu:
            return .orange
        case .gpu:
            return .purple
        case .disk:
            return .mint
        case .swap:
            return .orange
        case .memory:
            return .blue
        case .vram:
            return .cyan
        case .network:
            return .teal
        case .battery:
            return .green
        case .temperature:
            return .red
        case .fan:
            return .indigo
        }
    }
}

private struct ResourceUsageCard: View {
    let metrics: [DashboardMetric]
    @State private var isCardHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = DashboardOverviewLayout.usageHeaderTitle {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(metrics) { metric in
                UsageBarRow(metric: metric, color: DashboardMetricColor.color(for: metric.kind))
            }
        }
        .frame(
            maxWidth: DashboardOverviewLayout.usageContentMaxWidth,
            alignment: .leading
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(DashboardCardLayout.regularCardInsets)
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardOverviewLayout.topSplitCardHeight,
            maxHeight: DashboardCardLayout.cardChromeMaxHeight,
            alignment: DashboardOverviewLayout.usageCardContentAlignment
        )
        .dashboardCardChrome(isHovered: isCardHovered)
        .onHover { hovering in
            isCardHovered = hovering
        }
    }
}

private struct StorageUsageCard: View {
    let metrics: [DashboardMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardOverviewLayout.storageContentSpacing) {
            ForEach(DashboardOverviewLayout.storageCardContentOrder, id: \.self) { content in
                storageContent(content)
            }
        }
        .frame(maxWidth: DashboardOverviewLayout.storageContentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(DashboardCardLayout.regularCardInsets)
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardOverviewLayout.topSplitCardHeight,
            maxHeight: DashboardCardLayout.cardChromeMaxHeight,
            alignment: .center
        )
        .dashboardCardChrome()
    }

    @ViewBuilder
    private func storageContent(_ content: DashboardStorageCardContent) -> some View {
        switch content {
        case .details:
            storageDetails
        case .bar:
            storageBar
        }
    }

    private var storageDetails: some View {
        StorageUsageDetails(metrics: metrics)
            .frame(height: DashboardOverviewLayout.storageDetailHeight(for: metrics))
            .animation(DashboardMotion.valueAnimation, value: DashboardOverviewLayout.storageUsageLabels(for: metrics))
    }

    private var storageBar: some View {
        StorageSegmentedUsageBar(metrics: metrics)
            .frame(height: DashboardOverviewLayout.storageBarHeight)
    }
}

private struct StorageSegmentedUsageBar: View {
    @Environment(\.appearsActive) private var appearsActive
    let metrics: [DashboardMetric]

    var body: some View {
        GeometryReader { proxy in
            let segments = DashboardOverviewLayout.storageUsageSegments(for: metrics)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))

                ForEach(segments) { segment in
                    Rectangle()
                        .fill(
                            DashboardOverviewChrome.emphasisFillColor(
                                baseColor: DashboardMetricColor.color(for: segment.kind),
                                opacity: DashboardOverviewChrome.usageFillOpacity,
                                appearsActive: appearsActive
                            )
                        )
                        .frame(width: proxy.size.width * segment.widthProgress)
                        .offset(x: proxy.size.width * segment.startProgress)
                        .transition(.opacity)
                }
            }
            .clipShape(Capsule())
        }
        .accessibilityLabel(Text(AppLocalization.string(.dashboardStorageAccessibility)))
        .accessibilityValue(Text(AppLocalization.storageAccessibilityValue(for: visibleMetrics)))
        .animation(DashboardMotion.valueAnimation, value: metrics)
    }

    private var visibleMetrics: [DashboardMetric] {
        DashboardOverviewLayout.visibleStorageUsageMetrics(in: metrics)
    }
}

private struct StorageUsageDetails: View {
    let metrics: [DashboardMetric]

    var body: some View {
        GeometryReader { proxy in
            let labels = DashboardOverviewLayout.storageUsageLabels(for: metrics)
            ZStack(alignment: .topLeading) {
                ForEach(labels) { label in
                    Rectangle()
                        .fill(Color.primary.opacity(DashboardOverviewLayout.storageDetailMarkerOpacity))
                        .frame(
                            width: DashboardOverviewLayout.storageDetailMarkerWidth,
                            height: DashboardOverviewLayout.storageConnectorHeight(for: label)
                        )
                        .offset(
                            x: DashboardOverviewLayout.storageDetailMarkerXPosition(
                                for: label,
                                containerWidth: proxy.size.width
                            ),
                            y: DashboardOverviewLayout.storageConnectorYPosition(for: label)
                        )
                        .transition(.opacity)
                }

                ForEach(labels) { label in
                    if let metric = metric(for: label) {
                        let xPosition = DashboardOverviewLayout.storageDetailRowXPosition(
                            for: label,
                            containerWidth: proxy.size.width
                        )
                        StorageUsageDetailRow(
                            metric: metric,
                            alignment: DashboardOverviewLayout.storageDetailRowAlignment(
                                for: label,
                                containerWidth: proxy.size.width
                            ),
                            textAlignment: DashboardOverviewLayout.storageDetailRowTextAlignment(
                                for: label,
                                containerWidth: proxy.size.width
                            )
                        )
                            .frame(
                                width: DashboardOverviewLayout.storageDetailRowWidth(
                                    for: label,
                                    containerWidth: proxy.size.width
                                ),
                                height: DashboardOverviewLayout.storageDetailRowHeight,
                                alignment: DashboardOverviewLayout.storageDetailRowAlignment(
                                    for: label,
                                    containerWidth: proxy.size.width
                                )
                            )
                            .offset(
                                x: xPosition,
                                y: CGFloat(label.rowIndex)
                                    * (DashboardOverviewLayout.storageDetailRowHeight + DashboardOverviewLayout.storageDetailRowSpacing)
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                    }
                }
            }
        }
        .animation(DashboardMotion.valueAnimation, value: DashboardOverviewLayout.storageUsageLabels(for: metrics))
    }

    private func metric(for label: DashboardStorageUsageLabel) -> DashboardMetric? {
        metrics.first { $0.kind == label.kind }
    }
}

private struct StorageUsageDetailRow: View {
    let metric: DashboardMetric
    let alignment: Alignment
    let textAlignment: TextAlignment

    var body: some View {
        HStack(spacing: DashboardOverviewLayout.storageDetailSpacing) {
            if alignment == .trailing {
                Text(AppLocalization.dashboardMetricTitle(for: metric))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(DashboardMetricColor.color(for: metric.kind))
                    .lineLimit(1)
                    .multilineTextAlignment(textAlignment)

                storageValueText

                if let iconName = DashboardOverviewLayout.storageDetailIconName(for: metric.kind) {
                    Image(systemName: iconName)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(DashboardMetricColor.color(for: metric.kind))
                        .accessibilityHidden(true)
                }
            } else {
                DashboardMetricTitleLabel(
                    metric: metric,
                    font: .caption2.monospacedDigit().weight(.semibold),
                    titleColor: DashboardMetricColor.color(for: metric.kind),
                    iconColor: DashboardMetricColor.color(for: metric.kind),
                    textAlignment: textAlignment
                )

                storageValueText
            }
        }
        .lineLimit(1)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: alignment
        )
    }

    private var storageValueText: some View {
        Text(DashboardOverviewLayout.storageDetailValue(for: metric))
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .multilineTextAlignment(textAlignment)
    }
}

private struct DashboardMetricTitleLabel: View {
    let metric: DashboardMetric
    let font: Font
    let titleColor: Color
    let iconColor: Color
    var spacing: CGFloat = DashboardOverviewLayout.metricTitleIconSpacing
    var textAlignment: TextAlignment = .leading
    var showsText = true

    var body: some View {
        HStack(spacing: spacing) {
            if let iconName = DashboardOverviewLayout.metricIconName(for: metric.kind) {
                Image(systemName: iconName)
                    .font(font)
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
            }

            if showsText {
                Text(AppLocalization.dashboardMetricTitle(for: metric))
                    .font(font)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .multilineTextAlignment(textAlignment)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AppLocalization.dashboardMetricTitle(for: metric)))
    }
}

private struct UsageBarRow: View {
    @Environment(\.appearsActive) private var appearsActive
    let metric: DashboardMetric
    let color: Color
    @State private var displayedProgress: Double?

    var body: some View {
        let targetProgress = DashboardOverviewLayout.usageProgress(for: metric)

        HStack(spacing: DashboardOverviewLayout.usageRowSpacing) {
            DashboardMetricTitleLabel(
                metric: metric,
                font: .caption.monospacedDigit().weight(.semibold),
                titleColor: .primary,
                iconColor: color
            )
            .frame(
                width: DashboardOverviewLayout.usageLabelColumnWidth,
                alignment: .center
            )

            GeometryReader { proxy in
                let progress = displayedProgress ?? targetProgress
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            DashboardOverviewChrome.emphasisFillColor(
                                baseColor: color,
                                opacity: DashboardOverviewChrome.usageFillOpacity,
                                appearsActive: appearsActive
                            )
                        )
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: DashboardOverviewLayout.usageBarHeight)

            Text(metric.value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(
                    width: DashboardOverviewLayout.usageValueColumnWidth,
                    alignment: .center
                )
        }
        .onAppear {
            displayedProgress = targetProgress
        }
        .onChange(of: targetProgress) { progress in
            withAnimation(DashboardMotion.valueAnimation) {
                displayedProgress = progress
            }
        }
    }
}

private struct CompactTrendMetricCard: View {
    let metric: DashboardMetric
    @State private var isCardHovered = false

    var body: some View {
        Group {
            if DashboardOverviewLayout.compactTrendUsesTopReadout(for: metric) {
                VStack(alignment: .leading, spacing: 2) {
                    if DashboardOverviewLayout.compactTrendShowsTopReadout(
                        for: metric,
                        isHovered: isCardHovered
                    ) {
                        if metric.kind == .fan {
                            CompactFanReadout(metric: metric)
                        } else {
                            CompactTemperatureReadout(metric: metric)
                        }
                    }
                    trendChart
                }
            } else {
                HStack(
                    alignment: .center,
                    spacing: DashboardOverviewLayout.compactTrendTextChartSpacing(
                        for: metric.kind,
                        isHovered: isCardHovered
                    )
                ) {
                    if DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: metric.kind)
                        && DashboardOverviewLayout.compactTrendShowsReadout(
                            for: metric.kind,
                            isHovered: isCardHovered
                        ) {
                        VStack(alignment: .leading, spacing: 3) {
                            DashboardMetricTitleLabel(
                                metric: metric,
                                font: .caption2.weight(.semibold),
                                titleColor: .secondary,
                                iconColor: DashboardMetricColor.color(for: metric.kind)
                            )
                            Text(metric.value)
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    trendChart
                }
            }
        }
        .padding(DashboardCardLayout.compactChartInsets)
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardOverviewLayout.compactTrendCardHeight,
            maxHeight: DashboardCardLayout.cardChromeMaxHeight,
            alignment: .leading
        )
        .dashboardCardChrome(isHovered: isCardHovered)
        .onHover { hovering in
            isCardHovered = hovering
        }
        .animation(DashboardMotion.hoverAnimation, value: isCardHovered)
    }

    private var trendChart: some View {
        DashboardTrendChart(
            metric: metric,
            color: DashboardMetricColor.color(for: metric.kind),
            isCardHovered: isCardHovered,
            showsYAxisLabels: DashboardOverviewLayout.showsTrendYAxisLabels(
                for: metric.kind,
                isCompactOverviewChart: true
            )
        )
        .id(metric.id)
        .frame(height: DashboardOverviewLayout.trendChartHeight(for: metric, isHovered: isCardHovered))
        .frame(maxWidth: .infinity)
    }
}

private struct CompactFanReadout: View {
    let metric: DashboardMetric

    private var color: Color {
        DashboardMetricColor.color(for: .fan)
    }

    var body: some View {
        HStack(spacing: DashboardOverviewLayout.metricTitleIconSpacing) {
            fanIcon
            fanText(metric.value)
            Spacer(minLength: 8)
            if let secondaryText = metric.secondaryText {
                fanText(secondaryText)
                fanIcon
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AppLocalization.dashboardMetricTitle(for: metric)))
        .accessibilityValue(Text(DashboardOverviewLayout.fanReadoutValues(for: metric).joined(separator: ", ")))
    }

    private var fanIcon: some View {
        Image(systemName: "fanblades")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    private func fanText(_ value: String) -> some View {
        Text(value)
            .font(.caption.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }
}

private struct CompactTemperatureReadout: View {
    let metric: DashboardMetric

    private var color: Color {
        DashboardMetricColor.color(for: .temperature)
    }

    var body: some View {
        HStack(spacing: DashboardOverviewLayout.metricTitleIconSpacing) {
            Image(systemName: "thermometer")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(DashboardOverviewLayout.compactTrendReadoutTitle(for: metric))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(metric.value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(AppLocalization.dashboardMetricTitle(for: metric)))
        .accessibilityValue(Text(metric.value))
    }
}

private struct SlimTrendMetricCard: View {
    let metric: DashboardMetric
    @State private var isCardHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: DashboardOverviewLayout.compactTrendRestTextChartSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                DashboardMetricTitleLabel(
                    metric: metric,
                    font: .caption2.weight(.semibold),
                    titleColor: .secondary,
                    iconColor: DashboardMetricColor.color(for: metric.kind),
                    showsText: DashboardOverviewLayout.overviewCardShowsTitleText(for: metric.kind)
                )
                Text(metric.value)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .fixedSize(horizontal: true, vertical: false)

            DashboardTrendChart(
                metric: metric,
                color: DashboardMetricColor.color(for: metric.kind),
                isCardHovered: isCardHovered,
                showsYAxisLabels: DashboardOverviewLayout.showsTrendYAxisLabels(
                    for: metric.kind,
                    isCompactOverviewChart: false
                )
            )
            .id(metric.id)
            .frame(height: DashboardCardLayout.compactChartHeight)
            .frame(maxWidth: .infinity)
        }
        .padding(DashboardCardLayout.compactChartInsets)
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardOverviewLayout.slimTrendCardHeight,
            maxHeight: DashboardCardLayout.cardChromeMaxHeight,
            alignment: .leading
        )
        .dashboardCardChrome(isHovered: isCardHovered)
        .onHover { hovering in
            isCardHovered = hovering
        }
    }
}

private struct MetricCard: View {
    @Environment(\.appearsActive) private var appearsActive
    let metric: DashboardMetric
    @State private var isCardHovered = false

    private var isCompactChartCard: Bool {
        metric.style == .chart || metric.style == .memoryStackedChart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompactChartCard ? 6 : 10) {
            HStack(alignment: .top) {
                DashboardMetricTitleLabel(
                    metric: metric,
                    font: isCompactChartCard ? .caption2.weight(.semibold) : .caption.weight(.semibold),
                    titleColor: .secondary,
                    iconColor: color,
                    showsText: DashboardOverviewLayout.overviewCardShowsTitleText(for: metric.kind)
                )
                Spacer(minLength: 8)
                trailingValueView
            }

            switch metric.style {
            case .chart:
                trendChart
            case .memoryStackedChart:
                if let memoryTrend = metric.memoryTrend, !memoryTrend.samples.isEmpty {
                    RAMSegmentBars(trend: memoryTrend)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                    if let latestSample = memoryTrend.samples.last {
                        RAMSegmentLegend(sample: latestSample)
                    }
                } else {
                    trendChart
                }
            case .value:
                Rectangle()
                    .fill(
                        DashboardOverviewChrome.emphasisFillColor(
                            baseColor: color,
                            opacity: DashboardOverviewChrome.valueStripOpacity,
                            appearsActive: appearsActive
                        )
                    )
                    .frame(height: 4)
                    .clipShape(Capsule())
            }

            if let detail = AppLocalization.dashboardMetricDetail(for: metric), !isCompactChartCard {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(isCompactChartCard ? DashboardCardLayout.compactChartInsets : DashboardCardLayout.regularCardInsets)
        .frame(
            maxWidth: .infinity,
            minHeight: isCompactChartCard ? DashboardCardLayout.compactChartMinHeight : 44,
            maxHeight: DashboardCardLayout.cardChromeMaxHeight,
            alignment: .topLeading
        )
        .dashboardCardChrome(isHovered: isCardHovered)
        .onHover { hovering in
            isCardHovered = hovering
        }
    }

    private var color: Color {
        DashboardMetricColor.color(for: metric.kind)
    }

    @ViewBuilder
    private var trendChart: some View {
        let chart = DashboardTrendChart(
            metric: metric,
            color: color,
            isCardHovered: isCardHovered,
            showsYAxisLabels: DashboardOverviewLayout.showsTrendYAxisLabels(
                for: metric.kind,
                isCompactOverviewChart: false
            )
        )
        .id(metric.id)

        switch DashboardCardLayout.chartHeightBehavior(for: metric.kind) {
        case .fixed(let height):
            chart.frame(height: height)
        case .fillsRemainingHeight:
            chart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var trailingValueView: some View {
        if isCompactChartCard, let secondaryText = metric.secondaryText {
            VStack(alignment: .trailing, spacing: 1) {
                Text(metric.value)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(secondaryText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .multilineTextAlignment(.trailing)
        } else {
            Text(metric.value)
                .font(
                    isCompactChartCard
                    ? .subheadline.monospacedDigit().weight(.semibold)
                    : .title3.monospacedDigit().weight(.semibold)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
