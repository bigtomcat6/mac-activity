import SwiftUI
import MacActivityCore

enum DashboardCardLayout {
    static let compactChartHeight: CGFloat = 60
    static let compactChartMinHeight: CGFloat = 98
    static let compactChartInsets = EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8)
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

private struct MetricCard: View {
    let metric: DashboardMetric
    @State private var isCardHovered = false

    private var isCompactChartCard: Bool {
        metric.style == .chart
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
                DashboardTrendChart(
                    metric: metric,
                    color: color,
                    isCardHovered: isCardHovered
                )
                    .frame(height: DashboardCardLayout.compactChartHeight)
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
            minHeight: metric.style == .chart ? DashboardCardLayout.compactChartMinHeight : 44,
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
