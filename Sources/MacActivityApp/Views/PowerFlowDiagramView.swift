import SwiftUI

struct PowerFlowDiagramFlowLabel: Equatable, Identifiable {
    var nodeID: String
    var text: String
    var id: String { nodeID }
}

/// Localized endpoint + measurement explanation reused by lane hit regions,
/// icon help and idle context. Never a bare number.
enum PowerFlowDiagramHelp {
    static func node(_ node: PowerFlowDiagramNode) -> String {
        switch node.measurement {
        case .unavailable:
            return AppLocalization.string(.powerFlowAccessibilityNodeUnavailable, node.title)
        case .idle:
            return node.title
        case .exact, .lowerBound:
            guard let value = PowerFlowDiagramRenderPlan.powerText(
                node.measurement, provenance: node.provenance
            ) else {
                return node.title
            }
            let key: AppLocalization.Key =
                node.provenance == .derived || node.provenance == .mixed
                ? .powerFlowAccessibilityNodeDerived
                : .powerFlowAccessibilityNodeMeasured
            return AppLocalization.string(key, node.title, value)
        }
    }

    /// View-level combined narration. The builder's idle label is status-only,
    /// so idle endpoint identities are appended here without touching the model.
    static func combinedAccessibilityLabel(_ presentation: PowerFlowDiagramPresentation) -> String {
        guard presentation.status == .idle, !presentation.idleEndpoints.isEmpty else {
            return presentation.accessibilityLabel
        }
        let idle = presentation.idleEndpoints
            .map { node($0) }
            .joined(separator: "; ")
        return presentation.accessibilityLabel + " " + idle
    }
}

struct PowerFlowDiagramRenderPlan: Equatable {
    var layout: PowerFlowDiagramLayoutResult
    var flowLabels: [PowerFlowDiagramFlowLabel]
    let exposesPairwiseEdges = false
    var sourceTotalText: String?
    var sinkTotalText: String?
    var totalsText: String?
    var qualityText: String?
    var showsExpandedTotalsFooter: Bool
    var endpointPowerLabels: [String: String] = [:]

    init(presentation: PowerFlowDiagramPresentation, width: CGFloat) {
        let sourceTotal = Self.powerText(
            presentation.sourceSummary.total, provenance: presentation.sourceSummary.provenance
        )
        let sinkTotal = Self.powerText(
            presentation.sinkSummary.total, provenance: presentation.sinkSummary.provenance
        )
        sourceTotalText = sourceTotal
        sinkTotalText = sinkTotal

        let effective = PowerFlowDiagramLayout.effectiveMode(
            preferredMode: presentation.preferredMode, width: width
        )
        let isExpanded: Bool
        if case .expanded = effective { isExpanded = true } else { isExpanded = false }

        var totals: String?
        if isExpanded, !presentation.issues.isEmpty, let input = sourceTotal, let output = sinkTotal {
            totals = AppLocalization.string(.powerFlowTotals, input, output)
        } else if effective == .grouped, let input = sourceTotal, let output = sinkTotal {
            totals = AppLocalization.string(.powerFlowTotals, input, output)
        }
        totalsText = totals
        showsExpandedTotalsFooter = isExpanded && totals != nil

        layout = PowerFlowDiagramLayout.resolve(
            width: width, preferredMode: presentation.preferredMode,
            sourceCount: presentation.sources.count, sinkCount: presentation.sinks.count,
            reservesTotalsFooter: showsExpandedTotalsFooter,
            sourceWatts: presentation.sources.map(\.measurement.exactWatts),
            sinkWatts: presentation.sinks.map(\.measurement.exactWatts)
        )

        let labeledNodes: [PowerFlowDiagramNode]
        switch layout.effectiveMode {
        case .expanded(.oneToOne), .expanded(.oneToMany):
            labeledNodes = presentation.sinks
        case .expanded(.manyToOne):
            labeledNodes = presentation.sources
        case .expanded(.manyToMany):
            labeledNodes = presentation.sources + presentation.sinks
        case .waiting, .idle, .unavailable, .grouped:
            labeledNodes = []
        }
        flowLabels = labeledNodes.compactMap { node in
            Self.branchPowerText(node).map {
                PowerFlowDiagramFlowLabel(nodeID: node.id, text: $0)
            }
        }
        let totalNode: PowerFlowDiagramNode?
        switch layout.effectiveMode {
        case .expanded(.oneToMany): totalNode = presentation.sources.first
        case .expanded(.manyToOne): totalNode = presentation.sinks.first
        default: totalNode = nil
        }
        if let node = totalNode, !node.isSynthetic, let watts = node.measurement.exactWatts {
            endpointPowerLabels[node.id] = watts >= 1
                ? "\(watts.formatted(.number.locale(AppLocalization.currentLocale()).precision(.fractionLength(0))))W"
                : Self.powerText(node.measurement, provenance: node.provenance)
        }
        qualityText = presentation.issues.isEmpty
            ? nil
            : AppLocalization.string(.powerFlowPartialData)
    }

