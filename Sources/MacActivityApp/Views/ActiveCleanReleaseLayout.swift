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
    static let cornerRadius: CGFloat = 8
    static let backgroundOpacity = 0.55
    static let borderOpacity = 0.45
    static let hoverBorderOpacity = 0.68

    static func borderOpacity(isHovered: Bool) -> Double {
        isHovered ? hoverBorderOpacity : borderOpacity
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
    static let backgroundOpacity = DashboardCardChrome.backgroundOpacity
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
    let isHovered: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: DashboardCardChrome.cornerRadius,
            style: .continuous
        )

        content
            .contentShape(shape)
            .background(.quaternary.opacity(DashboardCardChrome.backgroundOpacity), in: shape)
            .clipShape(shape)
            .overlay {
                shape.stroke(
                    .separator.opacity(DashboardCardChrome.borderOpacity(isHovered: isHovered)),
                    lineWidth: 1
                )
            }
    }
}

private struct ActiveCleanupCardChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ActiveCleanupChrome.cornerRadius, style: .continuous)

        content
            .background(.quaternary.opacity(ActiveCleanupChrome.backgroundOpacity), in: shape)
            .clipShape(shape)
            .overlay {
                shape.stroke(.separator.opacity(ActiveCleanupChrome.borderOpacity), lineWidth: 1)
            }
    }
}

extension View {
    func dashboardCardChrome(isHovered: Bool = false) -> some View {
        modifier(DashboardCardChromeModifier(isHovered: isHovered))
    }

    func activeCleanupCardChrome() -> some View {
        modifier(ActiveCleanupCardChromeModifier())
    }
}
