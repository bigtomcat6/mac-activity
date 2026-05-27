import SwiftUI
import MacActivityCore

enum DashboardCardLayout {
    static let compactChartHeight: CGFloat = 60
    static let compactChartMinHeight: CGFloat = 116
    static let compactChartInsets = EdgeInsets(top: 8, leading: 8, bottom: 6, trailing: 8)
    static let regularCardInsets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)

    static func usesCompactHoverLayout(for chartHeight: CGFloat) -> Bool {
        chartHeight <= 64
    }
}

private enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case actives = "Actives"

    var id: String { rawValue }
}

struct DashboardView: View {
    @ObservedObject var dashboardModel: DashboardModel
    @StateObject private var activeAppsModel = ActiveAppsModel()
    @State private var selectedTab: DashboardTab = .overview
    let openPreferences: () -> Void
    let quitApplication: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], 18)
                .padding(.bottom, 10)

            tabPicker
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                switch selectedTab {
                case .overview:
                    overviewContent
                case .actives:
                    activesContent
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button("Preferences", action: openPreferences)
                Spacer(minLength: 12)
                Button("Quit", action: quitApplication)
            }
            .padding(14)
            .background(.bar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            activeAppsModel.refresh()
        }
        .onChange(of: selectedTab) { tab in
            if tab == .actives {
                activeAppsModel.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mac Activity")
                    .font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("Live")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
    }

    private var tabPicker: some View {
        Picker("Dashboard section", selection: $selectedTab) {
            ForEach(DashboardTab.allCases) { tab in
                Text(tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var overviewContent: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if dashboardModel.metrics.isEmpty {
                emptyState
            } else {
                ForEach(dashboardModel.metrics) { metric in
                    MetricCard(metric: metric)
                }
            }
        }
        .padding(18)
    }

    private var activesContent: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ActiveAppsMemoryCard(model: activeAppsModel)
        }
        .padding(18)
    }

    private var summaryText: String {
        let visible = dashboardModel.metrics.prefix(3).map { metric in
            "\(metric.title) \(metric.value)"
        }
        return visible.isEmpty ? "Waiting for the first sample" : visible.joined(separator: " · ")
    }

    private var emptyState: some View {
        Text("Waiting for the first metric sample.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@MainActor
private final class ActiveAppsModel: ObservableObject {
    @Published private(set) var apps: [ActiveAppMemoryEntry] = []
    @Published private(set) var lastActionMessage: String?
    @Published private(set) var isCleaningMemory = false

    private let service: ActiveAppMemoryService
    private let memoryCleaner: any MemoryCleaning
    private let limit: Int

    init(
        service: ActiveAppMemoryService = ActiveAppMemoryService(),
        memoryCleaner: any MemoryCleaning = CleanMemoryService(),
        limit: Int = 8
    ) {
        self.service = service
        self.memoryCleaner = memoryCleaner
        self.limit = limit
        refresh()
    }

    func refresh() {
        apps = service.topApps(limit: limit)
    }

    func cleanMemory() async {
        guard !isCleaningMemory else { return }
        isCleaningMemory = true
        lastActionMessage = "Cleaning reclaimable memory…"

        let result = await memoryCleaner.cleanMemory()

        switch result {
        case .succeeded:
            lastActionMessage = "Cleaned reclaimable memory."
        case .unavailable:
            lastActionMessage = "Memory clean command is unavailable on this Mac."
        case .failed(let exitCode):
            lastActionMessage = "Memory clean failed with exit code \(exitCode)."
        }

        isCleaningMemory = false
        refresh()
    }

    func quit(_ app: ActiveAppMemoryEntry) {
        switch service.requestTermination(processIdentifier: app.processIdentifier) {
        case .requested:
            lastActionMessage = "Requested \(app.name) to quit."
        case .notFound:
            lastActionMessage = "\(app.name) is no longer running."
        case .notTerminable:
            lastActionMessage = "\(app.name) could not be quit safely."
        }
        refresh()
    }
}

private struct ActiveAppsMemoryCard: View {
    @ObservedObject var model: ActiveAppsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Top Memory Apps")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Visible apps ranked by resident memory")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                Button("Refresh") {
                    model.refresh()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            cleanMemoryButton

            if model.apps.isEmpty {
                Text("No foreground apps are reporting memory usage yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.apps) { app in
                        ActiveAppRow(app: app) {
                            model.quit(app)
                        }

                        if app.id != model.apps.last?.id {
                            Divider()
                                .padding(.leading, 28)
                        }
                    }
                }
            }

            if let message = model.lastActionMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(DashboardCardLayout.regularCardInsets)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }

    private var cleanMemoryButton: some View {
        Button {
            Task {
                await model.cleanMemory()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(model.isCleaningMemory ? "Cleaning Memory…" : "Clean Memory")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isCleaningMemory)
        .help("Release reclaimable system memory without deleting app data")
    }
}

private struct ActiveAppRow: View {
    let app: ActiveAppMemoryEntry
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "app.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let bundleIdentifier = app.bundleIdentifier {
                    Text(bundleIdentifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(app.formattedResidentMemory)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)

            Button("Quit", action: quit)
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!app.isTerminable)
                .help("Request this app to quit safely")
        }
        .padding(.vertical, 6)
    }
}