    static func powerText(
        _ measurement: PowerFlowDisplayMeasurement,
        provenance: PowerFlowDisplayProvenance
    ) -> String? {
        PowerFlowPresentation.diagramPowerText(
            measurement, provenance: provenance, locale: AppLocalization.currentLocale()
        )
    }

    private static func branchPowerText(_ node: PowerFlowDiagramNode) -> String? {
        if let watts = node.measurement.exactWatts, watts >= 1 {
            return "\(watts.formatted(.number.locale(AppLocalization.currentLocale()).precision(.fractionLength(2)))) W"
        }
        return powerText(node.measurement, provenance: node.provenance)
    }
}

enum PowerFlowDiagramMotion {
    // 127 timestamped AlDente frames over 10 seconds: repetition ~3.60 s.
    static let glowCycleDuration: TimeInterval = 3.6
    static let restingPhase: CGFloat = 2.1 / 3.6

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: DashboardMotion.valueDuration)
    }

    static func shouldAnimate(
        mode: PowerFlowDiagramMode, isVisible: Bool, reduceMotion: Bool, hasKnownFlow: Bool = true
    ) -> Bool {
        isVisible && !reduceMotion && hasKnownFlow && mode.showsFlowGlow
    }

    static func glowPhase(at date: Date) -> CGFloat {
        let elapsed = date.timeIntervalSinceReferenceDate
        let wrapped = elapsed.truncatingRemainder(dividingBy: glowCycleDuration)
        return CGFloat((wrapped + glowCycleDuration).truncatingRemainder(dividingBy: glowCycleDuration)
            / glowCycleDuration)
    }

    struct Pulse {
        var head: CGFloat
        var opacity: Double
        var blueMix: Double
        var sourceStrength: Double
        var sinkStrength: Double
    }

    static func pulse(at phase: CGFloat) -> Pulse {
        let time = Double(phase) * glowCycleDuration
        return Pulse(
            head: CGFloat(ramp(time, from: 0.4, to: 2.2) * 1.12),
            opacity: ramp(time, from: 0.55, to: 0.75)
                * pow(1 - ramp(time, from: 2.1, to: 3.1), 1.5),
            blueMix: 1 - pow(1 - ramp(time, from: 1.2, to: 2.1), 2),
            sourceStrength: ramp(time, from: 0, to: 0.28)
                * pow(1 - ramp(time, from: 0.58, to: 1.35), 2),
            sinkStrength: ramp(time, from: 2.2, to: 2.42)
                * (1 - smoothstep(time, from: 2.7, to: 3.45))
        )
    }

    private static func ramp(_ time: Double, from start: Double, to end: Double) -> Double {
        min(1, max(0, (time - start) / (end - start)))
    }

    private static func smoothstep(_ time: Double, from start: Double, to end: Double) -> Double {
        let value = ramp(time, from: start, to: end)
        return value * value * (3 - 2 * value)
    }
}

