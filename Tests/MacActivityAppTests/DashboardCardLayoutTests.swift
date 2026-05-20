import XCTest
@testable import MacActivityApp

@MainActor
final class DashboardCardLayoutTests: XCTestCase {
    func testCompactChartCardUsesSlightlyTallerHeights() {
        XCTAssertEqual(DashboardCardLayout.compactChartHeight, 60)
        XCTAssertEqual(DashboardCardLayout.compactChartMinHeight, 98)
    }

    func testCompactHoverLayoutStillUsesCompactAnnotationSizing() {
        XCTAssertTrue(DashboardCardLayout.usesCompactHoverLayout(for: DashboardCardLayout.compactChartHeight))
        XCTAssertFalse(DashboardCardLayout.usesCompactHoverLayout(for: 72))
    }

    func testCompactChartCardUsesTighterBottomInsetThanTop() {
        XCTAssertEqual(DashboardCardLayout.compactChartInsets.top, 8)
        XCTAssertEqual(DashboardCardLayout.compactChartInsets.bottom, 4)
    }
}
