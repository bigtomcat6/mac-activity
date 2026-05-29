import Foundation

enum ActiveProcessMemoryLayout {
    static let rowHeight: CGFloat = 38
    static let trailingActionWidth: CGFloat = 72

    static func progress(bytes: UInt64, maxBytes: UInt64) -> Double {
        guard maxBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(maxBytes)))
    }
}