enum PowerFlowDiagramPalette {
    static func symbol(for kind: PowerFlowDiagramNodeKind, charging: Bool = false) -> String {
        switch kind {
        case .externalPower: return "bolt.fill"
        case .battery: return charging ? "battery.100.bolt" : "battery.100"
        case .mac: return "laptopcomputer"
        case .other: return "ellipsis"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct PowerFlowDiagramSizingLayout: Layout {
    let presentation: PowerFlowDiagramPresentation

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? PowerFlowDiagramLayout.referenceWidth
        let mode = PowerFlowDiagramLayout.effectiveMode(preferredMode: presentation.preferredMode, width: width)
        return CGSize(width: width, height: PowerFlowDiagramLayout.height(
            for: mode, sourceCount: presentation.sources.count, sinkCount: presentation.sinks.count
        ))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(bounds.size))
    }
}

struct PowerFlowDiagramView: View {
    let presentation: PowerFlowDiagramPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dashboardPresentationIsPresented) private var dashboardIsPresented

    var body: some View {
        PowerFlowDiagramSizingLayout(presentation: presentation) {
            GeometryReader { proxy in
                let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: proxy.size.width)
                animatedPanel(plan: plan)
                    .frame(width: plan.layout.cardFrame.width, height: plan.layout.cardFrame.height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(PowerFlowDiagramHelp.combinedAccessibilityLabel(presentation)))
        .help(PowerFlowPresentation.statusText(presentation.status))
        .animation(PowerFlowDiagramMotion.animation(reduceMotion: reduceMotion), value: presentation)
    }

    @ViewBuilder
    private func animatedPanel(plan: PowerFlowDiagramRenderPlan) -> some View {
        if PowerFlowDiagramMotion.shouldAnimate(
            mode: plan.layout.effectiveMode,
            isVisible: dashboardIsPresented,
            reduceMotion: reduceMotion,
            hasKnownFlow: PowerFlowDiagramActivity.hasKnownFlow(presentation)
        ) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                panel(plan: plan, phase: PowerFlowDiagramMotion.glowPhase(at: context.date))
            }
        } else {
            panel(plan: plan, phase: PowerFlowDiagramMotion.restingPhase)
        }
    }

    func panel(plan: PowerFlowDiagramRenderPlan, phase: CGFloat) -> some View {
        PowerFlowDiagramGlassSurface(
            layout: plan.layout,
            isFlowing: plan.layout.effectiveMode.showsFlowGlow && PowerFlowDiagramActivity.hasKnownFlow(presentation)
        ) {
            flowLayer(plan: plan, phase: phase)
        } content: {
            content(plan: plan, phase: phase)
        }
    }

    @ViewBuilder
    func flowLayer(plan: PowerFlowDiagramRenderPlan, phase: CGFloat) -> some View {
        if case .expanded = plan.layout.effectiveMode {
            PowerFlowDiagramRibbonLayer(presentation: presentation, layout: plan.layout, phase: phase)
        } else if plan.layout.effectiveMode == .grouped,
                  PowerFlowDiagramActivity.hasKnownFlow(presentation) {
            PowerFlowDiagramGlow(middle: plan.layout.middleSegment, phase: phase,
                                 tint: PowerFlowDiagramPalette.neutral,
                                 sourceTint: PowerFlowDiagramPalette.neutral)
        }
    }

    private func activePhase(_ phase: CGFloat) -> CGFloat? {
        PowerFlowDiagramActivity.hasKnownFlow(presentation) ? phase : nil
    }

    @ViewBuilder
    private func content(plan: PowerFlowDiagramRenderPlan, phase: CGFloat) -> some View {
        switch plan.layout.effectiveMode {
        case .expanded:
            expandedContent(plan: plan, phase: phase)
        case .grouped:
            groupedContent(plan: plan, phase: phase)
        case .waiting:
            terminalContent(status: .waiting, middle: plan.layout.middleSegment)
        case .unavailable:
            terminalContent(status: .unavailable, middle: plan.layout.middleSegment)
        case .idle:
            terminalContent(status: .idle, middle: plan.layout.middleSegment)
        }
    }

    private func expandedContent(plan: PowerFlowDiagramRenderPlan, phase: CGFloat) -> some View {
        Group {
            ForEach(Array(zip(presentation.sources, plan.layout.sourceFrames)), id: \.0.id) { node, frame in
                PowerFlowDiagramNodeLane(node: node, phase: activePhase(phase), edge: .leading,
                                         powerText: plan.endpointPowerLabels[node.id])
                    .diagramFrame(frame)
            }
            ForEach(Array(zip(presentation.sinks, plan.layout.sinkFrames)), id: \.0.id) { node, frame in
                PowerFlowDiagramNodeLane(node: node, phase: activePhase(phase), edge: .trailing,
                                         powerText: plan.endpointPowerLabels[node.id])
                    .diagramFrame(frame)
            }
            ForEach(Array(zip(plan.flowLabels, plan.layout.flowLabelFrames)), id: \.0.id) { label, frame in
                PowerFlowDiagramWattLabel(text: label.text)
                    .diagramFrame(frame)
                    .help(labelHelp(plan: plan, label: label))
            }
            if plan.showsExpandedTotalsFooter, let footer = plan.layout.totalsFooterFrame {
                PowerFlowDiagramExpandedTotalsFooter(
                    totals: plan.totalsText,
                    quality: plan.qualityText
                )
                .diagramFrame(footer)
            } else if let quality = plan.qualityText {
                PowerFlowDiagramQualityNote(text: quality)
                    .diagramFrame(qualityFrame(plan.layout.middleSegment))
            }
        }
    }

    private func labelHelp(plan: PowerFlowDiagramRenderPlan, label: PowerFlowDiagramFlowLabel) -> String {
        guard let node = labelOwner(plan: plan, label: label) else { return label.text }
        return PowerFlowDiagramHelp.node(node)
    }

    private func labelOwner(
        plan: PowerFlowDiagramRenderPlan,
        label: PowerFlowDiagramFlowLabel
    ) -> PowerFlowDiagramNode? {
        switch plan.layout.effectiveMode {
        case .expanded(.oneToOne), .expanded(.oneToMany):
            return presentation.sinks.first { $0.id == label.nodeID }
        case .expanded(.manyToOne), .expanded(.manyToMany):
            return (presentation.sources + presentation.sinks).first { $0.id == label.nodeID }
        default:
            return nil
        }
    }

    private func groupedContent(plan: PowerFlowDiagramRenderPlan, phase: CGFloat) -> some View {
        Group {
            if let source = plan.layout.groupedSourceFrame,
               let center = plan.layout.groupedCenterFrame,
               let sink = plan.layout.groupedSinkFrame {
                PowerFlowDiagramSideSummaryView(
                    summary: presentation.sourceSummary, countKey: .powerFlowSourcesCount,
                    edge: .leading, phase: activePhase(phase)
                )
                .diagramFrame(source)
                PowerFlowDiagramSideSummaryView(
                    summary: presentation.sinkSummary, countKey: .powerFlowOutputsCount,
                    edge: .trailing, phase: activePhase(phase)
                )
                .diagramFrame(sink)
                PowerFlowDiagramTotalsView(
                    input: plan.sourceTotalText,
                    output: plan.sinkTotalText,
                    quality: plan.qualityText
                )
                .diagramFrame(center)
            }
        }
    }

    private func terminalContent(status: PowerFlowDiagramStatus, middle: CGRect) -> some View {
        Group {
            if status == .idle, !presentation.idleEndpoints.isEmpty {
                PowerFlowDiagramIdleContext(nodes: presentation.idleEndpoints)
                    .diagramFrame(middle.insetBy(dx: 6, dy: 6))
            } else {
                let text = PowerFlowPresentation.statusText(status)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .help(text)
                    .diagramFrame(middle.insetBy(dx: 6, dy: 6))
            }
        }
    }
}

