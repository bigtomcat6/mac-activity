import SwiftUI

struct PowerFlowDiagramFlowLabel: Equatable, Identifiable {
    var nodeID: String
    var text: String
    var id: String { nodeID }
}

struct PowerFlowDiagramRenderPlan: Equatable {
    var layout: PowerFlowDiagramLayoutResult
    var flowLabels: [PowerFlowDiagramFlowLabel]
    var usesSharedBus: Bool
    let exposesPairwiseEdges = false
    var sourceTotalText: String?
    var sinkTotalText: String?
    var totalsText: String?

    init(presentation: PowerFlowDiagramPresentation, width: CGFloat) {
        layout = PowerFlowDiagramLayout.resolve(
            width: width, preferredMode: presentation.preferredMode,
            sourceCount: presentation.sources.count, sinkCount: presentation.sinks.count
        )
        let labeledNodes: [PowerFlowDiagramNode]
        switch layout.effectiveMode {
        case .expanded(.oneToOne), .expanded(.oneToMany):
            labeledNodes = presentation.sinks
        case .expanded(.manyToOne), .expanded(.manyToMany):
            labeledNodes = presentation.sources + presentation.sinks
        case .waiting, .idle, .unavailable, .grouped:
            labeledNodes = []
        }
        flowLabels = labeledNodes.compactMap { node in
            Self.powerText(node.measurement, provenance: node.provenance).map {
                PowerFlowDiagramFlowLabel(nodeID: node.id, text: $0)
            }
        }
        usesSharedBus = layout.effectiveMode == .expanded(.manyToMany)
        sourceTotalText = Self.powerText(presentation.sourceSummary.total, provenance: presentation.sourceSummary.provenance)
        sinkTotalText = Self.powerText(presentation.sinkSummary.total, provenance: presentation.sinkSummary.provenance)
        let showsTotals = layout.effectiveMode == .grouped || usesSharedBus || !presentation.issues.isEmpty
        if showsTotals, let input = sourceTotalText, let output = sinkTotalText {
            totalsText = AppLocalization.string(.powerFlowTotals, input, output)
        }
    }

    static func powerText(
        _ measurement: PowerFlowDisplayMeasurement,
        provenance: PowerFlowDisplayProvenance
    ) -> String? {
        PowerFlowPresentation.diagramPowerText(
            measurement, provenance: provenance, locale: AppLocalization.currentLocale()
        )
    }
}

enum PowerFlowDiagramMotion {
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: DashboardMotion.valueDuration)
    }
}

enum PowerFlowDiagramPalette {
    static func color(for kind: PowerFlowDiagramNodeKind) -> Color {
        switch kind {
        case .externalPower, .unknown: return .secondary
        case .battery: return .green
        case .mac: return .blue
        case .other: return .indigo
        }
    }

    static func symbol(for kind: PowerFlowDiagramNodeKind) -> String {
        switch kind {
        case .externalPower: return "powerplug.fill"
        case .battery: return "battery.100"
        case .mac: return "laptopcomputer"
        case .other: return "ellipsis"
        case .unknown: return "questionmark"
        }
    }
}

