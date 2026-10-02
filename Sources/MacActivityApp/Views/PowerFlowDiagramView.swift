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
        case .unknown: return "questionmark.circle.fill"
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
            PowerFlowDiagramFlowCanvas(
                layout: plan.layout,
                sources: presentation.sources,
                sinks: presentation.sinks
            )
            .accessibilityHidden(true)

            tiles(nodes: presentation.sources, frames: plan.layout.sourceFrames)
            tiles(nodes: presentation.sinks, frames: plan.layout.sinkFrames)
            ForEach(Array(zip(plan.flowLabels, plan.layout.flowLabelFrames)), id: \.0.id) { label, frame in
                PowerFlowDiagramWattLabel(text: label.text).diagramFrame(frame)
            }
        }
    }

    private func tiles(nodes: [PowerFlowDiagramNode], frames: [CGRect]) -> some View {
        ForEach(Array(zip(nodes, frames)), id: \.0.id) { node, frame in
            PowerFlowDiagramNodeTile(
                node: node,
                isCompact: frame.height < PowerFlowDiagramNodeVisual.compactHeightThreshold
            )
            .diagramFrame(frame)
        }
    }

    @ViewBuilder
    private func groupedContent(plan: PowerFlowDiagramRenderPlan) -> some View {
        if let source = plan.layout.groupedSourceFrame,
           let center = plan.layout.groupedCenterFrame,
           let sink = plan.layout.groupedSinkFrame {
            groupedBusConnector(source: source, sink: sink, center: center)
            PowerFlowDiagramSideSummaryView(summary: presentation.sourceSummary, countKey: .powerFlowSourcesCount)
                .diagramFrame(source)
            PowerFlowDiagramSideSummaryView(summary: presentation.sinkSummary, countKey: .powerFlowOutputsCount)
                .diagramFrame(sink)
            VStack(spacing: 2) {
                aggregateLabel(title: .powerFlowInput, value: plan.sourceTotalText)
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 26, height: 0.5)
                aggregateLabel(title: .powerFlowOutput, value: plan.sinkTotalText)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PowerFlowDiagramSurface())
            .diagramFrame(center)
        }
    }

    private func groupedBusConnector(source: CGRect, sink: CGRect, center: CGRect) -> some View {
        let connector = CGRect(
            x: source.maxX,
            y: center.midY - 12,
            width: max(0, sink.minX - source.maxX),
            height: 24
        )
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .frame(width: connector.width, height: connector.height)
            .position(x: connector.midX, y: connector.midY)
            .accessibilityHidden(true)
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

// Shared node metrics keep icon and title content inside the 28 pt two-lane
// tiles while allowing a larger icon on the 64 pt single-lane tiles.
enum PowerFlowDiagramNodeVisual {
    static let baseFillOpacity: Double = 0.05
    static let compactHeightThreshold: CGFloat = 40
    static let compactIconPointSize: CGFloat = 14
    static let compactTitlePointSize: CGFloat = 9
    static let regularIconPointSize: CGFloat = 22
    static let regularTitlePointSize: CGFloat = 11
    // Compact tiles stack the icon over a full-width title: the horizontal
    // arrangement left only a few points of title width on 40 pt nodes.
    static let compactSpacing: CGFloat = 0
    static let regularSpacing: CGFloat = 2
    static let tilePadding: CGFloat = 3
    static let compactTilePadding: CGFloat = 1

    static func fillOpacity(for appearance: DashboardStyleAppearance) -> Double {
        max(appearance.moduleFillOpacity, baseFillOpacity)
    }
}

// Internal layers reuse the resolved dashboard policy, never nested glass.
// A small base fill keeps tiles visible even when the standard policy's
// moduleFillOpacity is zero.
private struct PowerFlowDiagramSurface: View {
    var isSynthetic = false
    @Environment(\.dashboardStyleAppearance) private var appearance
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let stroke = contrast == .increased
            ? max(appearance.strokeOpacity, DashboardPresentationPolicy.increasedContrastStrokeOpacity)
            : appearance.strokeOpacity
        shape
            .fill(Color.primary.opacity(PowerFlowDiagramNodeVisual.fillOpacity(for: appearance)))
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(stroke),
                    style: StrokeStyle(lineWidth: 0.5, dash: isSynthetic ? [3, 3] : [])
                )
            }
    }
}

