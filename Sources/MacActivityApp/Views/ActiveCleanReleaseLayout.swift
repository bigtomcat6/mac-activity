import SwiftUI

enum ActiveCleanReleaseLayout {
    static let trashSectionHeight: CGFloat = 103
    static let diskCleanupStripHeight: CGFloat = 44
    static let memoryStripHeight: CGFloat = diskCleanupStripHeight
    static let processRowHeight: CGFloat = ActiveProcessMemoryLayout.rowHeight
    static let processListSpacing: CGFloat = 0
    static let sectionSpacing: CGFloat = 10
}

enum DashboardCardChrome {
    static let cornerRadius: CGFloat = 18
    static let borderOpacity = 0.10
    static let hoverBorderOpacity = 0.18
    static let increasedContrastBorderOpacity = 0.55
    static let shadowRadius: CGFloat = 7
    static let shadowOffsetY: CGFloat = 3

    static func borderOpacity(isHovered: Bool) -> Double {
        isHovered ? hoverBorderOpacity : borderOpacity
    }

    // Mirrors DashboardPresentationHostKind: modules float straight on the desktop
    // only with Liquid Glass and full transparency; otherwise the popover backs them.
    static func usesFloatingModules(reduceTransparency: Bool) -> Bool {
        if #available(macOS 26.0, *) {
            return !reduceTransparency
        }
        return false
    }

    // Clear glass shows what sits behind almost raw. Dark modules get a dim that holds
    // text contrast; light glass in the key panel already renders near white, so light
    // modules get a faint shade instead of a white lift that would glare.
    static func glassScrim(for colorScheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        switch (colorScheme, contrast) {
        case (.dark, .increased): return Color.black.opacity(0.48)
        case (.dark, _): return Color.black.opacity(0.30)
        // Increase Contrast keeps the brightest module behind dark text.
        case (_, .increased): return .clear
        default: return Color.black.opacity(0.06)
        }
    }

    static let panelCornerRadius: CGFloat = 32
    // Light regular glass reads almost white over bright windows; a faint shade keeps
    // the panel from glaring. Dark glass is already dim.
    static let lightPanelShadeOpacity = 0.10

    static func panelShade(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .clear : Color.black.opacity(lightPanelShadeOpacity)
    }

    static func surfaceColor(for colorScheme: ColorScheme) -> Color {
        Color(.sRGB, white: colorScheme == .dark ? 0.20 : 0.98, opacity: 1)
    }

    static func shadowOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.20 : 0.10
    }
}

struct DashboardFallbackCardSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // The power-flow diagram passes its own silhouette; cards use the rounded default.
    var shape: AnyShape = AnyShape(
        RoundedRectangle(cornerRadius: DashboardCardChrome.cornerRadius, style: .continuous)
    )

    var body: some View {
        shape
            .fill(reduceTransparency
                ? AnyShapeStyle(DashboardCardChrome.surfaceColor(for: colorScheme))
                : AnyShapeStyle(.ultraThinMaterial))
            .shadow(
                color: .black.opacity(DashboardCardChrome.shadowOpacity(for: colorScheme)),
                radius: DashboardCardChrome.shadowRadius,
                x: 0,
                y: DashboardCardChrome.shadowOffsetY
            )
    }
}

enum DashboardHeaderChrome {
    static let horizontalPadding: CGFloat = 18
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 12
    static let titlePickerSpacing: CGFloat = 12
    static let capsuleLeadingPadding: CGFloat = 16
    static let capsuleTrailingPadding: CGFloat = 6
    static let capsuleVerticalPadding: CGFloat = 6
}

enum ActiveCleanupChrome {
    static let cornerRadius = DashboardCardChrome.cornerRadius
    static let borderOpacity = DashboardCardChrome.borderOpacity
    static let activeProgressFill = Color.accentColor.opacity(0.12)
    static let inactiveProgressFill = Color.black.opacity(0.22)

    static func progressFillColor(appearsActive: Bool) -> Color {
        appearsActive ? activeProgressFill : inactiveProgressFill
    }
}

enum ActiveProcessQuitButtonVisualStyle: Equatable {
    case bordered
    case destructiveProminent
}