struct RAMSegmentBarsLayout {
    static let rollingWindowDuration: TimeInterval = 5 * 60

    static func displaySampleBudget(for containerSize: CGSize) -> Int {
        guard containerSize.width > 0 else { return 1 }
        return min(96, max(12, Int((containerSize.width / 5).rounded())))
    }

    static func displaySamples(
        for samples: [DashboardMemoryTrendSample],
        containerSize: CGSize,
        referenceDate: Date
    ) -> [DashboardMemoryTrendSample] {
        let budget = displaySampleBudget(for: containerSize)
        let windowStart = referenceDate.addingTimeInterval(-rollingWindowDuration)
        let recentSamples = samples.filter {
            $0.timestamp >= windowStart && $0.timestamp <= referenceDate
        }

        guard recentSamples.count > budget, budget > 1 else { return recentSamples }

        let scale = Double(recentSamples.count - 1) / Double(budget - 1)
        return (0..<budget).reduce(into: []) { result, index in
            let sampleIndex = Int((Double(index) * scale).rounded())
            guard recentSamples.indices.contains(sampleIndex),
                  result.last?.timestamp != recentSamples[sampleIndex].timestamp else { return }
            result.append(recentSamples[sampleIndex])
        }
    }

    static func displaySlots(
        for samples: [DashboardMemoryTrendSample],
        containerSize: CGSize,
        referenceDate: Date
    ) -> [RAMSegmentBarSlot] {
        let budget = displaySampleBudget(for: containerSize)
        let displayedSamples = displaySamples(
            for: samples,
            containerSize: containerSize,
            referenceDate: referenceDate
        )
        let emptySlotCount = max(0, budget - displayedSamples.count)
        let emptySlots = Array(repeating: RAMSegmentBarSlot(sample: nil), count: emptySlotCount)
        let sampleSlots = displayedSamples.map { RAMSegmentBarSlot(sample: $0) }

        return emptySlots + sampleSlots
    }