extension PowerFlowDiagramMode {
    /// Terminal/idle/unavailable states must not imply an active flow.
    var showsFlowGlow: Bool {
        switch self {
        case .expanded, .grouped: return true
        case .waiting, .idle, .unavailable: return false
        }
    }
}

private extension View {
    func diagramFrame(_ frame: CGRect) -> some View {
        self.frame(width: max(0, frame.width), height: max(0, frame.height))
            .position(x: frame.midX, y: frame.midY)
    }
}

private func qualityFrame(_ middle: CGRect) -> CGRect {
    CGRect(
        x: middle.minX + 4,
        y: middle.maxY - 15,
        width: max(0, middle.width - 8),
        height: 13
    )
}

// MARK: - Segmented shape

/// Three subpaths — left round-capped piece, middle rectangle, right
/// round-capped piece — so the separators stay transparent and both the
/// content and the chrome can be cut by the same silhouette.
struct PowerFlowDiagramSegmentedShape: Shape {
    var source: CGRect
    var middle: CGRect
    var sink: CGRect
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        addLeadingPiece(&path, rect: source)
        path.addRect(middle)
        addTrailingPiece(&path, rect: sink)
        return path
    }

    private func cornerRadius(for rect: CGRect) -> CGFloat {
        max(0, min(radius, min(rect.width, rect.height) / 2))
    }

    private func addLeadingPiece(_ path: inout Path, rect: CGRect) {
        let r = cornerRadius(for: rect)
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - r),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + r, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
    }

    private func addTrailingPiece(_ path: inout Path, rect: CGRect) {
        let r = cornerRadius(for: rect)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + r),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
    }
}

