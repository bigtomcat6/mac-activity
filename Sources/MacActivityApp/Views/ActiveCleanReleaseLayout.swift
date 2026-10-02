import SwiftUI

enum ActiveCleanReleaseLayout {
    static let trashSectionHeight: CGFloat = 103
    static let diskCleanupStripHeight: CGFloat = 44
    static let memoryStripHeight: CGFloat = diskCleanupStripHeight
    static let processRowHeight: CGFloat = ActiveProcessMemoryLayout.rowHeight
    static let processListSpacing: CGFloat = 0
    static let sectionSpacing: CGFloat = 10
    static let zoneOrder = ["diskCleanup", "processes"]
}

enum DashboardCardChrome {
    static let cornerRadius: CGFloat = 12
    static let borderOpacity = 0.10
    static let hoverBorderOpacity = 0.18
    static let increasedContrastBorderOpacity = 0.55
    static let shadowRadius: CGFloat = 7
    static let shadowOffsetY: CGFloat = 3

    static func borderOpacity(isHovered: Bool) -> Double {
        isHovered ? hoverBorderOpacity : borderOpacity
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
    // Custom silhouette for the three-segment power-flow panel; defaults to the
    // shared rounded-card shape so every existing caller is unchanged.
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
    static let tabPickerMinWidth: CGFloat = 160
}

enum DashboardTabChrome {
    static let iconButtonWidth: CGFloat = 30
    static let iconButtonHeight: CGFloat = 20
    static let itemSpacing: CGFloat = 2
    static let trackPadding: CGFloat = 2
    static let trackFillOpacity: Double = 0.06
    static let selectedFillOpacity: Double = 0.12
    static let hoverFillOpacity: Double = 0.06
    static let focusRingWidth: CGFloat = 2
}

enum ActiveCleanupChrome {
    static let cornerRadius = DashboardCardChrome.cornerRadius
    static let borderOpacity = DashboardCardChrome.borderOpacity
    static let activeProgressFill = Color.accentColor.opacity(0.12)
    static let inactiveProgressFill = Color.black.opacity(0.22)

    static func progressFillColor(
        appearsActive: Bool,
        appearance: DashboardStyleAppearance = .standardAppearance
    ) -> Color {
        guard appearsActive == false else { return activeProgressFill }
        return appearance.usesTranslucentChrome
            ? DashboardOverviewChrome.translucentInactiveEmphasisFill
            : inactiveProgressFill
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
    @Environment(\.dashboardStyleAppearance) private var appearance
    let isHovered: Bool
    // nil keeps the shared rounded-card silhouette for every existing caller.
    var customShape: AnyShape? = nil
    // Panel-only native-glass tint; default shared cards pass nil and stay exact.
    var glassTint: Color? = nil
    // Non-opaque panel calibration layer above the glass, below the content.
    var glassOverlay: Color? = nil

    func body(content: Content) -> some View {
        let shape = customShape ?? AnyShape(RoundedRectangle(
            cornerRadius: appearance.moduleCornerRadius,
            style: .continuous
        ))
        let borderOpacity = resolvedBorderOpacity
        let clippedContent = content.contentShape(shape).clipShape(shape)

        Group {
            if #available(macOS 26.0, *), !reduceTransparency {
                let glass = glassTint.map { Glass.regular.tint($0) } ?? Glass.regular
                if appearance.usesRootGlass {
                    clippedContent
                        .background(shape.fill(Color.primary.opacity(appearance.moduleFillOpacity)))
                } else if customShape != nil {
                    // Panel-only custom silhouette: keep the native glass surface
                    // as a background layer so the glow and readouts sit above it
                    // and are not part of the glass foreground processing. This
                    // makes the calibration predictable; default shared rounded
                    // cards keep the exact legacy path below.
                    ZStack {
                        shape.fill(Color.clear)
                            .glassEffect(glass, in: shape)
                        if let glassOverlay { shape.fill(glassOverlay) }
                        clippedContent
                    }
                } else {
                    clippedContent
                        .background {
                            if let glassOverlay { shape.fill(glassOverlay) }
                        }
                        .glassEffect(glass, in: shape)
                }
            } else {
                clippedContent.background {
                    if let customShape {
                        DashboardFallbackCardSurface(shape: customShape)
                    } else {
                        DashboardFallbackCardSurface()
                    }
                }
            }
        }
        .overlay {
            if let customShape {
                // Borderless reference: the custom silhouette owns no ordinary
                // stroke. Increased-contrast still gets a stronger edge.
                if contrast == .increased {
                    customShape.stroke(Color.primary.opacity(borderOpacity), lineWidth: 0.5)
                }
            } else {
                RoundedRectangle(
                    cornerRadius: appearance.moduleCornerRadius,
                    style: .continuous
                )
                .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 0.5)
            }
        }
    }

    private var resolvedBorderOpacity: Double {
        if appearance.usesTranslucentChrome {
            return appearance.strokeOpacity + (isHovered ? 0.10 : 0)
        }
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

    // Panel-only custom silhouette; the default rounded shape is untouched.
    func dashboardCardChrome(
        shape: AnyShape,
        isHovered: Bool = false,
        glassTint: Color? = nil,
        glassOverlay: Color? = nil
    ) -> some View {
        modifier(
            DashboardCardChromeModifier(
                isHovered: isHovered, customShape: shape,
                glassTint: glassTint, glassOverlay: glassOverlay
            )
        )
    }

    func activeCleanupCardChrome() -> some View {
        dashboardCardChrome()
    }
}