struct PowerFlowDiagramNodeTile: View {
    let node: PowerFlowDiagramNode
    let isCompact: Bool

    var body: some View {
        content
            .padding(isCompact ? PowerFlowDiagramNodeVisual.compactTilePadding : PowerFlowDiagramNodeVisual.tilePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PowerFlowDiagramSurface(isSynthetic: node.isSynthetic))
    }

    @ViewBuilder
    var content: some View {
        if isCompact {
            compactContent
        } else {
            regularContent
        }
    }

    var compactContent: some View {
        VStack(spacing: PowerFlowDiagramNodeVisual.compactSpacing) {
            symbol(pointSize: PowerFlowDiagramNodeVisual.compactIconPointSize)
            title(pointSize: PowerFlowDiagramNodeVisual.compactTitlePointSize)
        }
    }

    var regularContent: some View {
        VStack(spacing: PowerFlowDiagramNodeVisual.regularSpacing) {
            symbol(pointSize: PowerFlowDiagramNodeVisual.regularIconPointSize)
            title(pointSize: PowerFlowDiagramNodeVisual.regularTitlePointSize)
        }
    }

    private func symbol(pointSize: CGFloat) -> some View {
        Image(systemName: PowerFlowDiagramPalette.symbol(for: node.kind))
            .font(.system(size: pointSize, weight: .semibold))
            .foregroundStyle(PowerFlowDiagramPalette.color(for: node.kind))
            // The SF power plug is drawn horizontally; rotate it upright to match
            // the reference instead of depending on a non-native symbol.
            .rotationEffect(.degrees(node.kind == .externalPower ? 90 : 0))
            .accessibilityHidden(true)
    }

    private func title(pointSize: CGFloat) -> some View {
        Text(node.title)
            .font(.system(size: pointSize, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .help(node.title)
    }
}

struct PowerFlowDiagramSideSummaryView: View {
    let summary: PowerFlowDiagramSideSummary
    let countKey: AppLocalization.Key

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            let count = AppLocalization.string(countKey, Int64(summary.memberCount))
            Text(count).font(.caption2.weight(.semibold)).lineLimit(1).help(count)
            ForEach(summary.representatives) { node in
                representativeRow(node)
            }
            bottomRow
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PowerFlowDiagramSurface())
    }

    private func representativeRow(_ node: PowerFlowDiagramNode) -> some View {
        HStack(spacing: 2) {
            Image(systemName: PowerFlowDiagramPalette.symbol(for: node.kind))
                .accessibilityHidden(true)
            Text(node.title).lineLimit(1).minimumScaleFactor(0.7).help(node.title)
            Spacer(minLength: 0)
            if let value = PowerFlowDiagramRenderPlan.powerText(node.measurement, provenance: node.provenance) {
                valueLabel(value).layoutPriority(1)
            }
        }
        .font(.caption2)
    }

