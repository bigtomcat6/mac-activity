import XCTest
import CoreGraphics
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardCardLayoutTests: XCTestCase {
    func testCompactChartCardUsesSlightlyTallerHeights() {
        XCTAssertEqual(DashboardCardLayout.compactChartHeight, 60)
        XCTAssertEqual(DashboardCardLayout.compactChartMinHeight, 116)
    }

    func testCompactHoverLayoutStillUsesCompactAnnotationSizing() {
        XCTAssertTrue(DashboardCardLayout.usesCompactHoverLayout(for: DashboardCardLayout.compactChartHeight))
        XCTAssertFalse(DashboardCardLayout.usesCompactHoverLayout(for: 72))
    }

    func testCompactChartCardUsesTighterBottomInsetThanTop() {
        XCTAssertEqual(DashboardCardLayout.compactChartInsets.top, 8)
        XCTAssertEqual(DashboardCardLayout.compactChartInsets.bottom, 6)
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
                usedBytes: UInt64(index),
                totalBytes: 120
            )
        }

        let displayed = RAMSegmentBarsLayout.displaySamples(
            for: samples,
            containerSize: CGSize(width: 60, height: 60),
            referenceDate: Date(timeIntervalSince1970: 119)
        )

        XCTAssertEqual(displayed.count, 12)
        XCTAssertEqual(displayed.first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(displayed.last?.timestamp, samples.last?.timestamp)
    }

    func testRAMSegmentBarsLayoutFiltersToRecentRollingWindow() {
        let samples = [0, 299, 300, 450, 600].map { offset in
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: TimeInterval(offset)),
                pressurePercent: Double(offset),
                usedBytes: UInt64(offset),
                totalBytes: 1_000
            )
        }

        let displayed = RAMSegmentBarsLayout.displaySamples(
            for: samples,
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 600)
        )

        XCTAssertEqual(displayed.map(\.timestamp), samples.suffix(3).map(\.timestamp))
    }

    func testRAMSegmentBarsLayoutRightAnchorsSparseRecentSamplesInFixedSlots() {
        let samples = [100, 160].map { offset in
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: TimeInterval(offset)),
                pressurePercent: Double(offset),
                usedBytes: UInt64(offset),
                totalBytes: 1_000
            )
        }

        let slots = RAMSegmentBarsLayout.displaySlots(
            for: samples,
            containerSize: CGSize(width: 60, height: 60),
            referenceDate: Date(timeIntervalSince1970: 160)
        )

        XCTAssertEqual(slots.count, 12)
        XCTAssertEqual(slots.prefix(10).compactMap(\.sample).count, 0)
        XCTAssertEqual(slots.suffix(2).compactMap(\.sample).map(\.timestamp), samples.map(\.timestamp))
    }

    func testRAMSegmentBarsLayoutBuildsStackedSegmentsFromMemoryBreakdown() {
        let sample = DashboardMemoryTrendSample(
            timestamp: Date(timeIntervalSince1970: 200),
            pressurePercent: 50,
            usedBytes: 500,
            totalBytes: 1_000,
            breakdown: MemoryBreakdown(
                wiredBytes: 100,
                activeBytes: 300,
                compressedBytes: 100,
                cachedBytes: 250,
                availableBytes: 500
            )
        )

        XCTAssertEqual(
            RAMSegmentBarsLayout.displaySegments(for: sample),
            [
                RAMSegmentBarComponent(kind: .active, bytes: 300),
                RAMSegmentBarComponent(kind: .compressed, bytes: 100),
                RAMSegmentBarComponent(kind: .wired, bytes: 100),
            ]
        )
    }

    func testRAMSegmentBarsLayoutReportsSegmentPercentagesAgainstTotalMemory() {
        let sample = DashboardMemoryTrendSample(
            timestamp: Date(timeIntervalSince1970: 202),
            pressurePercent: 50,
            usedBytes: 500,
            totalBytes: 1_000,
            breakdown: MemoryBreakdown(wiredBytes: 100, activeBytes: 300, compressedBytes: 100)
        )
        let active = RAMSegmentBarComponent(kind: .active, bytes: 300)

        XCTAssertEqual(RAMSegmentBarsLayout.percentage(for: active, in: sample), 30, accuracy: 0.001)
    }

    func testRAMSegmentBarsLayoutCapsScaledSegmentsToUsedBytes() {
        let sample = DashboardMemoryTrendSample(
            timestamp: Date(timeIntervalSince1970: 201),
            pressurePercent: 50,
            usedBytes: 5,
            totalBytes: 10,
            breakdown: MemoryBreakdown(
                wiredBytes: 2,
                activeBytes: 2,
                compressedBytes: 2
            )
        )

        XCTAssertEqual(
            RAMSegmentBarsLayout.displaySegments(for: sample).reduce(UInt64(0)) { $0 + $1.bytes },
            5
        )
    }
}
