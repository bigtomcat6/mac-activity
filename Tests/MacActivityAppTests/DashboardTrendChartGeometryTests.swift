import XCTest
import SwiftUI
@testable import MacActivityApp

@MainActor
final class DashboardTrendChartGeometryTests: XCTestCase {
    func testIdlePlotRectUsesNearlyFullChartBounds() {
        let rect = DashboardTrendChartGeometry.basePlotRect(
            in: CGSize(width: 300, height: 120),
        )

        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 4, accuracy: 0.001)
        XCTAssertEqual(rect.width, 292, accuracy: 0.001)
        XCTAssertEqual(rect.height, 112, accuracy: 0.001)
    }

    func testHoverPlotRectShrinksTowardTopTrailingCorner() {
        let size = CGSize(width: 300, height: 120)
        let idleRect = DashboardTrendChartGeometry.basePlotRect(in: size)
        let hoverRect = DashboardTrendChartGeometry.plotRect(in: size, isHovering: true)

        XCTAssertGreaterThan(hoverRect.minX, idleRect.minX)
        XCTAssertEqual(hoverRect.minY, idleRect.minY, accuracy: 0.001)
        XCTAssertEqual(hoverRect.maxX, idleRect.maxX, accuracy: 0.001)
        XCTAssertLessThan(hoverRect.width, idleRect.width)
        XCTAssertLessThan(hoverRect.height, idleRect.height)
        XCTAssertGreaterThanOrEqual(hoverRect.minX, 56)
        XCTAssertGreaterThanOrEqual(size.height - hoverRect.maxY, 22)
    }

    func testSelectedIndexMapsLocationWithinPlotRect() {
        let plotRect = CGRect(x: 58, y: 32, width: 220, height: 64)

        XCTAssertEqual(
            DashboardTrendChartGeometry.selectedIndex(
                for: plotRect.minX,
                sampleCount: 5,
                plotRect: plotRect
            ),
            0
        )
        XCTAssertEqual(
            DashboardTrendChartGeometry.selectedIndex(
                for: plotRect.midX,
                sampleCount: 5,
                plotRect: plotRect
            ),
            2
        )
        XCTAssertEqual(
            DashboardTrendChartGeometry.selectedIndex(
                for: plotRect.maxX,
                sampleCount: 5,
                plotRect: plotRect
            ),
            4
        )
        XCTAssertEqual(
            DashboardTrendChartGeometry.selectedIndex(
                for: plotRect.minX - 100,
                sampleCount: 5,
                plotRect: plotRect
            ),
            0
        )
        XCTAssertEqual(
            DashboardTrendChartGeometry.selectedIndex(
                for: plotRect.maxX + 100,
                sampleCount: 5,
                plotRect: plotRect
            ),
            4
        )
    }
}
