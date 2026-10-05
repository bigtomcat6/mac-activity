import SwiftUI

/// Trimmed cubic boundaries with tangent-continuous exposed caps. Internal bus
/// joins retain their full, flat boundary and the original horizontal tangent.
struct PowerFlowRibbonShape: Shape {
    var geometry: PowerFlowRibbonGeometry
    var startRadius: CGFloat = 0
    var endRadius: CGFloat = 0

    init(geometry: PowerFlowRibbonGeometry, startRadius: CGFloat = 0, endRadius: CGFloat = 0) {
        self.geometry = geometry
        self.startRadius = startRadius
        self.endRadius = endRadius
    }

    /// All glass and light callers use this same exposed endpoint policy.
    init(geometry: PowerFlowRibbonGeometry, layout: PowerFlowDiagramLayoutResult) {
        self.geometry = geometry
        // The 1→1 channel already owns its rounded module outline; leave its
        // underlying light track unchanged (the surface clips it afterward).
        let radius: CGFloat = geometry.role == .direct ? 0 : layout.outerCornerRadius
        startRadius = geometry.startX == layout.middleSegment.minX ? radius : 0
        endRadius = geometry.endX == layout.middleSegment.maxX ? radius : 0
    }

    func path(in rect: CGRect) -> Path {
        let g = geometry
        let startHalf = max(0, g.startHeight / 2)
        let endHalf = max(0, g.endHeight / 2)
        let width = g.endX - g.startX
        guard width > 0, startHalf > 0, endHalf > 0 else { return Path() }
        let (start, end, a, b) = cuts
        var path = Path()
        let top = boundary(from: g.startCenterY - startHalf, to: g.endCenterY - endHalf, a: a, b: b)
        let bottom = boundary(from: g.startCenterY + startHalf, to: g.endCenterY + endHalf, a: a, b: b)
        path.move(to: CGPoint(x: g.startX, y: g.startCenterY - startHalf + start))
        path.addQuadCurve(to: top.start, control: top.leading)
        path.addCurve(to: top.end, control1: top.control1, control2: top.control2)
        path.addQuadCurve(to: CGPoint(x: g.endX, y: g.endCenterY - endHalf + end), control: top.trailing)
        path.addLine(to: CGPoint(x: g.endX, y: g.endCenterY + endHalf - end))
        path.addQuadCurve(to: bottom.end, control: bottom.trailing)
        path.addCurve(to: bottom.start, control1: bottom.control2, control2: bottom.control1)
        path.addQuadCurve(to: CGPoint(x: g.startX, y: g.startCenterY + startHalf - start), control: bottom.leading)
        path.closeSubpath()
        return path
    }

    fileprivate var cuts: (start: CGFloat, end: CGFloat, a: CGFloat, b: CGFloat) {
        let g = geometry, width = g.endX - g.startX
        let startHalf = max(0, g.startHeight / 2), endHalf = max(0, g.endHeight / 2)
        let start = max(0, min(startRadius, startHalf, endHalf, width / 4))
        let end = max(0, min(endRadius, startHalf, endHalf, width / 4))
        // Trim the original cubic, not a replacement centreline/stroked tube.
        // Endpoint derivative is 1.5 * width; these conservative parameter cuts
        // cannot cross even on a short band with an oversized requested radius.
        // On a very short bent band, also bound the vertical departure from
        // each endpoint so the tangent intersection cannot pull a cap outside.
        let bend = max(1, abs(g.endCenterY - g.startCenterY) + abs(endHalf - startHalf))
        let a = min(start / (1.5 * width), sqrt(start / bend) / 4)
        let b = 1 - min(end / (1.5 * width), sqrt(end / bend) / 4)
        return (start, end, a, b)
    }