struct PowerFlowDiagramView: View {
    let presentation: PowerFlowDiagramPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                statusRow(plan: plan).diagramFrame(plan.layout.statusFrame)
                diagramContent(plan: plan)
            }
            .frame(width: plan.layout.cardFrame.width, height: plan.layout.cardFrame.height)
        }
        .frame(height: PowerFlowDiagramLayout.cardHeight)
        .dashboardCardChrome()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(presentation.accessibilityLabel))
        .animation(PowerFlowDiagramMotion.animation(reduceMotion: reduceMotion), value: presentation)
    }

    private func statusRow(plan: PowerFlowDiagramRenderPlan) -> some View {
        HStack(spacing: 4) {
            let status = PowerFlowPresentation.statusText(presentation.status)
            Text(status)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .help(status)
            if !presentation.issues.isEmpty {
                let partial = AppLocalization.string(.powerFlowPartialData)
                Text(partial)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(partial)
            }
            Spacer(minLength: 0)
            if let totals = plan.totalsText {
                PowerFlowDiagramWattLabel(text: totals)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
            }
        }
    }

    @ViewBuilder
    private func diagramContent(plan: PowerFlowDiagramRenderPlan) -> some View {
        switch plan.layout.effectiveMode {
        case .expanded:
            expandedContent(plan: plan)
        case .grouped:
            groupedContent(plan: plan)
        case .waiting:
            terminalContent(symbol: "hourglass", status: .waiting)
                .diagramFrame(plan.layout.diagramFrame)
        case .unavailable:
            terminalContent(symbol: "questionmark.circle", status: .unavailable)
                .diagramFrame(plan.layout.diagramFrame)
        case .idle:
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    ForEach(presentation.idleEndpoints.prefix(2)) { node in
                        Label(node.title, systemImage: PowerFlowDiagramPalette.symbol(for: node.kind))
                            .lineLimit(1)
                            .help(node.title)
                    }
                }
                Text(PowerFlowPresentation.statusText(.idle))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .diagramFrame(plan.layout.diagramFrame)
        }
    }

    private func terminalContent(symbol: String, status: PowerFlowDiagramStatus) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(PowerFlowPresentation.statusText(status))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .help(PowerFlowPresentation.statusText(status))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func expandedContent(plan: PowerFlowDiagramRenderPlan) -> some View {
        Group {
            Group {
                ribbons(nodes: presentation.sources, layouts: plan.layout.sourceRibbons)
                if let bus = plan.layout.busFrame {
                    sharedBus.diagramFrame(bus)
                }
                ribbons(nodes: presentation.sinks, layouts: plan.layout.sinkRibbons)
            }
            .accessibilityHidden(true)

            tiles(nodes: presentation.sources, frames: plan.layout.sourceFrames)
            tiles(nodes: presentation.sinks, frames: plan.layout.sinkFrames)
            ForEach(Array(zip(plan.flowLabels, plan.layout.flowLabelFrames)), id: \.0.id) { label, frame in
                PowerFlowDiagramWattLabel(text: label.text).diagramFrame(frame)
            }
        }
    }

    private func ribbons(nodes: [PowerFlowDiagramNode], layouts: [PowerFlowDiagramRibbonLayout]) -> some View {
        ForEach(Array(zip(nodes, layouts)), id: \.0.id) { node, layout in
            PowerFlowRibbon(layout: layout, kind: node.kind, measurement: node.measurement)
                .diagramFrame(layout.frame)
        }
        .accessibilityHidden(true)
    }

    private func tiles(nodes: [PowerFlowDiagramNode], frames: [CGRect]) -> some View {
        ForEach(Array(zip(nodes, frames)), id: \.0.id) { node, frame in
            PowerFlowDiagramNodeTile(node: node).diagramFrame(frame)
        }
    }

    @ViewBuilder
    private func groupedContent(plan: PowerFlowDiagramRenderPlan) -> some View {
        if let source = plan.layout.groupedSourceFrame,
           let center = plan.layout.groupedCenterFrame,
           let sink = plan.layout.groupedSinkFrame {
            PowerFlowDiagramSideSummaryView(summary: presentation.sourceSummary, countKey: .powerFlowSourcesCount)
                .diagramFrame(source)
            PowerFlowDiagramSideSummaryView(summary: presentation.sinkSummary, countKey: .powerFlowOutputsCount)
                .diagramFrame(sink)
            if let bus = plan.layout.busFrame {
                sharedBus.diagramFrame(bus).accessibilityHidden(true)
            }
            VStack(spacing: 2) {
                aggregateLabel(title: .powerFlowInput, value: plan.sourceTotalText)
                aggregateLabel(title: .powerFlowOutput, value: plan.sinkTotalText)
            }
            .diagramFrame(center)
        }
    }

    private func aggregateLabel(title: AppLocalization.Key, value: String?) -> some View {
        VStack(spacing: 0) {
            let title = AppLocalization.string(title)
            Text(title).font(.caption2).lineLimit(1).help(title)
            if let value {
                PowerFlowDiagramWattLabel(text: value)
            }
        }
    }

    private var sharedBus: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.secondary.opacity(0.16))
            .accessibilityHidden(true)
    }
}

private extension View {
    func diagramFrame(_ frame: CGRect) -> some View {
        self.frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

private struct PowerFlowDiagramWattLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
    }
}