// MARK: - Glow

/// A soft leading edge travels right while its gradient tail grows from the
/// source. The same wash changes yellow → blue, then fades at the destination.
/// Clip after blurring so neither transparent separator receives any color.
struct PowerFlowDiagramGlow: View {
    let middle: CGRect
    var phase: CGFloat = PowerFlowDiagramMotion.restingPhase
    var tint: Color = PowerFlowDiagramGlowStyle.tint
    var sourceTint: Color = PowerFlowDiagramGlowStyle.sourceTint

    var body: some View {
        let pulse = PowerFlowDiagramMotion.pulse(at: phase)
        // Draw at the reference middle-piece aspect ratio, then stretch only
        // horizontally. This keeps the soft leading edge proportional to the
        // track width without making its top/bottom blur deeper on wide cards.
        let drawingWidth = max(1, middle.height * (320.0 / 150.0))
        let width = max(0, drawingWidth * pulse.head)
        Rectangle()
            .fill(tint)
            .overlay {
                Rectangle()
                    .fill(sourceTint)
                    .opacity(1 - pulse.blueMix)
            }
            .compositingGroup()
            .mask(LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: middle.height)
            .blur(radius: middle.height * 0.10)
            .scaleEffect(x: middle.width / drawingWidth, y: 1, anchor: .leading)
            .position(x: middle.minX + width / 2, y: middle.midY)
            .opacity(PowerFlowDiagramGlowStyle.coreOpacity * pulse.opacity)
            .mask {
                Rectangle()
                    .frame(width: middle.width, height: middle.height)
                    .position(x: middle.midX, y: middle.midY)
            }
            .accessibilityHidden(true)
    }
}

enum PowerFlowDiagramGlowStyle {
    // Endpoint colors and the middle wash share the observed yellow/blue pair.
    static let sourceTint = Color(red: 0.98, green: 0.85, blue: 0.44)
    static let tint = Color(red: 0.43, green: 0.63, blue: 0.97)
    static let coreOpacity: Double = 0.90
}

// MARK: - Node icons