    fileprivate func boundary(from y0: CGFloat, to y1: CGFloat, a: CGFloat, b: CGFloat)
        -> (start: CGPoint, end: CGPoint, control1: CGPoint, control2: CGPoint, leading: CGPoint, trailing: CGPoint) {
        let width = geometry.endX - geometry.startX
        func point(_ t: CGFloat) -> CGPoint {
            CGPoint(x: geometry.startX + width * (1.5 * t - 1.5 * t * t + t * t * t),
                    y: y0 + (y1 - y0) * t * t * (3 - 2 * t))
        }
        func tangent(_ t: CGFloat) -> CGPoint {
            CGPoint(x: width * (1.5 - 3 * t + 3 * t * t), y: (y1 - y0) * 6 * t * (1 - t))
        }
        let p = point(a), q = point(b), u = tangent(a), v = tangent(b)
        let span = (b - a) / 3
        return (p, q, CGPoint(x: p.x + u.x * span, y: p.y + u.y * span),
                CGPoint(x: q.x - v.x * span, y: q.y - v.y * span),
                CGPoint(x: geometry.startX, y: p.y + (geometry.startX - p.x) * u.y / u.x),
                CGPoint(x: geometry.endX, y: q.y + (geometry.endX - q.x) * v.y / v.x))
    }
}

