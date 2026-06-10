import Foundation

enum ActiveCleanReleaseLayout {
    static let trashSectionHeight: CGFloat = 103
    static let diskCleanupStripHeight: CGFloat = 44
    static let memoryStripHeight: CGFloat = diskCleanupStripHeight
    static let processRowHeight: CGFloat = ActiveProcessMemoryLayout.rowHeight
    static let processListSpacing: CGFloat = 0
    static let sectionSpacing: CGFloat = 10
    static let zoneOrder = ["diskCleanup", "processes"]
}
