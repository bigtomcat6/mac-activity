import CoreGraphics
import AppKit
import SwiftUI
import XCTest
@testable import MacActivityCore
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

    func testOverviewTrendFocusPaletteChangeDoesNotAnimate() {
        XCTAssertNil(DashboardMotion.focusPaletteAnimation)
    }

    func testOverviewLayoutUsesApprovedFixedSlots() {
        let metrics = DashboardCardLayoutTests.overviewMetrics([
            .cpu,
            .gpu,
            .disk,
            .swap,
            .memory,
            .network,
            .temperature,
            .fan,
            .battery,
        ])

        XCTAssertEqual(
            DashboardOverviewLayout.topRowSlots(for: metrics),
            [.usage, .storage, .metric(.memory)]
        )
        XCTAssertEqual(
            DashboardOverviewLayout.computeUsageMetricKinds(in: DashboardOverviewLayout.metricsByKind(metrics)),
            [.cpu, .gpu]
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageUsageMetricKinds(in: DashboardOverviewLayout.metricsByKind(metrics)),
            [.disk, .swap]
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

    func testOverviewUsageRegionCanDisplayDiskAndSwapWithoutCPUOrGPU() {
        let metrics = DashboardCardLayoutTests.overviewMetrics([.disk, .swap])

        XCTAssertEqual(
            DashboardOverviewLayout.topRowSlots(for: metrics),
            [.storage]
        )
        XCTAssertEqual(
            DashboardOverviewLayout.computeUsageMetricKinds(in: DashboardOverviewLayout.metricsByKind(metrics)),
            []
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageUsageMetricKinds(in: DashboardOverviewLayout.metricsByKind(metrics)),
            [.disk, .swap]
        )
    }

    func testOverviewUsageProgressParsesPercentTextAndClamps() {
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "38%"), 0.38, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "0%"), 0.0, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "147%"), 1.0, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "-7%"), 0.0, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: "Collecting"), 0.0, accuracy: 0.001)
    }

    func testOverviewUsageRowsUseStableCenteredColumns() {
        XCTAssertEqual(DashboardOverviewLayout.usageLabelColumnWidth, 54)
        XCTAssertEqual(DashboardOverviewLayout.usageValueColumnWidth, 44)
        XCTAssertEqual(DashboardOverviewLayout.usageRowSpacing, 10)
        XCTAssertEqual(DashboardOverviewLayout.usageBarHeight, 8)
    }

    func testOverviewUsageCardRowsFillAvailableCardWidth() {
        XCTAssertTrue(DashboardOverviewLayout.usageContentMaxWidth.isInfinite)
    }

    func testOverviewStorageCardKeepsBoundedContentWidth() {
        XCTAssertEqual(DashboardOverviewLayout.storageContentMaxWidth, 180)
    }

    func testOverviewUsageCardCentersContentWithinCardFrame() {
        XCTAssertEqual(DashboardOverviewLayout.usageCardContentAlignment, Alignment.center)
    }

    func testOverviewTopRowHeightFitsSplitUsageCards() {
        XCTAssertEqual(DashboardOverviewLayout.topSplitCardHeight, DashboardOverviewLayout.compactTrendCardHeight)
        XCTAssertEqual(
            DashboardOverviewLayout.topRowHeight,
            DashboardOverviewLayout.topSplitCardHeight * 2 + DashboardOverviewLayout.sectionSpacing
        )
    }

    func testOverviewUsageProgressPrefersStructuredProgressAndClamps() {
        let metric = DashboardMetric(kind: .disk, title: "Disk", value: "Collecting", progress: 0.42)
        let highMetric = DashboardMetric(kind: .disk, title: "Disk", value: "38%", progress: 1.5)
        let lowMetric = DashboardMetric(kind: .disk, title: "Disk", value: "38%", progress: -0.25)
        let textOnlyMetric = DashboardMetric(kind: .disk, title: "Disk", value: "62%")

        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: metric), 0.42, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: highMetric), 1.0, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: lowMetric), 0.0, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.usageProgress(for: textOnlyMetric), 0.62, accuracy: 0.001)
    }

    func testOverviewCompactTrendLayoutUsesTextLeftChartRightShape() {
        XCTAssertEqual(DashboardOverviewLayout.compactTrendChartHeight, 44)
        XCTAssertEqual(DashboardOverviewLayout.sectionSpacing, 12)
        XCTAssertEqual(DashboardOverviewLayout.compactTrendRestTextChartSpacing, 12)
    }

    func testOverviewUsageCardHeaderIsHidden() {
        XCTAssertNil(DashboardOverviewLayout.usageHeaderTitle)
    }

    func testOverviewStorageCardUsesStableCompactGeometry() {
        XCTAssertEqual(DashboardOverviewLayout.storageBarHeight, 8)
        XCTAssertEqual(DashboardOverviewLayout.storageContentSpacing, 0)
        XCTAssertEqual(DashboardOverviewLayout.storageDetailRowCount, 2)
        XCTAssertEqual(DashboardOverviewLayout.storageDetailRowHeight, 14)
        XCTAssertEqual(DashboardOverviewLayout.storageDetailRowSpacing, 2)
        XCTAssertEqual(DashboardOverviewLayout.storageDetailBarSpacing, 4)
        XCTAssertEqual(DashboardOverviewLayout.storageDetailMarkerWidth, 1)
        XCTAssertEqual(DashboardOverviewLayout.storageDetailIconCenterOffset, 7)
        XCTAssertEqual(DashboardOverviewLayout.storageSwapMinimumVisibleWidth, 0.02)
        XCTAssertEqual(DashboardOverviewLayout.storageDetailContentAlignment, Alignment.leading)
        XCTAssertEqual(DashboardOverviewLayout.storageDetailTextAlignment, .leading)
        XCTAssertEqual(DashboardOverviewLayout.storageDetailSpacing, 4)
    }

    func testOverviewStorageDetailUsesNativeSymbolsForDiskAndSwap() {
        XCTAssertEqual(DashboardOverviewLayout.storageDetailIconName(for: .disk), "externaldrive")
        XCTAssertEqual(DashboardOverviewLayout.storageDetailIconName(for: .swap), "memorychip")
        XCTAssertNil(DashboardOverviewLayout.storageDetailIconName(for: .cpu))
    }

    func testOverviewStorageCardShowsDetailsAboveUsageBar() {
        XCTAssertEqual(DashboardOverviewLayout.storageCardContentOrder, [.details, .bar])
    }

    func testOverviewStorageSegmentsUseDiskTotalAsSharedDenominatorAndStayAdjacent() {
        let metrics = [
            DashboardMetric(
                kind: .disk,
                title: "Disk",
                value: "80%",
                usedBytes: 800,
                totalBytes: 1_000,
                progress: 0.8
            ),
            DashboardMetric(
                kind: .swap,
                title: "Swap",
                value: "50%",
                usedBytes: 100,
                totalBytes: 200,
                progress: 0.5
            ),
        ]

        let segments = DashboardOverviewLayout.storageUsageSegments(for: metrics)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].kind, .disk)
        XCTAssertEqual(segments[0].startProgress, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].widthProgress, 0.8, accuracy: 0.001)
        XCTAssertEqual(segments[1].kind, .swap)
        XCTAssertEqual(segments[1].startProgress, 0.8, accuracy: 0.001)
        XCTAssertEqual(segments[1].widthProgress, 0.1, accuracy: 0.001)
    }

    func testOverviewStorageSegmentsUseMinimumVisibleWidthOnlyForNonzeroSmallSwap() {
        let metrics = [
            DashboardMetric(
                kind: .disk,
                title: "Disk",
                value: "40%",
                usedBytes: 400,
                totalBytes: 1_000,
                progress: 0.4
            ),
            DashboardMetric(
                kind: .swap,
                title: "Swap",
                value: "0%",
                usedBytes: 0,
                totalBytes: 1_000,
                progress: 0.0
            ),
        ]

        XCTAssertEqual(
            DashboardOverviewLayout.storageUsageSegments(for: metrics),
            [
                DashboardStorageUsageSegment(kind: .disk, startProgress: 0.0, widthProgress: 0.4),
            ]
        )

        let smallSwapMetrics = [
            DashboardMetric(
                kind: .disk,
                title: "Disk",
                value: "40%",
                usedBytes: 400,
                totalBytes: 1_000,
                progress: 0.4
            ),
            DashboardMetric(
                kind: .swap,
                title: "Swap",
                value: "1%",
                usedBytes: 10,
                totalBytes: 1_000,
                progress: 0.01
            ),
        ]

        XCTAssertEqual(
            DashboardOverviewLayout.storageUsageSegments(for: smallSwapMetrics),
            [
                DashboardStorageUsageSegment(kind: .disk, startProgress: 0.0, widthProgress: 0.4),
                DashboardStorageUsageSegment(kind: .swap, startProgress: 0.4, widthProgress: 0.02),
            ]
        )
    }

    func testOverviewStorageSegmentsFallBackToEqualSlotsWithoutDiskTotalBytes() {
        let metrics = [
            DashboardMetric(
                kind: .disk,
                title: "Disk",
                value: "40%",
                progress: 0.4
            ),
            DashboardMetric(
                kind: .swap,
                title: "Swap",
                value: "50%",
                progress: 0.5
            ),
        ]

        XCTAssertEqual(
            DashboardOverviewLayout.storageUsageSegments(for: metrics),
            [
                DashboardStorageUsageSegment(kind: .disk, startProgress: 0.0, widthProgress: 0.2),
                DashboardStorageUsageSegment(kind: .swap, startProgress: 0.5, widthProgress: 0.25),
            ]
        )
    }

    func testOverviewStorageLabelsAndConnectorsCollapseWhenSwapIsZero() {
        let metrics = [
            DashboardMetric(
                kind: .disk,
                title: "Disk",
                value: "40%",
                usedBytes: 400,
                totalBytes: 1_000,
                progress: 0.4
            ),
            DashboardMetric(
                kind: .swap,
                title: "Swap",
                value: "0%",
                usedBytes: 0,
                totalBytes: 1_000,
                progress: 0.0
            ),
        ]

        let labels = DashboardOverviewLayout.storageUsageLabels(for: metrics)

        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels[0].kind, .disk)
        XCTAssertEqual(labels[0].startProgress, 0.0, accuracy: 0.001)
        XCTAssertEqual(labels[0].endProgress ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(
            DashboardOverviewLayout.storageConnectorHeight(for: labels[0]),
            DashboardOverviewLayout.storageDetailBarSpacing,
            accuracy: 0.001
        )
    }

    func testOverviewStorageLabelsUseSegmentStartsAcrossTwoRows() {
        let metrics = [
            DashboardMetric(
                kind: .disk,
                title: "Disk",
                value: "80%",
                usedBytes: 800,
                totalBytes: 1_000,
                progress: 0.8
            ),
            DashboardMetric(
                kind: .swap,
                title: "Swap",
                value: "50%",
                usedBytes: 100,
                totalBytes: 200,
                progress: 0.5
            ),
        ]

        XCTAssertEqual(
            DashboardOverviewLayout.storageUsageLabels(for: metrics),
            [
                DashboardStorageUsageLabel(kind: .disk, startProgress: 0.0, rowIndex: 0, endProgress: 0.8),
                DashboardStorageUsageLabel(kind: .swap, startProgress: 0.8, rowIndex: 1, endProgress: 0.9),
            ]
        )
    }

    func testOverviewStorageConnectorsStartBelowTheirLabelRows() {
        let labels = [
            DashboardStorageUsageLabel(kind: .disk, startProgress: 0.0, rowIndex: 0),
            DashboardStorageUsageLabel(kind: .swap, startProgress: 0.8, rowIndex: 1),
        ]

        XCTAssertEqual(DashboardOverviewLayout.storageConnectorYPosition(for: labels[0]), 14, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.storageConnectorHeight(for: labels[0]), 20, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.storageConnectorYPosition(for: labels[1]), 30, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.storageConnectorHeight(for: labels[1]), 4, accuracy: 0.001)
    }

    func testOverviewStorageDetailMarkersAlignDiskWithIconAndSwapWithSegmentEnd() {
        let metrics = [
            DashboardMetric(
                kind: .disk,
                title: "Disk",
                value: "80%",
                usedBytes: 800,
                totalBytes: 1_000,
                progress: 0.8
            ),
            DashboardMetric(
                kind: .swap,
                title: "Swap",
                value: "50%",
                usedBytes: 100,
                totalBytes: 200,
                progress: 0.5
            ),
        ]
        let labels = DashboardOverviewLayout.storageUsageLabels(for: metrics)
        let diskLabel = DashboardStorageUsageLabel(kind: .disk, startProgress: 0.0, rowIndex: 0)
        let swapLabel = labels[1]

        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailRowXPosition(
                for: diskLabel,
                containerWidth: 180
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailMarkerXPosition(
                for: diskLabel,
                containerWidth: 180
            ),
            7,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailRowXPosition(
                for: swapLabel,
                containerWidth: 600
            ),
            480,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailMarkerXPosition(
                for: swapLabel,
                containerWidth: 600
            ),
            540,
            accuracy: 0.001
        )
    }

    func testOverviewStorageSwapLabelFallsBackToTrailingWhenStartLeavesTooLittleRoom() {
        let diskLabel = DashboardStorageUsageLabel(kind: .disk, startProgress: 0.0, rowIndex: 0)
        let swapLabel = DashboardStorageUsageLabel(kind: .swap, startProgress: 0.9, rowIndex: 1)

        XCTAssertFalse(
            DashboardOverviewLayout.storageDetailUsesTrailingFallback(
                for: diskLabel,
                containerWidth: 180
            )
        )
        XCTAssertTrue(
            DashboardOverviewLayout.storageDetailUsesTrailingFallback(
                for: swapLabel,
                containerWidth: 180
            )
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailRowXPosition(
                for: swapLabel,
                containerWidth: 180
            ),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailRowWidth(
                for: swapLabel,
                containerWidth: 180
            ),
            180,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailRowAlignment(
                for: swapLabel,
                containerWidth: 180
            ),
            .trailing
        )
    }

    func testOverviewCompactTrendCardsUseAdaptiveTextWidthForRequestedMetrics() {
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .temperature))
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .fan))
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .battery))
        XCTAssertFalse(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .memory))
    }

    func testFooterUsesSameGrayOpacityTokenAsActivesChrome() {
        XCTAssertEqual(DashboardFooterChrome.backgroundOpacity, ActiveCleanupChrome.backgroundOpacity, accuracy: 0.001)
    }

    func testDashboardCardsShareActivesSurfaceChrome() {
        XCTAssertEqual(DashboardCardChrome.cornerRadius, ActiveCleanupChrome.cornerRadius)
        XCTAssertEqual(DashboardCardChrome.backgroundOpacity, ActiveCleanupChrome.backgroundOpacity, accuracy: 0.001)
        XCTAssertEqual(DashboardCardChrome.borderOpacity(isHovered: false), ActiveCleanupChrome.borderOpacity, accuracy: 0.001)
    }

    func testDashboardCardsIncreaseBorderEmphasisOnHover() {
        XCTAssertGreaterThan(
            DashboardCardChrome.borderOpacity(isHovered: true),
            DashboardCardChrome.borderOpacity(isHovered: false)
        )
    }

    func testHeaderLiveIndicatorUsesCompactChipChrome() {
        XCTAssertEqual(DashboardHeaderChrome.liveIndicatorDotSize, 6)
        XCTAssertEqual(DashboardHeaderChrome.liveIndicatorHorizontalPadding, 8)
        XCTAssertEqual(DashboardHeaderChrome.liveIndicatorVerticalPadding, 4)
    }

    func testFooterActionsUseStableSystemImages() {
        XCTAssertEqual(DashboardFooterChrome.preferencesSystemImage, "gearshape")
        XCTAssertEqual(DashboardFooterChrome.quitSystemImage, "power")
    }

    func testNetworkMetricCardChartFillsRemainingCardHeight() {
        XCTAssertEqual(
            DashboardCardLayout.chartHeightBehavior(for: .memory),
            .fillsRemainingHeight
        )
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
        XCTAssertEqual(
            DashboardOverviewLayout.topRowHeight,
            DashboardOverviewLayout.topSplitCardHeight * 2 + DashboardOverviewLayout.sectionSpacing
        )
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

    func testRenderedFooterUsesOverviewGrayBackgroundTone() throws {
        let model = DashboardModel(store: MetricsStore())
        let content = DashboardView(
            dashboardModel: model,
            preferencesController: Self.preferencesController(),
            openPreferences: {},
            quitApplication: {}
        )
        .frame(width: 360, height: 260)

        let referenceColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(.quaternary.opacity(ActiveCleanupChrome.backgroundOpacity))
                    .frame(width: 360, height: 60),
                atTopLeft: CGPoint(x: 180, y: 30)
            )
        )
        let footerColor = try XCTUnwrap(
            Self.renderedColor(of: content, atTopLeft: CGPoint(x: 180, y: 236))
        )

        XCTAssertTrue(
            Self.colorsApproximatelyEqual(footerColor, referenceColor, tolerance: 0.08),
            "Expected footer background to match the Overview/Actives gray tone. reference=\(Self.debugColor(referenceColor)) footer=\(Self.debugColor(footerColor))"
        )
    }

    func testRenderedOverviewDisplaysSplitStorageCardForDiskAndSwapMetrics() throws {
        let store = MetricsStore()
        store.apply(
            [
                .cpu(CPUReading(usagePercent: 25)),
                .gpu(GPUReading(usagePercent: 50)),
                .disk(DiskReading(usedBytes: 750, totalBytes: 1_000)),
                .swap(SwapReading(usedBytes: 256, totalBytes: 1_024)),
                .memory(MemoryReading(usedBytes: 600, totalBytes: 1_000)),
            ],
            timestamp: Date(timeIntervalSince1970: 21)
        )
        let model = DashboardModel(store: store)
        let content = DashboardView(
            dashboardModel: model,
            preferencesController: Self.preferencesController(),
            openPreferences: {},
            quitApplication: {}
        )
        .frame(width: 360, height: 320)

        XCTAssertEqual(
            DashboardOverviewLayout.topRowSlots(for: model.metrics),
            [.usage, .storage, .metric(.memory)]
        )
        XCTAssertNotNil(Self.renderedColor(of: content, atTopLeft: CGPoint(x: 90, y: 128)))

        let storageOnlyStore = MetricsStore()
        storageOnlyStore.apply(
            [
                .disk(DiskReading(usedBytes: 400, totalBytes: 1_000)),
                .swap(SwapReading(usedBytes: 100, totalBytes: 1_000)),
            ],
            timestamp: Date(timeIntervalSince1970: 22)
        )
        let storageOnlyModel = DashboardModel(store: storageOnlyStore)
        let storageOnlyContent = DashboardView(
            dashboardModel: storageOnlyModel,
            preferencesController: Self.preferencesController(),
            openPreferences: {},
            quitApplication: {}
        )
        .frame(width: 360, height: 320)

        XCTAssertEqual(DashboardOverviewLayout.topRowSlots(for: storageOnlyModel.metrics), [.storage])
        XCTAssertNotNil(Self.renderedColor(of: storageOnlyContent, atTopLeft: CGPoint(x: 90, y: 128)))
    }

    func testRenderedOverviewFallsBackToTrendChartForEmptyMemoryStackedMetric() throws {
        let model = DashboardModel(
            store: MetricsStore(),
            metricsBuilder: { _, _, _, _ in
                [
                    DashboardMetric(
                        kind: .memory,
                        title: "Memory",
                        value: "Collecting",
                        style: .memoryStackedChart,
                        trend: DashboardTrend(samples: [], scale: .fixed(lowerBound: 0, upperBound: 100)),
                        memoryTrend: DashboardMemoryTrend(samples: [])
                    ),
                ]
            }
        )
        let content = DashboardView(
            dashboardModel: model,
            preferencesController: Self.preferencesController(),
            openPreferences: {},
            quitApplication: {}
        )
        .frame(width: 360, height: 320)

        XCTAssertNotNil(Self.renderedColor(of: content, atTopLeft: CGPoint(x: 270, y: 128)))
    }

    func testRenderedOverviewDisplaysTemperatureFanAndBatteryTrendTitles() throws {
        let store = MetricsStore()
        store.apply(
            [
                .temperature(TemperatureReading(celsius: 42, source: .smc)),
                .fan(FanReading(rpm: 1_800)),
                .battery(BatteryReading(percentage: 82, isCharging: false)),
            ],
            timestamp: Date(timeIntervalSince1970: 24)
        )
        let model = DashboardModel(store: store)
        let content = DashboardView(
            dashboardModel: model,
            preferencesController: Self.preferencesController(),
            openPreferences: {},
            quitApplication: {}
        )
        .frame(width: 360, height: 320)

        XCTAssertNotNil(Self.renderedColor(of: content, atTopLeft: CGPoint(x: 180, y: 128)))
    }

    func testRenderedDashboardCanStartOnActivesTab() throws {
        let store = MetricsStore()
        store.apply(
            [
                .memory(MemoryReading(usedBytes: 600, totalBytes: 1_000)),
            ],
            timestamp: Date(timeIntervalSince1970: 23)
        )
        let model = DashboardModel(store: store)
        let content = DashboardView(
            dashboardModel: model,
            preferencesController: Self.preferencesController(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: AppPreferences.default.selectedSummaryMetrics,
                    showsProcessApplicationIdentifier: true
                )
            ),
            openPreferences: {},
            quitApplication: {},
            initialSelectedTab: .actives
        )
        .frame(width: 360, height: 320)

        XCTAssertNotNil(Self.renderedColor(of: content, atTopLeft: CGPoint(x: 180, y: 170)))
    }

    func testActivesCurrentUsedMemoryComesFromMemoryMetricLatestSample() {
        let metrics = [
            DashboardMetric(
                kind: .memory,
                title: "Memory",
                value: "6.0GB/10.0GB (60%)",
                memoryTrend: DashboardMemoryTrend(samples: [
                    DashboardMemoryTrendSample(
                        timestamp: Date(timeIntervalSince1970: 1),
                        pressurePercent: 50,
                        usedBytes: 5_000,
                        totalBytes: 10_000
                    ),
                    DashboardMemoryTrendSample(
                        timestamp: Date(timeIntervalSince1970: 2),
                        pressurePercent: 60,
                        usedBytes: 6_000,
                        totalBytes: 10_000
                    ),
                ])
            )
        ]

        XCTAssertEqual(DashboardView.currentUsedMemoryBytes(in: metrics), 6_000)
        XCTAssertNil(DashboardView.currentUsedMemoryBytes(in: []))
    }

    func testSwapMetricUsesOrangeTint() throws {
        let swapColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(DashboardMetricColor.color(for: .swap))
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )
        let orangeColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(.orange)
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )

        XCTAssertTrue(
            Self.colorsApproximatelyEqual(swapColor, orangeColor, tolerance: 0.02),
            "Expected Swap metric tint to be orange. swap=\(Self.debugColor(swapColor)) orange=\(Self.debugColor(orangeColor))"
        )
    }

    func testOverviewUsageBarFillChangesToneWhenWindowIsInactive() throws {
        let activeColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(
                        DashboardOverviewChrome.emphasisFillColor(
                            baseColor: .orange,
                            opacity: DashboardOverviewChrome.usageFillOpacity,
                            appearsActive: true
                        )
                    )
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )
        let inactiveColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(
                        DashboardOverviewChrome.emphasisFillColor(
                            baseColor: .orange,
                            opacity: DashboardOverviewChrome.usageFillOpacity,
                            appearsActive: false
                        )
                    )
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )

        XCTAssertFalse(
            Self.colorsApproximatelyEqual(activeColor, inactiveColor, tolerance: 0.04),
            "Expected Overview usage bar fill to change when the window becomes inactive. active=\(Self.debugColor(activeColor)) inactive=\(Self.debugColor(inactiveColor))"
        )
    }

    func testOverviewChromeUsesActivesNeutralFillWhenWindowIsInactive() throws {
        let inactiveColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(
                        DashboardOverviewChrome.emphasisFillColor(
                            baseColor: .orange,
                            opacity: DashboardOverviewChrome.usageFillOpacity,
                            appearsActive: false
                        )
                    )
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )
        let referenceColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(DashboardOverviewChrome.inactiveEmphasisFill)
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )

        XCTAssertTrue(
            Self.colorsApproximatelyEqual(inactiveColor, referenceColor, tolerance: 0.01),
            "Expected Overview inactive emphasis fill to reuse the shared neutral tone. inactive=\(Self.debugColor(inactiveColor)) reference=\(Self.debugColor(referenceColor))"
        )
    }

    func testOverviewLiveIndicatorColorChangesWhenWindowIsInactive() throws {
        let activeColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(DashboardOverviewChrome.liveIndicatorColor(appearsActive: true))
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )
        let inactiveColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(DashboardOverviewChrome.liveIndicatorColor(appearsActive: false))
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )

        XCTAssertFalse(
            Self.colorsApproximatelyEqual(activeColor, inactiveColor, tolerance: 0.04),
            "Expected the Live indicator color to lose its active accent when the window becomes inactive. active=\(Self.debugColor(activeColor)) inactive=\(Self.debugColor(inactiveColor))"
        )
    }

    func testOverviewTrendAreaGradientChangesToneWhenWindowIsInactive() throws {
        let activeColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(
                        DashboardOverviewChrome.chartAreaGradient(
                            baseColor: .green,
                            appearsActive: true
                        )
                    )
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 4)
            )
        )
        let inactiveColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(
                        DashboardOverviewChrome.chartAreaGradient(
                            baseColor: .green,
                            appearsActive: false
                        )
                    )
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 4)
            )
        )

        XCTAssertFalse(
            Self.colorsApproximatelyEqual(activeColor, inactiveColor, tolerance: 0.04),
            "Expected the Overview trend area gradient to change when the window becomes inactive. active=\(Self.debugColor(activeColor)) inactive=\(Self.debugColor(inactiveColor))"
        )
    }

    func testOverviewNetworkSecondaryStrokeUsesNeutralToneWhenWindowIsInactive() throws {
        let inactiveColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(
                        DashboardOverviewChrome.chartSecondaryStrokeColor(
                            baseColor: .red,
                            appearsActive: false
                        )
                    )
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )
        let referenceColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(DashboardOverviewChrome.inactiveChartSecondaryStroke)
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )

        XCTAssertTrue(
            Self.colorsApproximatelyEqual(inactiveColor, referenceColor, tolerance: 0.01),
            "Expected the inactive network secondary stroke to use the shared neutral chart tone. inactive=\(Self.debugColor(inactiveColor)) reference=\(Self.debugColor(referenceColor))"
        )
    }

    func testOverviewMemorySegmentColorUsesNeutralToneWhenWindowIsInactive() throws {
        let inactiveColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(
                        DashboardOverviewChrome.memorySegmentColor(
                            for: .active,
                            appearsActive: false
                        )
                    )
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )
        let referenceColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(DashboardOverviewChrome.inactiveMemorySegmentFill)
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 12, y: 12)
            )
        )

        XCTAssertTrue(
            Self.colorsApproximatelyEqual(inactiveColor, referenceColor, tolerance: 0.01),
            "Expected inactive memory segment fills to use the shared neutral chart tone. inactive=\(Self.debugColor(inactiveColor)) reference=\(Self.debugColor(referenceColor))"
        )
    }

    func testRAMSegmentBarsLayoutKeepsOriginalSlotBudgetWithoutSamples() {
        XCTAssertEqual(
            RAMSegmentBarsLayout.displaySampleBudget(for: CGSize(width: 1_000, height: 60)),
            96
        )
        XCTAssertEqual(
            RAMSegmentBarsLayout.displaySampleBudget(for: CGSize(width: 20, height: 60)),
            12
        )

        let slots = RAMSegmentBarsLayout.displaySlots(
            for: [],
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 305)
        )

        XCTAssertEqual(slots.count, 20)
        XCTAssertEqual(
            Array(Set(slots.map(\.bucketStart))).sorted(),
            [300].map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
        XCTAssertTrue(slots.allSatisfy { $0.sample == nil })
    }

    func testRAMSegmentBarsLayoutAveragesSamplesInsideSameMinute() {
        let samples = [
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 241),
                pressurePercent: 20,
                usedBytes: 200,
                totalBytes: 1_000,
                breakdown: MemoryBreakdown(
                    wiredBytes: 40,
                    activeBytes: 120,
                    compressedBytes: 40,
                    cachedBytes: 200,
                    availableBytes: 800
                )
            ),
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 269),
                pressurePercent: 40,
                usedBytes: 400,
                totalBytes: 1_000,
                breakdown: MemoryBreakdown(
                    wiredBytes: 80,
                    activeBytes: 240,
                    compressedBytes: 80,
                    cachedBytes: 300,
                    availableBytes: 600
                )
            ),
        ]

        let slots = RAMSegmentBarsLayout.displaySlots(
            for: samples,
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 330)
        )
        let averagedMinute = slots.first {
            $0.bucketStart == Date(timeIntervalSince1970: 240) && $0.sample != nil
        }?.sample

        XCTAssertEqual(averagedMinute?.timestamp, Date(timeIntervalSince1970: 240))
        XCTAssertEqual(averagedMinute?.usedBytes, 300)
        XCTAssertEqual(averagedMinute?.totalBytes, 1_000)
        XCTAssertEqual(averagedMinute?.pressurePercent ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(averagedMinute?.breakdown.activeBytes, 180)
        XCTAssertEqual(averagedMinute?.breakdown.compressedBytes, 60)
        XCTAssertEqual(averagedMinute?.breakdown.wiredBytes, 60)
        XCTAssertEqual(averagedMinute?.breakdown.cachedBytes, 250)
        XCTAssertEqual(averagedMinute?.breakdown.availableBytes, 700)
        XCTAssertEqual(slots.filter { $0.bucketStart == Date(timeIntervalSince1970: 240) }.compactMap(\.sample).count, 1)
    }

    func testRAMSegmentBarsLayoutRightmostSlotUsesLatestSampleAndLeavesOtherCurrentMinuteSlotsEmpty() {
        let firstSamples = [
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 301),
                pressurePercent: 80,
                usedBytes: 800,
                totalBytes: 1_000
            ),
        ]
        let updatedSamples = firstSamples + [
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 330),
                pressurePercent: 20,
                usedBytes: 200,
                totalBytes: 1_000
            ),
        ]

        let firstSlots = RAMSegmentBarsLayout.displaySlots(
            for: firstSamples,
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 330)
        )
        let updatedSlots = RAMSegmentBarsLayout.displaySlots(
            for: updatedSamples,
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 330)
        )

        XCTAssertEqual(firstSlots.last?.sample?.usedBytes, 800)
        XCTAssertNil(updatedSlots[16].sample)
        XCTAssertNil(updatedSlots[17].sample)
        XCTAssertNil(updatedSlots[18].sample)
        XCTAssertEqual(updatedSlots.last?.sample?.usedBytes, 200)
        XCTAssertEqual(firstSlots.last?.sample?.timestamp, Date(timeIntervalSince1970: 301))
        XCTAssertEqual(updatedSlots.last?.sample?.timestamp, Date(timeIntervalSince1970: 330))
    }

    func testRAMSegmentBarsLayoutCompactsSampledBucketsIntoTrailingAdjacentSlots() {
        let samples = [
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 65),
                pressurePercent: 10,
                usedBytes: 100,
                totalBytes: 1_000
            ),
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 245),
                pressurePercent: 40,
                usedBytes: 400,
                totalBytes: 1_000
            ),
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 301),
                pressurePercent: 50,
                usedBytes: 500,
                totalBytes: 1_000
            ),
        ]

        let slots = RAMSegmentBarsLayout.displaySlots(
            for: samples,
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 305)
        )

        XCTAssertEqual(
            slots.enumerated().compactMap { index, slot in
                slot.sample == nil ? nil : index
            },
            [17, 18, 19]
        )
        XCTAssertEqual(slots[17].sample?.usedBytes, 100)
        XCTAssertEqual(slots[18].sample?.usedBytes, 400)
        XCTAssertEqual(slots[19].sample?.usedBytes, 500)
    }

    func testRAMSegmentBarsLayoutIncludesFullRetainedHistoryInsteadOfFiveMinuteWindow() {
        let samples = [
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 305),
                pressurePercent: 30,
                usedBytes: 300,
                totalBytes: 1_000
            ),
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 1_201),
                pressurePercent: 50,
                usedBytes: 500,
                totalBytes: 1_000
            ),
        ]

        let slots = RAMSegmentBarsLayout.displaySlots(
            for: samples,
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 1_205)
        )

        XCTAssertEqual(
            slots.compactMap { $0.sample?.usedBytes },
            [300, 500]
        )
        XCTAssertEqual(slots.last?.sample?.usedBytes, 500)
    }

    func testRAMSegmentBarsLayoutCompactsDenseHistoryAndPreservesLatestSampleSemantics() {
        var samples: [DashboardMemoryTrendSample] = []
        for minute in 0..<40 {
            let timestamp = Date(timeIntervalSince1970: TimeInterval(minute * 60 + 5))
            samples.append(
                DashboardMemoryTrendSample(
                    timestamp: timestamp,
                    pressurePercent: Double(minute),
                    usedBytes: UInt64(minute),
                    totalBytes: 1_000
                )
            )
        }

        let slots = RAMSegmentBarsLayout.displaySlots(
            for: samples,
            containerSize: CGSize(width: 20, height: 60),
            referenceDate: Date(timeIntervalSince1970: 39 * 60 + 5)
        )

        XCTAssertEqual(slots.count, 12)
        XCTAssertEqual(slots.last?.valueSemantics, .latestSample)
        XCTAssertEqual(slots.last?.sample?.timestamp, Date(timeIntervalSince1970: 39 * 60 + 5))
        XCTAssertEqual(slots.last?.sample?.usedBytes, 39)
        XCTAssertEqual(slots.compactMap { $0.sample }.count, 12)
    }

    func testRAMSegmentBarsLayoutDropsEmptyCompactedGroups() {
        let bucketStart = Date(timeIntervalSince1970: 60)
        let slots = RAMSegmentBarsLayout.compactedSampleSlots(
            [
                RAMSegmentBarSlot(
                    bucketStart: Date(timeIntervalSince1970: 0),
                    sample: nil
                ),
                RAMSegmentBarSlot(
                    bucketStart: bucketStart,
                    sample: DashboardMemoryTrendSample(
                        timestamp: bucketStart,
                        pressurePercent: 40,
                        usedBytes: 400,
                        totalBytes: 1_000
                    )
                ),
                RAMSegmentBarSlot(
                    bucketStart: Date(timeIntervalSince1970: 120),
                    sample: nil
                ),
            ],
            slotCount: 2
        )

        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.bucketStart, bucketStart)
        XCTAssertEqual(slots.first?.sample?.usedBytes, 400)
    }

    func testRAMSegmentBarsLayoutAveragesPressureWhenTotalMemoryIsZero() {
        let samples = [
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 241),
                pressurePercent: 20,
                usedBytes: 0,
                totalBytes: 0
            ),
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 269),
                pressurePercent: 60,
                usedBytes: 0,
                totalBytes: 0
            ),
        ]

        let slots = RAMSegmentBarsLayout.displaySlots(
            for: samples,
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 330)
        )
        let averagedMinute = slots.first {
            $0.bucketStart == Date(timeIntervalSince1970: 240) && $0.sample != nil
        }?.sample

        XCTAssertEqual(averagedMinute?.totalBytes, 0)
        XCTAssertEqual(averagedMinute?.pressurePercent ?? 0, 40, accuracy: 0.001)
    }

    func testRAMSegmentTooltipTimeLabelShowsBucketEndForAveragesAndTimestampForLatestSample() {
        let bucketStart = Date(timeIntervalSince1970: 300)
        let latestTimestamp = Date(timeIntervalSince1970: 330)
        let averagedSlot = RAMSegmentBarSlot(
            bucketStart: bucketStart,
            sample: DashboardMemoryTrendSample(
                timestamp: bucketStart,
                pressurePercent: 50,
                usedBytes: 500,
                totalBytes: 1_000
            ),
            valueSemantics: .minuteAverage
        )
        let latestSlot = RAMSegmentBarSlot(
            bucketStart: bucketStart,
            sample: DashboardMemoryTrendSample(
                timestamp: latestTimestamp,
                pressurePercent: 20,
                usedBytes: 200,
                totalBytes: 1_000
            ),
            valueSemantics: .latestSample
        )
        let emptyLatestSlot = RAMSegmentBarSlot(
            bucketStart: bucketStart,
            sample: nil,
            valueSemantics: .latestSample
        )

        XCTAssertEqual(
            RAMSegmentBarsLayout.tooltipTimeLabel(for: averagedSlot),
            AppLocalization.formattedTime(bucketStart.addingTimeInterval(60))
        )
        XCTAssertEqual(
            RAMSegmentBarsLayout.tooltipTimeLabel(for: latestSlot),
            AppLocalization.formattedTime(latestTimestamp, includesSeconds: true)
        )
        XCTAssertEqual(
            RAMSegmentBarsLayout.tooltipTimeLabel(for: emptyLatestSlot),
            AppLocalization.formattedTime(bucketStart.addingTimeInterval(60))
        )
    }

    func testRAMSegmentAccessibilityLabelsDescribeEmptyAndLatestSamples() {
        let sample = DashboardMemoryTrendSample(
            timestamp: Date(timeIntervalSince1970: 39 * 60 + 5),
            pressurePercent: 50,
            usedBytes: 500,
            totalBytes: 1_000
        )

        XCTAssertEqual(
            RAMSegmentBarsLayout.accessibilityLabel(for: nil),
            AppLocalization.string(.memoryChartCollectingSamples)
        )
        XCTAssertEqual(
            RAMSegmentBarsLayout.accessibilityLabel(for: sample),
            AppLocalization.memoryChartAccessibilityLabel(
                pressurePercent: 50,
                usedMemory: DashboardMetricTextFormatter.formatMemoryGB(500),
                totalMemory: DashboardMetricTextFormatter.formatMemoryGB(1_000)
            )
        )
    }

    func testRenderedRAMSegmentBarsShowsTooltipForInitialHoveredSlot() {
        let sample = DashboardMemoryTrendSample(
            timestamp: Date(timeIntervalSince1970: 39 * 60 + 5),
            pressurePercent: 50,
            usedBytes: 500,
            totalBytes: 1_000,
            breakdown: MemoryBreakdown(
                wiredBytes: 100,
                activeBytes: 300,
                compressedBytes: 100
            )
        )
        let content = RAMSegmentBars(
            trend: DashboardMemoryTrend(samples: [sample]),
            hoveredSlotIndex: 19
        )
        .frame(width: 100, height: 60)

        XCTAssertNotNil(Self.renderedColor(of: content, atTopLeft: CGPoint(x: 78, y: 20)))
    }

    func testRAMSegmentBarsLayoutKeepsMissingMinutesEmpty() {
        let samples = [
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 65),
                pressurePercent: 10,
                usedBytes: 100,
                totalBytes: 1_000
            ),
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 245),
                pressurePercent: 40,
                usedBytes: 400,
                totalBytes: 1_000
            ),
        ]

        let slots = RAMSegmentBarsLayout.displaySlots(
            for: samples,
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 305)
        )

        XCTAssertEqual(
            Array(Set(slots.map(\.bucketStart))).sorted(),
            [60, 120, 180, 240, 300].map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
        XCTAssertEqual(
            Array(Set(slots.compactMap { $0.sample?.usedBytes })).sorted(),
            [100, 400]
        )
        XCTAssertEqual(slots.filter { $0.bucketStart == Date(timeIntervalSince1970: 120) }.compactMap(\.sample).count, 0)
        XCTAssertEqual(slots.filter { $0.bucketStart == Date(timeIntervalSince1970: 180) }.compactMap(\.sample).count, 0)
        XCTAssertEqual(slots.filter { $0.bucketStart == Date(timeIntervalSince1970: 300) }.compactMap(\.sample).count, 0)
    }

    func testRAMSegmentBarsLayoutIgnoresSamplesAfterReferenceDate() {
        let samples = [
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 305),
                pressurePercent: 30,
                usedBytes: 300,
                totalBytes: 1_000
            ),
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 1_210),
                pressurePercent: 90,
                usedBytes: 900,
                totalBytes: 1_000
            ),
        ]

        let slots = RAMSegmentBarsLayout.displaySlots(
            for: samples,
            containerSize: CGSize(width: 100, height: 60),
            referenceDate: Date(timeIntervalSince1970: 1_205)
        )

        XCTAssertEqual(
            slots.compactMap { $0.sample?.usedBytes },
            [300]
        )
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

    private static func preferencesController(initial: AppPreferences = .default) -> PreferencesController {
        PreferencesController(
            store: DashboardCardLayoutPreferencesStore(initial: initial),
            launchService: NoopLaunchAtLoginService()
        )
    }

    private static func renderedColor<Content: View>(
        of view: Content,
        atTopLeft point: CGPoint
    ) -> NSColor? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        let x = Int(point.x.rounded(.down))
        let y = Int(point.y.rounded(.down))
        let pixelY = bitmap.pixelsHigh - y - 1

        guard (0..<bitmap.pixelsWide).contains(x),
              (0..<bitmap.pixelsHigh).contains(pixelY)
        else {
            return nil
        }

        return bitmap.colorAt(x: x, y: pixelY)?.usingColorSpace(.deviceRGB)
    }

    private static func colorsApproximatelyEqual(
        _ lhs: NSColor,
        _ rhs: NSColor,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) <= tolerance
        && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
        && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
        && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
    }

    private static func debugColor(_ color: NSColor) -> String {
        String(
            format: "(r: %.3f g: %.3f b: %.3f a: %.3f)",
            color.redComponent,
            color.greenComponent,
            color.blueComponent,
            color.alphaComponent
        )
    }
}

private final class DashboardCardLayoutPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private var value: AppPreferences

    init(initial: AppPreferences) {
        self.value = initial
    }

    func load() -> AppPreferences {
        value
    }

    func save(_ preferences: AppPreferences) throws {
        value = preferences
    }
}
