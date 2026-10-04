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
            if #available(macOS 26.0, *), !reduceTransparency {
                clippedContent.glassEffect(.regular, in: shape)
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

    // Hover overlays float above the cards, which is the layer Liquid Glass is
    // meant for; older systems and Reduce Transparency keep the material bubble.
    func dashboardFloatingSurface(cornerRadius: CGFloat = 8) -> some View {
        modifier(DashboardFloatingSurfaceModifier(cornerRadius: cornerRadius))
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