    private var bottomRow: some View {
        HStack(spacing: 4) {
            if let total = PowerFlowDiagramRenderPlan.powerText(summary.total, provenance: summary.provenance) {
                valueLabel(total)
            }
            Spacer(minLength: 0)
            let hidden = summary.memberCount - summary.representatives.count
            if hidden > 0 {
                let more = AppLocalization.string(.powerFlowMoreCount, Int64(hidden))
                Text(more).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(more)
            }
        }
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

// Each ribbon fades from its endpoint tint to the same neutral-blue bus tint at
// the seam, so the two halves share one continuous color and opacity without a
// mid-band reset. Endpoint colors stay meaningful (battery green, Mac blue);
// external/unknown sources stay neutral.
enum PowerFlowDiagramFlowStyle {
    static let busCornerRadius: CGFloat = 8
    static let busTint = Color(red: 0.36, green: 0.55, blue: 0.88)

    static func opacities(
        contrast: ColorSchemeContrast,
        colorScheme: ColorScheme
    ) -> (edge: Double, peak: Double) {
        switch (contrast, colorScheme) {
        case (.increased, .dark): return (0.34, 0.74)
        case (.increased, _): return (0.28, 0.66)
        case (_, .dark): return (0.22, 0.56)
        default: return (0.16, 0.44)
        }
    }

    static func shading(
        ribbon: PowerFlowDiagramRibbonLayout,
        isSource: Bool,
        tint: Color,
        contrast: ColorSchemeContrast,
        colorScheme: ColorScheme
    ) -> GraphicsContext.Shading {
        let (edge, peak) = opacities(contrast: contrast, colorScheme: colorScheme)
        let shoulder = (edge + peak) / 2
        let stops: [Gradient.Stop] = isSource
            ? [
                Gradient.Stop(color: tint.opacity(edge), location: 0),
                Gradient.Stop(color: tint.opacity(shoulder), location: 0.5),
                Gradient.Stop(color: busTint.opacity(peak), location: 1),
            ]
            : [
                Gradient.Stop(color: busTint.opacity(peak), location: 0),
                Gradient.Stop(color: tint.opacity(shoulder), location: 0.5),
                Gradient.Stop(color: tint.opacity(edge), location: 1),
            ]
        return .linearGradient(
            Gradient(stops: stops),
            startPoint: CGPoint(x: ribbon.frame.minX, y: ribbon.frame.midY),
            endPoint: CGPoint(x: ribbon.frame.maxX, y: ribbon.frame.midY)
        )
    }

    static func busFill(contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.10 : 0.05)
    }

    static func busStroke(contrast: ColorSchemeContrast) -> Color {
        Color.primary.opacity(contrast == .increased ? 0.45 : 0.16)
    }
}

private struct PowerFlowDiagramFlowCanvas: View {
    let layout: PowerFlowDiagramLayoutResult
    let sources: [PowerFlowDiagramNode]
    let sinks: [PowerFlowDiagramNode]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, _ in
            draw(ribbons: layout.sourceRibbons, nodes: sources, isSource: true, in: &context)
            draw(ribbons: layout.sinkRibbons, nodes: sinks, isSource: false, in: &context)
            if let bus = layout.busFrame {
                let path = Path(roundedRect: bus, cornerRadius: PowerFlowDiagramFlowStyle.busCornerRadius)
                context.fill(path, with: .color(PowerFlowDiagramFlowStyle.busFill(contrast: contrast)))
                context.stroke(
                    path,
                    with: .color(PowerFlowDiagramFlowStyle.busStroke(contrast: contrast)),
                    lineWidth: 0.5
                )
            }
        }
        .frame(width: layout.cardFrame.width, height: layout.cardFrame.height)
        .allowsHitTesting(false)
    }

    private func draw(
        ribbons: [PowerFlowDiagramRibbonLayout],
        nodes: [PowerFlowDiagramNode],
        isSource: Bool,
        in context: inout GraphicsContext
    ) {
        for (node, ribbon) in zip(nodes, ribbons) {
            switch node.measurement {
            case .idle:
                continue
            case .unavailable:
                let path = PowerFlowRibbonShape(layout: ribbon).path(in: ribbon.frame)
                let outline = PowerFlowDiagramPalette.color(for: node.kind)
                context.fill(path, with: .color(outline.opacity(0.06)))
                context.stroke(
                    path,
                    with: .color(outline.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 1, dash: node.isSynthetic ? [2, 3] : [3, 4])
                )
            case .exact, .lowerBound:
                let shading = PowerFlowDiagramFlowStyle.shading(
                    ribbon: ribbon,
                    isSource: isSource,
                    tint: PowerFlowDiagramPalette.color(for: node.kind),
                    contrast: contrast,
                    colorScheme: colorScheme
                )
                context.fill(
                    PowerFlowRibbonShape(layout: ribbon).path(in: ribbon.frame),
                    with: shading
                )
            }
        }
    }
}

private struct PowerFlowRibbonShape: Shape {
    var layout: PowerFlowDiagramRibbonLayout

    func path(in rect: CGRect) -> Path {
        let startTop = rect.minY + layout.startCenterY - layout.startHeight / 2
        let startBottom = rect.minY + layout.startCenterY + layout.startHeight / 2
        let endTop = rect.minY + layout.endCenterY - layout.endHeight / 2
        let endBottom = rect.minY + layout.endCenterY + layout.endHeight / 2
        let controlX = rect.width * 0.52
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: startTop))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: endTop),
            control1: CGPoint(x: rect.minX + controlX, y: startTop),
            control2: CGPoint(x: rect.maxX - controlX, y: endTop)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: endBottom))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: startBottom),
            control1: CGPoint(x: rect.maxX - controlX, y: endBottom),
            control2: CGPoint(x: rect.minX + controlX, y: startBottom)
        )
        path.closeSubpath()
        return path
    }
}
