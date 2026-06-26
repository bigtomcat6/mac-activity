import Foundation
import SwiftUI

enum ActiveProcessMemoryLayout {
    static let rowHeight: CGFloat = 32
    static let trailingActionWidth: CGFloat = 72
    static let outerCornerRadius: CGFloat = ActiveCleanupChrome.cornerRadius

    static func progress(bytes: UInt64, usedMemoryBytes: UInt64) -> Double {
        guard usedMemoryBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(usedMemoryBytes)))
    }
}