    static func displaySegments(for sample: DashboardMemoryTrendSample) -> [RAMSegmentBarComponent] {
        let usedBytes = min(sample.usedBytes, sample.totalBytes)
        guard usedBytes > 0 else { return [] }

        let rawSegments = [
            RAMSegmentBarComponent(kind: .active, bytes: sample.breakdown.activeBytes),
            RAMSegmentBarComponent(kind: .compressed, bytes: sample.breakdown.compressedBytes),
            RAMSegmentBarComponent(kind: .wired, bytes: sample.breakdown.wiredBytes),
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
    var sample: DashboardMemoryTrendSample?
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

private struct RAMSegmentBars: View {
    let trend: DashboardMemoryTrend
    @State private var hoveredSlotIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            let referenceDate = trend.samples.last?.timestamp ?? .now
            let slots = RAMSegmentBarsLayout.displaySlots(
                for: trend.samples,
                containerSize: proxy.size,
                referenceDate: referenceDate
            )
            let barWidth = RAMSegmentBarsLayout.barWidth(slotCount: slots.count, containerWidth: proxy.size.width)
            let spacing = RAMSegmentBarsLayout.spacing(slotCount: slots.count)
            let hoveredSample = hoveredSlotIndex.flatMap { index in
                slots.indices.contains(index) ? slots[index].sample : nil
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

                if let hoveredSample, let hoveredSlotIndex {
                    RAMSegmentTooltip(sample: hoveredSample)
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
            .accessibilityLabel(accessibilityLabel(for: slots.compactMap(\.sample).last))
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

    private func accessibilityLabel(for sample: DashboardMemoryTrendSample?) -> String {
        guard let sample else { return "Memory chart collecting samples" }
        let parts = [
            "Memory \(Int(sample.pressurePercent.rounded())) percent",
            "used \(DashboardMetricTextFormatter.formatMemoryGB(sample.usedBytes))",
            "of \(DashboardMetricTextFormatter.formatMemoryGB(sample.totalBytes))",
        ]
        return parts.joined(separator: ", ")
    }
}

private struct RAMSegmentBar: View {
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
                                .fill(color(for: segment.kind))
                                .frame(height: barHeight(for: segment, sample: sample, containerHeight: proxy.size.height))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
        }
    }

    private func barHeight(for segment: RAMSegmentBarComponent, sample: DashboardMemoryTrendSample, containerHeight: CGFloat) -> CGFloat {
        let ratio = min(max(CGFloat(Double(segment.bytes) / Double(sample.totalBytes)), 0), 1)
        return max(1, ratio * containerHeight)
    }
}

private struct RAMSegmentLegend: View {
    let sample: DashboardMemoryTrendSample

    var body: some View {
        let segments = RAMSegmentBarsLayout.displaySegments(for: sample)
        HStack(spacing: 8) {
            ForEach(segments) { segment in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: segment.kind))
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
    let sample: DashboardMemoryTrendSample

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(RAMSegmentBarsLayout.displaySegments(for: sample)) { segment in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: segment.kind))
                        .frame(width: 8, height: 8)
                    Text("\(segment.kind.title): \(DashboardMetricTextFormatter.formatMemoryGB(segment.bytes)) (\(DashboardMetricTextFormatter.formatPercent(RAMSegmentBarsLayout.percentage(for: segment, in: sample))))")
                        .font(.caption2.monospacedDigit())
                        .lineLimit(1)
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

private func color(for kind: RAMSegmentBarComponent.Kind) -> Color {
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

private struct MetricCard: View {
    let metric: DashboardMetric
    @State private var isCardHovered = false

    private var isCompactChartCard: Bool {
        metric.style == .chart || metric.style == .memoryStackedChart
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompactChartCard ? 6 : 10) {
            HStack(alignment: .top) {
                Text(metric.title)
                    .font(isCompactChartCard ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailingValueView
            }

            switch metric.style {
            case .chart:
                DashboardTrendChart(metric: metric, color: color, isCardHovered: isCardHovered)
                    .frame(height: DashboardCardLayout.compactChartHeight)
            case .memoryStackedChart:
                if let memoryTrend = metric.memoryTrend, !memoryTrend.samples.isEmpty {
                    RAMSegmentBars(trend: memoryTrend)
                        .frame(height: DashboardCardLayout.compactChartHeight)
                    if let latestSample = memoryTrend.samples.last {
                        RAMSegmentLegend(sample: latestSample)
                    }
                } else {
                    DashboardTrendChart(metric: metric, color: color, isCardHovered: isCardHovered)
                        .frame(height: DashboardCardLayout.compactChartHeight)
                }
            case .value:
                Rectangle()
                    .fill(color.opacity(0.14))
                    .frame(height: 4)
                    .clipShape(Capsule())
            }

            if let detail = metric.detail, !isCompactChartCard {
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
            alignment: .topLeading
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .onHover { hovering in
            isCardHovered = hovering
        }
    }

    private var color: Color {
        switch metric.kind {
        case .cpu:
            return .orange
        case .gpu:
            return .purple
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