// Internal layers reuse the resolved dashboard policy, never nested glass.
private struct PowerFlowDiagramSurface: View {
    var isSynthetic = false
    @Environment(\.dashboardStyleAppearance) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let stroke = contrast == .increased
            ? max(appearance.strokeOpacity, DashboardPresentationPolicy.increasedContrastStrokeOpacity)
            : appearance.strokeOpacity
        shape.fill(Color.primary.opacity(appearance.moduleFillOpacity))
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(stroke),
                    style: StrokeStyle(lineWidth: 0.5, dash: isSynthetic ? [3, 3] : [])
                )
            }
    }
}

private struct PowerFlowDiagramNodeTile: View {
    let node: PowerFlowDiagramNode

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: PowerFlowDiagramPalette.symbol(for: node.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(PowerFlowDiagramPalette.color(for: node.kind))
                .accessibilityHidden(true)
            Text(node.title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .help(node.title)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PowerFlowDiagramSurface(isSynthetic: node.isSynthetic))
    }
}

private struct PowerFlowDiagramSideSummaryView: View {
    let summary: PowerFlowDiagramSideSummary
    let countKey: AppLocalization.Key

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let count = AppLocalization.string(countKey, Int64(summary.memberCount))
            Text(count).font(.caption2.weight(.semibold)).lineLimit(1).help(count)
            ForEach(summary.representatives) { node in
                HStack(spacing: 2) {
                    Image(systemName: PowerFlowDiagramPalette.symbol(for: node.kind))
                        .accessibilityHidden(true)
                    Text(node.title).lineLimit(1).help(node.title)
                    Spacer(minLength: 0)
                    if let value = PowerFlowDiagramRenderPlan.powerText(node.measurement, provenance: node.provenance) {
                        PowerFlowDiagramWattLabel(text: value).layoutPriority(1)
                    }
                }
                .font(.caption2)
            }
            let hidden = summary.memberCount - summary.representatives.count
            if hidden > 0 {
                let more = AppLocalization.string(.powerFlowMoreCount, Int64(hidden))
                Text(more).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(more)
            }
            if let total = PowerFlowDiagramRenderPlan.powerText(summary.total, provenance: summary.provenance) {
                PowerFlowDiagramWattLabel(text: total)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PowerFlowDiagramSurface())
    }
}

private struct PowerFlowRibbonShape: Shape {
    var layout: PowerFlowDiagramRibbonLayout

    func path(in rect: CGRect) -> Path {
        let startTop = layout.startCenterY - layout.startHeight / 2
        let startBottom = layout.startCenterY + layout.startHeight / 2
        let endTop = layout.endCenterY - layout.endHeight / 2
        let endBottom = layout.endCenterY + layout.endHeight / 2
        let controlX = rect.width * 0.52
        var path = Path()
        path.move(to: CGPoint(x: 0, y: startTop))
        path.addCurve(
            to: CGPoint(x: rect.width, y: endTop),
            control1: CGPoint(x: controlX, y: startTop),
            control2: CGPoint(x: rect.width - controlX, y: endTop)
        )
        path.addLine(to: CGPoint(x: rect.width, y: endBottom))
        path.addCurve(
            to: CGPoint(x: 0, y: startBottom),
            control1: CGPoint(x: rect.width - controlX, y: endBottom),
            control2: CGPoint(x: controlX, y: startBottom)
        )
        path.closeSubpath()
        return path
    }
}

private struct PowerFlowRibbon: View {
    let layout: PowerFlowDiagramRibbonLayout
    let kind: PowerFlowDiagramNodeKind
    let measurement: PowerFlowDisplayMeasurement

    var body: some View {
        let shape = PowerFlowRibbonShape(layout: layout)
        let color = PowerFlowDiagramPalette.color(for: kind)
        switch measurement {
        case .exact:
            shape.fill(LinearGradient(
                colors: [color.opacity(0.20), color.opacity(0.58)],
                startPoint: .leading, endPoint: .trailing
            ))
        case .unavailable:
            shape.stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        case .lowerBound:
            shape.fill(color.opacity(0.32))
        case .idle:
            EmptyView()
        }
    }
}
