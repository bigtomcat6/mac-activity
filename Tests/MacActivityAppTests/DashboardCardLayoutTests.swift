import XCTest
import CoreGraphics
import MacActivityCore
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

    func testRAMSegmentBarsLayoutCapsSampleBudgetForDenseHistories() {
        XCTAssertEqual(
            RAMSegmentBarsLayout.displaySampleBudget(for: CGSize(width: 1_000, height: 60)),
            96
        )
        XCTAssertEqual(
            RAMSegmentBarsLayout.displaySampleBudget(for: CGSize(width: 20, height: 60)),
            12
        )
    }

    func testRAMSegmentBarsLayoutDownsamplesChronologically() {
        let samples = (0..<120).map { index in
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                pressurePercent: Double(index),
                wiredBytes: UInt64(index),
                activeBytes: UInt64(index),
                compressedBytes: UInt64(index),
                cachedBytes: 0,
                availableBytes: 0,
                totalBytes: 120
            )
        }

        let displayed = RAMSegmentBarsLayout.displaySamples(
            for: samples,
            containerSize: CGSize(width: 60, height: 60)
        )

        XCTAssertEqual(displayed.count, 12)
        XCTAssertEqual(displayed.first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(displayed.last?.timestamp, samples.last?.timestamp)
    }
}
