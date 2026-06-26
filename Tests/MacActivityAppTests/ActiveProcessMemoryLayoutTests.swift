import XCTest
@testable import MacActivityApp

final class ActiveProcessMemoryLayoutTests: XCTestCase {
    func testRowProgressScalesAgainstCurrentUsedMemory() {
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 50, usedMemoryBytes: 200), 0.25)
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 300, usedMemoryBytes: 200), 1.0)
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 0, usedMemoryBytes: 200), 0.0)
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 10, usedMemoryBytes: 0), 0.0)
    }

    func testCompactLayoutConstantsMatchCleanReleasePage() {
        XCTAssertEqual(ActiveProcessMemoryLayout.rowHeight, 32)
        XCTAssertEqual(ActiveProcessMemoryLayout.trailingActionWidth, 72)
    }

    func testProcessListHasZeroSpacingWithOuterCornersRounded() {
        XCTAssertEqual(ActiveCleanReleaseLayout.processListSpacing, 0)
        XCTAssertEqual(ActiveProcessMemoryLayout.outerCornerRadius, ActiveCleanupChrome.cornerRadius)
    }
}
