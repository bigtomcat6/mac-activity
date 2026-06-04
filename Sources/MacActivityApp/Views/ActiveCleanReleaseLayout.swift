import SwiftUI

enum ActiveCleanReleaseLayout {
    static let trashSectionHeight: CGFloat = 103
    static let memoryStripHeight: CGFloat = 44
    static let processRowHeight: CGFloat = ActiveProcessMemoryLayout.rowHeight
    static let processListSpacing: CGFloat = 0
    static let sectionSpacing: CGFloat = 10
    static let zoneOrder = ["memory", "processes"]
}

enum ActiveCleanupChrome {
    static let cornerRadius: CGFloat = 8
    static let backgroundOpacity = 0.55
    static let borderOpacity = 0.45
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
    func activeCleanupCardChrome() -> some View {
        modifier(ActiveCleanupCardChromeModifier())
    }
}
