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

    static func canvasColor(for colorScheme: ColorScheme) -> Color {
        Color(.sRGB, white: colorScheme == .dark ? 0.14 : 0.92, opacity: 1)
    }

    static func shadowOpacity(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.20 : 0.10
    }
}

enum DashboardHeaderChrome {
    static let horizontalPadding: CGFloat = 18
    static let topPadding: CGFloat = 18
    static let bottomPadding: CGFloat = 12
    static let titlePickerSpacing: CGFloat = 12
    static let tabPickerMinWidth: CGFloat = 160
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let isHovered: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: DashboardCardChrome.cornerRadius,
            style: .continuous
        )
        let borderOpacity = contrast == .increased
            ? DashboardCardChrome.increasedContrastBorderOpacity + (isHovered ? 0.10 : 0)
            : DashboardCardChrome.borderOpacity(isHovered: isHovered)

        content
            .contentShape(shape)
            .clipShape(shape)
            .background {
                shape
                    .fill(DashboardCardChrome.surfaceColor(for: colorScheme))
                    .shadow(
                        color: .black.opacity(DashboardCardChrome.shadowOpacity(for: colorScheme)),
                        radius: DashboardCardChrome.shadowRadius,
                        x: 0,
                        y: DashboardCardChrome.shadowOffsetY
                    )
            }
            .overlay {
                shape.strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 0.5)
            }
    }
}

extension View {
    func dashboardCardChrome(isHovered: Bool = false) -> some View {
        modifier(DashboardCardChromeModifier(isHovered: isHovered))
    }

    func activeCleanupCardChrome() -> some View {
        dashboardCardChrome()
    }
}