/// Walk only the exposed bus perimeter. Internal cut faces are not contours.
/// The two open notches end in small G1 fillets, not independently capped joins.
private func busChannelPath(_ layout: PowerFlowDiagramLayoutResult) -> Path {
    let sources = layout.ribbons.filter { if case .source = $0.role { return true }; return false }
    let sinks = layout.ribbons.filter { if case .sink = $0.role { return true }; return false }
    guard let bus = layout.busFrame, !sources.isEmpty, !sinks.isEmpty else { return Path() }
    typealias Boundary = (start: CGPoint, end: CGPoint, control1: CGPoint, control2: CGPoint, leading: CGPoint, trailing: CGPoint)
    func edge(_ g: PowerFlowRibbonGeometry, top: Bool, a: CGFloat, b: CGFloat) -> Boundary {
        let sign: CGFloat = top ? -1 : 1
        return PowerFlowRibbonShape(geometry: g).boundary(
            from: g.startCenterY + sign * g.startHeight / 2,
            to: g.endCenterY + sign * g.endHeight / 2, a: a, b: b)
    }
    // Solve a finite gap on the original cubics. Half this gap is the local
    // fillet's nominal radius, bounded by adjacent thickness and available run.
    // At most 1/12 of the open gap is closed here; never apply the outer 21pt.
    func notchCut(_ upper: PowerFlowRibbonGeometry, _ lower: PowerFlowRibbonGeometry, source: Bool) -> CGFloat {
        let gap = source
            ? lower.startCenterY - lower.startHeight / 2 - upper.startCenterY - upper.startHeight / 2
            : lower.endCenterY - lower.endHeight / 2 - upper.endCenterY - upper.endHeight / 2
        guard gap > 0 else { return source ? 1 : 0 }
        let run = min(upper.endX - upper.startX, lower.endX - lower.startX)
        let finiteGap = min(2, min(upper.startHeight, lower.startHeight) / 12, gap / 12, run / 64)
        var low: CGFloat = 0, high: CGFloat = 0.5
        for _ in 0..<32 {
            let t = (low + high) / 2
            if gap * t * t * (3 - 2 * t) < finiteGap { low = t } else { high = t }
        }
        return source ? 1 - (low + high) / 2 : (low + high) / 2
    }
    func append(_ edge: Boundary, to path: inout Path, reverse: Bool = false) {
        path.addCurve(to: reverse ? edge.start : edge.end,
                      control1: reverse ? edge.control2 : edge.control1,
                      control2: reverse ? edge.control1 : edge.control2)
    }
    func fillet(from p: CGPoint, tangent u: CGPoint, to q: CGPoint, tangent v: CGPoint, path: inout Path) {
        // A single cubic semicircular turn. Nonzero opposing horizontal handles
        // match the original tangent slopes; the tip has a vertical derivative.
        let gap = abs(q.y - p.y)
        let slope = max(abs(u.y / u.x), abs(v.y / v.x))
        let joinX = u.x > 0 ? bus.minX : bus.maxX
        // Very short, steep bands need shorter handles so the cap stays within
        // the gap and before the bus; positive handles still preserve G1.
        let handle = min(gap * 2 / 3, gap / (3 * max(0.000001, slope)), abs(joinX - p.x) / 2)
        path.addCurve(to: q,
            control1: CGPoint(x: p.x + handle * (u.x > 0 ? 1 : -1), y: p.y + handle * u.y / abs(u.x)),
            control2: CGPoint(x: q.x - handle * (v.x > 0 ? 1 : -1), y: q.y - handle * v.y / abs(v.x)))
    }
    var path = Path()
    let first = sources[0], firstShape = PowerFlowRibbonShape(geometry: first, layout: layout)
    let firstTop = edge(first, top: true, a: firstShape.cuts.a, b: 1)
    path.move(to: CGPoint(x: first.startX, y: first.startCenterY - first.startHeight / 2 + firstShape.cuts.start))
    path.addQuadCurve(to: firstTop.start, control: firstTop.leading)
    append(firstTop, to: &path)
    path.addLine(to: CGPoint(x: bus.maxX, y: bus.minY))
    for i in sinks.indices {
        let g = sinks[i], shape = PowerFlowRibbonShape(geometry: g, layout: layout)
        let a = i == 0 ? 0 : notchCut(sinks[i - 1], g, source: false)
        let bottomA = i == sinks.count - 1 ? 0 : notchCut(g, sinks[i + 1], source: false)
        let top = edge(g, top: true, a: a, b: shape.cuts.b)
        let bottom = edge(g, top: false, a: bottomA, b: shape.cuts.b)
        append(top, to: &path)
        path.addQuadCurve(to: CGPoint(x: g.endX, y: g.endCenterY - g.endHeight / 2 + shape.cuts.end), control: top.trailing)
        path.addLine(to: CGPoint(x: g.endX, y: g.endCenterY + g.endHeight / 2 - shape.cuts.end))
        path.addQuadCurve(to: bottom.end, control: bottom.trailing)
        append(bottom, to: &path, reverse: true)
        if i < sinks.count - 1 {
            let next = edge(sinks[i + 1], top: true, a: bottomA, b: 1)
            fillet(from: bottom.start,
                tangent: CGPoint(x: bottom.start.x - bottom.control1.x, y: bottom.start.y - bottom.control1.y),
                to: next.start, tangent: CGPoint(x: next.control1.x - next.start.x, y: next.control1.y - next.start.y), path: &path)
        }
    }
    path.addLine(to: CGPoint(x: bus.minX, y: bus.maxY))
    for i in sources.indices.reversed() {
        let g = sources[i], shape = PowerFlowRibbonShape(geometry: g, layout: layout)
        let bottomB = i == sources.count - 1 ? 1 : notchCut(g, sources[i + 1], source: true)
        let topB = i == 0 ? 1 : notchCut(sources[i - 1], g, source: true)
        let bottom = edge(g, top: false, a: shape.cuts.a, b: bottomB)
        let top = edge(g, top: true, a: shape.cuts.a, b: topB)
        append(bottom, to: &path, reverse: true)
        path.addQuadCurve(to: CGPoint(x: g.startX, y: g.startCenterY + g.startHeight / 2 - shape.cuts.start), control: bottom.leading)
        if i == 0 {
            path.closeSubpath()
        } else {
            path.addLine(to: CGPoint(x: g.startX, y: g.startCenterY - g.startHeight / 2 + shape.cuts.start))
            path.addQuadCurve(to: top.start, control: top.leading)
            append(top, to: &path)
            let previous = edge(sources[i - 1], top: false, a: 0, b: topB)
            fillet(from: top.end,
                tangent: CGPoint(x: top.end.x - top.control2.x, y: top.end.y - top.control2.y),
                to: previous.end, tangent: CGPoint(x: previous.control2.x - previous.end.x, y: previous.control2.y - previous.end.y), path: &path)
        }
    }
    return path
}

