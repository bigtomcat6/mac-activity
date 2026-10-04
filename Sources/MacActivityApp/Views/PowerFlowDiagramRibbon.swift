import SwiftUI

/// The two boundaries use the same control-X values. Their tangent is
/// horizontal at both ends, including where adjacent halves meet a shared bus.
struct PowerFlowRibbonShape: Shape {
    var geometry: PowerFlowRibbonGeometry

    func path(in rect: CGRect) -> Path {
        let g = geometry
        let startHalf = max(0, g.startHeight / 2)
        let endHalf = max(0, g.endHeight / 2)
        let dx = (g.endX - g.startX) * 0.5
        var path = Path()
        path.move(to: CGPoint(x: g.startX, y: g.startCenterY - startHalf))
        path.addCurve(
            to: CGPoint(x: g.endX, y: g.endCenterY - endHalf),
            control1: CGPoint(x: g.startX + dx, y: g.startCenterY - startHalf),
            control2: CGPoint(x: g.endX - dx, y: g.endCenterY - endHalf)
        )
        path.addLine(to: CGPoint(x: g.endX, y: g.endCenterY + endHalf))
        path.addCurve(
            to: CGPoint(x: g.startX, y: g.startCenterY + startHalf),
            control1: CGPoint(x: g.endX - dx, y: g.endCenterY + endHalf),
            control2: CGPoint(x: g.startX + dx, y: g.startCenterY + startHalf)
        )
        path.closeSubpath()
        return path
    }
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
                    radius: min(layout.outerCornerRadius, frame.height * 0.28)
                ).path(in: rect))
            }
            for frame in layout.sinkFrames {
                path.addPath(PowerFlowDiagramSegmentedShape(
                    source: .zero, middle: .zero, sink: frame,
                    radius: min(layout.outerCornerRadius, frame.height * 0.28)
                ).path(in: rect))
            }
        }
        if includesChannel {
            for ribbon in layout.ribbons {
                path.addPath(PowerFlowRibbonShape(geometry: ribbon).path(in: rect))
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
                    Color.clear.glassEffect(.clear, in: channel)
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
        let union = Path { path in
            for ribbon in layout.ribbons {
                path.addPath(PowerFlowRibbonShape(geometry: ribbon).path(in: layout.cardFrame))
            }
        }
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.ribbons.enumerated()), id: \.offset) { _, ribbon in
                let shape = PowerFlowRibbonShape(geometry: ribbon)
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
