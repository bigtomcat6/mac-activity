import Foundation
import SwiftUI

enum ActiveProcessMemoryLayout {
    static let rowHeight: CGFloat = 38
    static let trailingActionWidth: CGFloat = 72
    static let rowCornerRadius: CGFloat = 10
    static let rowBorderOpacity = 0.08
    static let rowBackgroundOpacity = 0.05

    static func progress(bytes: UInt64, maxBytes: UInt64) -> Double {
        guard maxBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(maxBytes)))
    }

    static func rowBackgroundColor(appearsActive: Bool) -> Color {
        appearsActive
        ? Color.white.opacity(rowBackgroundOpacity)
        : Color.white.opacity(0.035)
    }

    static func rowBorderColor(appearsActive: Bool) -> Color {
        Color.primary.opacity(appearsActive ? rowBorderOpacity : 0.05)
    }
}