/// The glass follows the actual branches; gaps reveal the dashboard backdrop.
/// `endpoints` and `channel` split the same silhouette so each can use its own glass.
struct PowerFlowDiagramSurfaceShape: Shape {
    enum Part {
        case all
        case endpoints
        case channel
    }

    var layout: PowerFlowDiagramLayoutResult
    var part: Part = .all

    func path(in rect: CGRect) -> Path {
        let includesEndpoints = part != .channel
        let includesChannel = part != .endpoints
        guard case .expanded(let topology) = layout.effectiveMode, topology != .oneToOne else {
            return PowerFlowDiagramSegmentedShape(
                source: includesEndpoints ? layout.sourceSegment : .zero,
                middle: includesChannel ? layout.middleSegment : .zero,
                sink: includesEndpoints ? layout.sinkSegment : .zero,
                radius: layout.outerCornerRadius,
                // Each piece reads as its own rounded glass module; small square-ish
                // corners make the glass refraction draw hard diagonal seams.
                innerRadius: layout.outerCornerRadius
            ).path(in: rect)
        }
        var path = Path()
        if includesEndpoints {
            for frame in layout.sourceFrames {
                path.addPath(PowerFlowDiagramSegmentedShape(
                    source: frame, middle: .zero, sink: .zero,
                    radius: layout.outerCornerRadius,
                    innerRadius: layout.outerCornerRadius
                ).path(in: rect))
            }
            for frame in layout.sinkFrames {
                path.addPath(PowerFlowDiagramSegmentedShape(
                    source: .zero, middle: .zero, sink: frame,
                    radius: layout.outerCornerRadius,
                    innerRadius: layout.outerCornerRadius
                ).path(in: rect))
            }
        }
        if includesChannel {
            if topology == .manyToMany {
                path.addPath(busChannelPath(layout))
            } else {
                for ribbon in layout.ribbons {
                    path.addPath(PowerFlowRibbonShape(geometry: ribbon, layout: layout).path(in: rect))
                }
            }
            if let footer = layout.totalsFooterFrame {
                path.addRoundedRect(in: footer, cornerSize: CGSize(width: 3, height: 3))
            }
        }
        return path
    }
}