/// Full-lane hit region so hover help can explain the endpoint, not just a number.
struct PowerFlowDiagramNodeLane: View {
    let node: PowerFlowDiagramNode
    var phase: CGFloat? = nil
    var edge: PowerFlowDiagramSideEdge? = nil
    var powerText: String? = nil

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            VStack(spacing: 3) {
                PowerFlowDiagramNodeIcon(node: node, phase: phase, edge: edge)
                if let powerText {
                    Text(powerText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            }
        }
        .help(PowerFlowDiagramHelp.node(node))
    }
}

struct PowerFlowDiagramNodeIcon: View {
    let node: PowerFlowDiagramNode
    var phase: CGFloat? = nil
    var edge: PowerFlowDiagramSideEdge? = nil
    /// Grouped representative rows use a smaller glyph but keep the same
    /// measurement-aware cue policy.
    var compact = false

    var body: some View {
        if compact, isUnavailable {
            // Grouped representative rows stack with spacing 0, so the dashed
            // cue must occupy real layout height. The previous offset drew it
            // past the glyph box and into the next row. Laying the cue out as a
            // sibling under the glyph reserves the exact footprint.
            VStack(spacing: Self.compactCueGap) {
                glyph
                PowerFlowDiagramUnavailableCue(width: 8)
            }
        } else {
            ZStack {
                glyph
                if isUnavailable {
                    PowerFlowDiagramUnavailableCue(width: 12)
                        .offset(y: iconSize.height / 2 + 4)
                }
            }
        }
    }

    private var glyph: some View {
        ZStack {
            glyphImage
                .foregroundStyle(isUnavailable
                    ? AnyShapeStyle(.secondary)
                    : AnyShapeStyle(PowerFlowDiagramIconStyle.color))
            if PowerFlowDiagramActivity.isKnownActive(node), let phase, let edge {
                let pulse = PowerFlowDiagramMotion.pulse(at: phase)
                glyphImage
                    .foregroundStyle(PowerFlowDiagramPalette.color(for: node.kind))
                    .opacity(edge == .leading ? pulse.sourceStrength : pulse.sinkStrength)
            }
        }
        .accessibilityHidden(true)
    }

    private var glyphImage: some View {
        Image(systemName: PowerFlowDiagramPalette.symbol(for: node.kind, charging: node.kind == .battery && edge == .trailing))
            .resizable()
            .scaledToFit()
            .fontWeight(.regular)
            .frame(width: iconSize.width, height: iconSize.height)
    }

    /// Gap between the compact glyph and its dashed cue. Matches the former
    /// offset geometry (glyph half-height + 4 pt to the cue centre, minus the
    /// cue's 0.5 pt half-height).
    private static let compactCueGap: CGFloat = 3.5

    private var isUnavailable: Bool {
        node.measurement == .unavailable
    }

    private var iconSize: CGSize {
        let base = PowerFlowDiagramIconStyle.baseSize(for: node.kind)
        guard compact else { return base }
        return CGSize(width: max(1, base.width * 0.7), height: max(1, base.height * 0.7))
    }
}

/// Short dashed underline — the only cue an endpoint has no reading. Never an
/// ordinary tile border and never a fabricated value.
struct PowerFlowDiagramUnavailableCue: View {
    var width: CGFloat = 12

    var body: some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: width, y: 0))
        }
        .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        .foregroundStyle(.tertiary)
        .frame(width: width, height: 1)
        .accessibilityHidden(true)
    }
}

enum PowerFlowDiagramIconStyle {
    static let color = Color.primary.opacity(0.72)

    /// Compact visible ink targets: lightning bolt ~9x15 pt, laptop ~18x11 pt.
    static func baseSize(for kind: PowerFlowDiagramNodeKind) -> CGSize {
        switch kind {
        case .externalPower: return CGSize(width: 9, height: 15)
        case .mac: return CGSize(width: 18, height: 11)
        case .battery: return CGSize(width: 14, height: 9)
        case .unknown: return CGSize(width: 12, height: 12)
        case .other: return CGSize(width: 12, height: 12)
        }
    }
}