enum ActiveProcessQuitButtonStyling {
    static func visualStyle(
        for state: ActiveProcessQuitConfirmationState,
        appearsActive: Bool
    ) -> ActiveProcessQuitButtonVisualStyle {
        state == .confirming && appearsActive ? .destructiveProminent : .bordered
    }
}

private struct DashboardCardChromeModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let isHovered: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DashboardCardChrome.cornerRadius, style: .continuous)
        let clippedContent = content.contentShape(shape).clipShape(shape)

        Group {
            if DashboardCardChrome.usesFloatingModules(reduceTransparency: reduceTransparency) {
                clippedContent.dashboardModuleGlass(in: shape)
            } else {
                clippedContent.background { DashboardFallbackCardSurface() }
            }
        }
        .overlay {
            shape.strokeBorder(Color.primary.opacity(resolvedBorderOpacity), lineWidth: 0.5)
        }
    }

    private var resolvedBorderOpacity: Double {
        if contrast == .increased {
            return DashboardCardChrome.increasedContrastBorderOpacity + (isHovered ? 0.10 : 0)
        }
        return DashboardCardChrome.borderOpacity(isHovered: isHovered)
    }
}

extension View {
    func dashboardCardChrome(isHovered: Bool = false) -> some View {
        modifier(DashboardCardChromeModifier(isHovered: isHovered))
    }

    // Control Center module surface; callers gate it on usesFloatingModules.
    func dashboardModuleGlass(in shape: some Shape) -> some View {
        modifier(DashboardModuleGlassModifier(shape: shape))
    }

    // The floating panel's own backdrop: one Liquid Glass slab behind the modules.
    func dashboardPanelBackdrop() -> some View {
        modifier(DashboardPanelBackdropModifier())
    }

    // Hover overlays float above the cards, which is the layer Liquid Glass is
    // meant for; older systems and Reduce Transparency keep the material bubble.
    func dashboardFloatingSurface(cornerRadius: CGFloat = 8) -> some View {
        modifier(DashboardFloatingSurfaceModifier(cornerRadius: cornerRadius))
    }

    // Icon-only actions become Control Center's round glass buttons on macOS 26.
    @ViewBuilder
    func dashboardIconButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        } else {
            buttonStyle(.borderless)
        }
    }

    // Icon-only menus match the round glass icon buttons beside them.
    @ViewBuilder
    func dashboardIconMenuStyle() -> some View {
        if #available(macOS 26.0, *) {
            menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
        } else {
            menuStyle(.borderlessButton)
        }
    }

    // Card actions use native glass buttons on macOS 26 and bordered buttons before it.
    @ViewBuilder
    func dashboardActionButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

private struct DashboardFloatingSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay { shape.stroke(Color.primary.opacity(0.08), lineWidth: 1) }
                .shadow(radius: 4, y: 2)
        }
    }
}

private struct DashboardModuleGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    shape.fill(DashboardCardChrome.glassScrim(for: colorScheme, contrast: contrast))
                }
                .glassEffect(.clear, in: shape)
        } else {
            content
        }
    }
}

private struct DashboardPanelBackdropModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background {
            // Regular glass blurs the desktop about as strongly as a HUD backdrop and
            // brings the glass rim; the clear modules above stay separate elements.
            if #available(macOS 26.0, *),
               DashboardCardChrome.usesFloatingModules(reduceTransparency: reduceTransparency) {
                let shape = RoundedRectangle(cornerRadius: DashboardCardChrome.panelCornerRadius, style: .continuous)
                shape
                    .fill(DashboardCardChrome.panelShade(for: colorScheme))
                    .glassEffect(.regular, in: shape)
                    // The slab fills the window, so its glass shadow would land in the
                    // corners outside the rounded shape and stop at the window edge.
                    .clipShape(shape)
                    .overlay {
                        if contrast == .increased {
                            shape.strokeBorder(
                                Color.primary.opacity(DashboardCardChrome.increasedContrastBorderOpacity),
                                lineWidth: 0.5
                            )
                        }
                    }
            }
        }
    }
}