/// The diagram is its own Liquid Glass element: frosted endpoint nodes and a
/// glass channel. While power flows, the light layer sits *under* clear glass so
/// the glass refracts it like energy inside a tube. Without glass (macOS < 26 or
/// Reduce Transparency) the light is drawn over the opaque fallback surface.
struct PowerFlowDiagramGlassSurface<Light: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let layout: PowerFlowDiagramLayoutResult
    let isFlowing: Bool
    let light: Light
    let content: Content

    init(
        layout: PowerFlowDiagramLayoutResult,
        isFlowing: Bool,
        @ViewBuilder light: () -> Light,
        @ViewBuilder content: () -> Content
    ) {
        self.layout = layout
        self.isFlowing = isFlowing
        self.light = light()
        self.content = content()
    }

    var body: some View {
        let surface = PowerFlowDiagramSurfaceShape(layout: layout)
        let channel = PowerFlowDiagramSurfaceShape(layout: layout, part: .channel)
        ZStack(alignment: .topLeading) {
            if DashboardCardChrome.usesFloatingModules(reduceTransparency: reduceTransparency) {
                if isFlowing {
                    // Clear glass needs the module scrim underneath so the backdrop never
                    // shows raw; system materials cannot blur the desktop in this panel.
                    channel.fill(DashboardCardChrome.glassScrim(for: colorScheme, contrast: contrast))
                    // On the light frosted base the pastel wash (yellow above all)
                    // would wash out; deepen it there so the pulse stays visible.
                    light
                        .saturation(colorScheme == .dark ? 1 : 1.5)
                        .brightness(colorScheme == .dark ? 0 : -0.1)
                        .clipShape(channel)
                }
                Color.clear.dashboardModuleGlass(in: PowerFlowDiagramSurfaceShape(layout: layout, part: .endpoints))
                if isFlowing, #available(macOS 26.0, *) {
                    // The material base already dims the backdrop; a scrim would mute the light.
                    if layout.effectiveMode == .expanded(.oneToMany)
                        || layout.effectiveMode == .expanded(.manyToOne) {
                        // Independent glass avoids the compound channel's large end facets.
                        // Keep the original coordinates and full diagram hosts.
                        Group {
                            ForEach(Array(layout.ribbons.enumerated()), id: \.offset) { _, ribbon in
                                Color.clear.glassEffect(.clear, in: PowerFlowRibbonShape(geometry: ribbon, layout: layout))
                                    .frame(width: layout.cardFrame.width, height: layout.cardFrame.height)
                            }
                            if let footer = layout.totalsFooterFrame {
                                Color.clear.glassEffect(.clear, in: Path(roundedRect: footer, cornerRadius: 3))
                            }
                        }
                        // Do not retain outgoing branch glass over a new grouped/bus surface.
                        .transition(.identity)
                    } else {
                        Color.clear.glassEffect(.clear, in: channel)
                    }
                } else {
                    Color.clear.dashboardModuleGlass(in: channel)
                }
            } else {
                DashboardFallbackCardSurface(shape: AnyShape(surface))
                light.clipShape(channel)
            }
            content
        }
        .contentShape(surface)
        .overlay {
            // Borderless like the glass; Increase Contrast still gets an outline.
            if contrast == .increased {
                surface.stroke(
                    Color.primary.opacity(DashboardCardChrome.increasedContrastBorderOpacity),
                    lineWidth: 0.5
                )
            }
        }
    }
}

extension PowerFlowDiagramPalette {
    static let battery = Color(red: 0.27, green: 0.78, blue: 0.48)
    static let neutral = Color(red: 0.54, green: 0.63, blue: 0.71)

    static func color(for kind: PowerFlowDiagramNodeKind) -> Color {
        switch kind {
        case .externalPower: return PowerFlowDiagramGlowStyle.sourceTint
        case .battery: return battery
        case .mac: return PowerFlowDiagramGlowStyle.tint
        case .other, .unknown: return neutral
        }
    }
}

enum PowerFlowDiagramActivity {
    static func isKnownActive(_ node: PowerFlowDiagramNode) -> Bool {
        !node.isSynthetic && (node.measurement.exactWatts ?? 0) > 0
    }

    static func hasKnownFlow(_ presentation: PowerFlowDiagramPresentation) -> Bool {
        presentation.sources.contains(where: isKnownActive)
            && presentation.sinks.contains(where: isKnownActive)
    }

    static func isKnown(_ role: PowerFlowRibbonRole, in presentation: PowerFlowDiagramPresentation) -> Bool {
        switch role {
        case .source(let index): return isKnownActive(presentation.sources[index])
        case .sink(let index): return isKnownActive(presentation.sinks[index])
        case .direct, .bus: return hasKnownFlow(presentation)
        }
    }
}

struct PowerFlowDiagramRibbonLayer: View {
    let presentation: PowerFlowDiagramPresentation
    let layout: PowerFlowDiagramLayoutResult
    let phase: CGFloat

