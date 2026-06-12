import XCTest
@testable import MacActivityApp

final class ActiveProcessMemoryLayoutTests: XCTestCase {
    func testRowProgressScalesAgainstLargestVisibleProcess() {
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 50, maxBytes: 100), 0.5)
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 150, maxBytes: 100), 1.0)
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 0, maxBytes: 100), 0.0)
        XCTAssertEqual(ActiveProcessMemoryLayout.progress(bytes: 10, maxBytes: 0), 0.0)
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
