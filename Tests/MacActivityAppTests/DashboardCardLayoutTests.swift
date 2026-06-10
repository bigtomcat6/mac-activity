import XCTest
import CoreGraphics
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardCardLayoutTests: XCTestCase {
    func testSelectingActivesTabAdvancesActivesRefreshTrigger() {
        XCTAssertEqual(
            DashboardView.activesRefreshTrigger(afterSelecting: .overview, currentTrigger: 4),
            4
        )
        XCTAssertEqual(
            DashboardView.activesRefreshTrigger(afterSelecting: .actives, currentTrigger: 4),
            5
        )
    }

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

    func testCardChromeFillsExplicitOverviewRowFrames() {
        XCTAssertTrue(DashboardCardLayout.cardChromeMaxHeight.isInfinite)
    }

    func testOverviewMotionDurationsStayResponsiveButVisible() {
        XCTAssertEqual(DashboardMotion.sampleDuration, 0.32, accuracy: 0.001)
        XCTAssertEqual(DashboardMotion.domainDuration, 0.38, accuracy: 0.001)
        XCTAssertEqual(DashboardMotion.valueDuration, 0.42, accuracy: 0.001)
    }

    func testOverviewLayoutUsesApprovedFixedSlots() {
        let metrics = DashboardCardLayoutTests.overviewMetrics([
            .cpu,
            .gpu,
            .memory,
            .network,
            .temperature,
            .fan,
            .battery,
        ])

        XCTAssertEqual(
            DashboardOverviewLayout.topRowSlots(for: metrics),
            [.usage, .metric(.memory)]
        )
        XCTAssertEqual(
            DashboardOverviewLayout.secondRowLeadingSlot(for: metrics),
            .metric(.network)
        )
        XCTAssertEqual(
            DashboardOverviewLayout.secondRowTrailingSlots(for: metrics),
            [.metric(.temperature), .metric(.fan)]
        )
        XCTAssertEqual(
            DashboardOverviewLayout.thirdRowSlots(for: metrics),
            [.metric(.battery)]
        )
    }

    func testOverviewLayoutOmitsUnavailableSlotsAndKeepsBatteryOnlyThirdRegion() {
        let metrics = DashboardCardLayoutTests.overviewMetrics([.cpu, .memory, .fan, .vram])

        XCTAssertEqual(
            DashboardOverviewLayout.topRowSlots(for: metrics),
            [.usage, .metric(.memory)]
        )
        XCTAssertNil(DashboardOverviewLayout.secondRowLeadingSlot(for: metrics))
        XCTAssertEqual(
            DashboardOverviewLayout.secondRowTrailingSlots(for: metrics),
            [.metric(.fan)]
        )
        XCTAssertEqual(DashboardOverviewLayout.thirdRowSlots(for: metrics), [])
    }

    func testOverviewUsageProgressParsesPercentTextAndClamps() {
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "38%"), 0.38, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "0%"), 0.0, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "147%"), 1.0, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "-7%"), 0.0, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "Collecting"), 0.0, accuracy: 0.001)
    }

    func testOverviewCompactTrendLayoutUsesTextLeftChartRightShape() {
        XCTAssertEqual(DashboardOverviewLayout.compactTrendChartHeight, 44)
        XCTAssertEqual(DashboardOverviewLayout.sectionSpacing, 12)
        XCTAssertEqual(DashboardOverviewLayout.compactTrendRestTextChartSpacing, 12)
    }

    func testOverviewUsageCardHeaderIsHidden() {
        XCTAssertNil(DashboardOverviewLayout.usageHeaderTitle)
    }

    func testOverviewCompactTrendCardsUseAdaptiveTextWidthForRequestedMetrics() {
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .temperature))
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .fan))
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .battery))
        XCTAssertFalse(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .memory))
    }

    func testNetworkMetricCardChartFillsRemainingCardHeight() {
        XCTAssertEqual(
            DashboardCardLayout.chartHeightBehavior(for: .network),
            .fillsRemainingHeight
        )
        XCTAssertEqual(
            DashboardCardLayout.chartHeightBehavior(for: .temperature),
            .fixed(DashboardCardLayout.compactChartHeight)
        )
        XCTAssertEqual(
            DashboardCardLayout.chartHeightBehavior(for: .fan),
            .fixed(DashboardCardLayout.compactChartHeight)
        )
        XCTAssertEqual(
            DashboardCardLayout.chartHeightBehavior(for: .battery),
            .fixed(DashboardCardLayout.compactChartHeight)
        )
    }

    func testOverviewRowsUseFixedHeightsToKeepSiblingCardsEven() {
        XCTAssertEqual(DashboardOverviewLayout.topRowHeight, DashboardCardLayout.compactChartMinHeight)
        XCTAssertEqual(DashboardOverviewLayout.compactTrendCardHeight, 64)
        XCTAssertEqual(
            DashboardOverviewLayout.secondRowHeight,
            DashboardOverviewLayout.compactTrendCardHeight * 2 + DashboardOverviewLayout.sectionSpacing
        )
        XCTAssertEqual(DashboardOverviewLayout.slimTrendCardHeight, 74)
        XCTAssertEqual(DashboardOverviewLayout.batteryRowHeight, DashboardOverviewLayout.slimTrendCardHeight)
    }

    func testOverviewBatteryRowHeightFitsCurrentChartHeightOnly() {
        XCTAssertEqual(
            DashboardOverviewLayout.batteryRowHeight,
            DashboardCardLayout.compactChartHeight
            + DashboardCardLayout.compactChartInsets.top
            + DashboardCardLayout.compactChartInsets.bottom
        )
    }

    func testCompactTrendCardsKeepCharacterSizedGapBeforeChart() {
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .temperature))
        XCTAssertEqual(DashboardOverviewLayout.compactTrendRestTextChartSpacing, 12)
    }

    func testCompactTrendCardsCollapseReadoutAndGapOnHover() {
        XCTAssertTrue(
            DashboardOverviewLayout.compactTrendShowsReadout(
                for: .temperature,
                isHovered: false
            )
        )
        XCTAssertFalse(
            DashboardOverviewLayout.compactTrendShowsReadout(
                for: .temperature,
                isHovered: true
            )
        )
        XCTAssertEqual(
            DashboardOverviewLayout.compactTrendTextChartSpacing(
                for: .temperature,
                isHovered: false
            ),
            12
        )
        XCTAssertEqual(
            DashboardOverviewLayout.compactTrendTextChartSpacing(
                for: .temperature,
                isHovered: true
            ),
            0
        )
        XCTAssertEqual(
            DashboardOverviewLayout.compactTrendTextChartSpacing(
                for: .battery,
                isHovered: true
            ),
            12
        )
    }

    func testOverviewSuppressesLeftYAxisLabelsForNetworkAndCompactTrendCharts() {
        XCTAssertFalse(DashboardOverviewLayout.showsTrendYAxisLabels(for: .network, isCompactOverviewChart: false))
        XCTAssertFalse(DashboardOverviewLayout.showsTrendYAxisLabels(for: .temperature, isCompactOverviewChart: true))
        XCTAssertFalse(DashboardOverviewLayout.showsTrendYAxisLabels(for: .fan, isCompactOverviewChart: true))
        XCTAssertTrue(DashboardOverviewLayout.showsTrendYAxisLabels(for: .memory, isCompactOverviewChart: false))
        XCTAssertTrue(DashboardOverviewLayout.showsTrendYAxisLabels(for: .battery, isCompactOverviewChart: false))
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

    private static func overviewMetrics(_ kinds: [MetricKind]) -> [DashboardMetric] {
        kinds.map { kind in
            DashboardMetric(
                kind: kind,
                title: kind.title,
                value: kind == .fan ? "1800 RPM" : "42%",
                style: kind == .memory ? .memoryStackedChart : .chart
            )
        }
    }
}