    var body: some View {
        let contributions = Path { path in
            for ribbon in layout.ribbons {
                path.addPath(PowerFlowRibbonShape(geometry: ribbon, layout: layout).path(in: layout.cardFrame))
            }
        }
        let union = layout.effectiveMode == .expanded(.manyToMany) ? busChannelPath(layout) : contributions
        let joinFill = Path { path in
            path.addPath(union)
            path.addPath(contributions)
        }
        ZStack(alignment: .topLeading) {
            if layout.effectiveMode == .expanded(.manyToMany), PowerFlowDiagramActivity.hasKnownFlow(presentation) {
                // Local notch fills share the neutral junction light, not a dark
                // patch left between the original color-contribution clips.
                PowerFlowDiagramGlow(middle: layout.middleSegment, phase: phase,
                                     tint: PowerFlowDiagramPalette.neutral, sourceTint: PowerFlowDiagramPalette.neutral)
                    // Contributions tile without overlap. Even-odd subtraction
                    // lights ONLY the newly filled notches, never doubles the
                    // normal bands or includes the separately glassed footer.
                    .clipShape(joinFill, style: FillStyle(eoFill: true, antialiased: false))
            }
            ForEach(Array(layout.ribbons.enumerated()), id: \.offset) { _, ribbon in
                let shape = PowerFlowRibbonShape(geometry: ribbon, layout: layout)
                let colors = colors(for: ribbon.role)
                let known = PowerFlowDiagramActivity.isKnown(ribbon.role, in: presentation)
                if known, PowerFlowDiagramActivity.hasKnownFlow(presentation) {
                    if ribbon.role == .direct {
                        PowerFlowDiagramGlow(middle: layout.middleSegment, phase: phase,
                                             tint: colors.end, sourceTint: colors.start)
                            .clipShape(shape, style: FillStyle(antialiased: false))
                    } else {
                        // Color is continuous at junctions: all contributions
                        // meet at the same neutral color, then each sink acquires
                        // its own color. One shared pulse supplies only alpha.
                        Rectangle()
                            .fill(LinearGradient(colors: [colors.start, colors.end],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: ribbon.bounds.width, height: layout.cardFrame.height)
                            .position(x: ribbon.bounds.midX, y: layout.cardFrame.midY)
                            .mask {
                                PowerFlowDiagramGlow(middle: layout.middleSegment, phase: phase,
                                                     tint: .white, sourceTint: .white)
                            }
                            // Shared edges tile exactly; the union below owns
                            // antialiasing and feathering of the visible outline.
                            .clipShape(shape, style: FillStyle(antialiased: false))
                    }
                } else if !known {
                    shape.stroke(Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .mask {
                            if layout.effectiveMode == .expanded(.manyToMany) {
                                union.stroke(.white, lineWidth: 2)
                            } else {
                                Rectangle().fill(.white)
                            }
                        }
                }
            }
        }
        // Feather the UNION, not separate pieces: shared boundaries must not
        // leave vertical seams or a dark line through the bus. Clip afterward
        // to keep every separator and branch gap clear.
        .mask { union.fill(.white).blur(radius: layout.ribbons.count > 1 ? 1.4 : 0) }
        .clipShape(union)
        .accessibilityHidden(true)
    }

    private func colors(for role: PowerFlowRibbonRole) -> (start: Color, end: Color) {
        let neutral = PowerFlowDiagramPalette.neutral
        let source = presentation.sources.count == 1
            ? PowerFlowDiagramPalette.color(for: presentation.sources[0].kind) : neutral
        let sink = presentation.sinks.count == 1
            ? PowerFlowDiagramPalette.color(for: presentation.sinks[0].kind) : neutral
        switch role {
        case .direct: return (source, sink)
        case .source(let index):
            let color = PowerFlowDiagramPalette.color(for: presentation.sources[index].kind)
            return (color, presentation.sources.count == 1 ? neutral : (presentation.sinks.count == 1 ? sink : neutral))
        case .sink(let index):
            let color = PowerFlowDiagramPalette.color(for: presentation.sinks[index].kind)
            return (presentation.sources.count == 1 ? source : neutral, color)
        case .bus: return (neutral, neutral)
        }
    }
}