// MARK: - Watt readout

enum PowerFlowDiagramTextStyle {
    /// Photo reference charcoal, not pure system ink.
    static func primary(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.92)
            : Color(red: 0x30 / 255, green: 0x30 / 255, blue: 0x38 / 255)
    }
}

struct PowerFlowDiagramWattLabel: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(PowerFlowDiagramTextStyle.primary(for: colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
    }
}

struct PowerFlowDiagramQualityNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .help(text)
    }
}

// MARK: - Expanded totals footer

/// Compact two-labelled In/Out footer shown for partial or unbalanced expanded
/// data. Reuses the localized `powerFlowTotals` format and the quality string.
struct PowerFlowDiagramExpandedTotalsFooter: View {
    let totals: String?
    let quality: String?

    var body: some View {
        VStack(spacing: 0) {
            if let totals {
                Text(totals)
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help(totals)
            }
            if let quality {
                Text(quality)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help(quality)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Idle context

struct PowerFlowDiagramIdleContext: View {
    let nodes: [PowerFlowDiagramNode]

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 12) {
                ForEach(nodes) { node in
                    PowerFlowDiagramNodeIcon(node: node)
                        .opacity(0.55)
                        .help(PowerFlowDiagramHelp.node(node))
                }
            }
            Text(PowerFlowPresentation.statusText(.idle))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help(PowerFlowPresentation.statusText(.idle))
        }
    }
}

// MARK: - Grouped

struct PowerFlowDiagramTotalsView: View {
    let input: String?
    let output: String?
    let quality: String?

    var body: some View {
        VStack(spacing: 1) {
            PowerFlowDiagramTotalsRow(title: .powerFlowInput, value: input)
            PowerFlowDiagramTotalsRow(title: .powerFlowOutput, value: output)
            if let quality {
                Text(quality)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .help(quality)
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct PowerFlowDiagramTotalsRow: View {
    let title: AppLocalization.Key
    let value: String?

    var body: some View {
        let title = AppLocalization.string(title)
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .help(title)
            if let value {
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
    }
}

enum PowerFlowDiagramSideEdge {
    case leading
    case trailing
}

struct PowerFlowDiagramSideSummaryView: View {
    let summary: PowerFlowDiagramSideSummary
    let countKey: AppLocalization.Key
    var edge: PowerFlowDiagramSideEdge = .leading
    var phase: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let count = AppLocalization.string(countKey, Int64(summary.memberCount))
            Text(count)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .help(count)
            ForEach(summary.representatives) { node in
                representativeRow(node)
            }
            bottomRow
        }
        .padding(.top, 8)
        .padding(.leading, edge == .leading ? 8 : 4)
        .padding(.trailing, edge == .trailing ? 8 : 4)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func representativeRow(_ node: PowerFlowDiagramNode) -> some View {
        HStack(spacing: 3) {
            PowerFlowDiagramNodeIcon(node: node, phase: phase, edge: edge, compact: true)
                .accessibilityHidden(true)
            Text(node.title)
                .font(.system(size: 9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if let value = PowerFlowDiagramRenderPlan.powerText(node.measurement, provenance: node.provenance) {
                Text(value)
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        // Same node-aware cue/help as the expanded lanes: unavailable and
        // synthetic representatives are never rendered as a bare glyph.
        .help(PowerFlowDiagramHelp.node(node))
    }

    private var bottomRow: some View {
        HStack(spacing: 3) {
            if let total = PowerFlowDiagramRenderPlan.powerText(summary.total, provenance: summary.provenance) {
                Text(total)
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            let hidden = summary.memberCount - summary.representatives.count
            if hidden > 0 {
                let more = AppLocalization.string(.powerFlowMoreCount, Int64(hidden))
                Text(more)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help(more)
            }
        }
    }
}
