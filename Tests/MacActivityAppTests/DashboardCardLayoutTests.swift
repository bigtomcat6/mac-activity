import CoreGraphics
import AppKit
import SwiftUI
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardCardLayoutTests: XCTestCase {
    func testDashboardTabsIncludeEnergyImpactAndAudioAsSeparatePages() {
        XCTAssertEqual(DashboardTab.allCases, [.overview, .actives, .energyImpact, .audio])
        XCTAssertEqual(DashboardTab.energyImpact.title, AppLocalization.string(.dashboardTabEnergyImpact))
        XCTAssertEqual(DashboardTab.audio.title, AppLocalization.string(.dashboardTabAudio))
    }

    func testDashboardTabsUseStableIconSymbolPairs() {
        XCTAssertEqual(DashboardTab.overview.systemImage, "square.grid.2x2")
        XCTAssertEqual(DashboardTab.overview.selectedSystemImage, "square.grid.2x2.fill")
        XCTAssertEqual(DashboardTab.actives.systemImage, "list.bullet.rectangle")
        XCTAssertEqual(DashboardTab.actives.selectedSystemImage, "list.bullet.rectangle.fill")
        XCTAssertEqual(DashboardTab.energyImpact.systemImage, "bolt")
        XCTAssertEqual(DashboardTab.energyImpact.selectedSystemImage, "bolt.fill")
        XCTAssertEqual(DashboardTab.audio.systemImage, "speaker.wave.2")
        XCTAssertEqual(DashboardTab.audio.selectedSystemImage, "speaker.wave.2.fill")
    }

    func testDashboardMotionDefinesTabSelectionDuration() {
        XCTAssertEqual(DashboardMotion.tabSelectionDuration, 0.28, accuracy: 0.001)
    }

    func testSelectingActivesTabAdvancesActivesRefreshTrigger() {
        XCTAssertEqual(
            DashboardView.activesRefreshTrigger(afterSelecting: .overview, currentTrigger: 4),
            4
        )
        XCTAssertEqual(
            DashboardView.activesRefreshTrigger(afterSelecting: .audio, currentTrigger: 4),
            4
        )
        XCTAssertEqual(
            DashboardView.activesRefreshTrigger(afterSelecting: .actives, currentTrigger: 4),
            5
        )
    }

    func testEnergyImpactRefreshTriggerOnlyChangesForEnergyImpactTab() {
        XCTAssertEqual(
            DashboardView.energyImpactRefreshTrigger(afterSelecting: .energyImpact, currentTrigger: 3),
            4
        )
        XCTAssertEqual(
            DashboardView.energyImpactRefreshTrigger(afterSelecting: .actives, currentTrigger: 3),
            3
        )
        XCTAssertEqual(
            DashboardView.energyImpactRefreshTrigger(afterSelecting: .audio, currentTrigger: 3),
            3
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
            .battery
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

    func testOverviewMetricTitleIconsUseCompactSpacing() {
        XCTAssertEqual(DashboardOverviewLayout.metricTitleIconSpacing, 4)
    }

    func testOverviewStorageDetailUsesNativeSymbolsForDiskAndSwap() {
        XCTAssertEqual(DashboardOverviewLayout.storageDetailIconName(for: .disk), "externaldrive")
        XCTAssertEqual(DashboardOverviewLayout.storageDetailIconName(for: .swap), "memorychip")
        XCTAssertNil(DashboardOverviewLayout.storageDetailIconName(for: .cpu))
    }

    func testOverviewMetricIconsUseApprovedNativeSymbols() {
        let expectations: [(MetricKind, String?)] = [
            (.cpu, "cpu"),
            (.gpu, "display"),
            (.disk, "externaldrive"),
            (.swap, "memorychip"),
            (.memory, "memorychip"),
            (.vram, nil),
            (.network, "network"),
            (.battery, "battery.100"),
            (.temperature, "thermometer"),
            (.fan, "fanblades")
        ]

        for (kind, expectedIconName) in expectations {
            XCTAssertEqual(
                DashboardOverviewLayout.metricIconName(for: kind),
                expectedIconName,
                "Unexpected Overview icon for \(kind)"
            )
        }
    }

    func testOverviewStorageDetailIconsUseSharedMetricIconMappingOnlyForStorageMetrics() {
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailIconName(for: .disk),
            DashboardOverviewLayout.metricIconName(for: .disk)
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailIconName(for: .swap),
            DashboardOverviewLayout.metricIconName(for: .swap)
        )
        XCTAssertNil(DashboardOverviewLayout.storageDetailIconName(for: .cpu))
        XCTAssertNil(DashboardOverviewLayout.storageDetailIconName(for: .memory))
    }

    func testOverviewStorageDetailHidesSwapPercent() {
        let disk = DashboardMetric(
            kind: .disk,
            value: "80%",
            detailRole: .raw("800 B (80%)"),
            title: "Disk",
            detail: "800 B (80%)",
            usedBytes: 800
        )
        let swap = DashboardMetric(
            kind: .swap,
            value: "25%",
            detailRole: .raw("256 B (25%)"),
            title: "Swap",
            detail: "256 B (25%)",
            usedBytes: 256
        )

        XCTAssertEqual(DashboardOverviewLayout.storageDetailValue(for: disk), "800 B (80%)")
        XCTAssertEqual(DashboardOverviewLayout.storageDetailValue(for: swap), "256 B")
    }

    func testOverviewStorageCardShowsDetailsAboveUsageBar() {
        XCTAssertEqual(DashboardOverviewLayout.storageCardContentOrder, [.details, .bar])
    }

    func testOverviewStorageSegmentsUseDiskTotalAsSharedDenominatorAndOverlaySwap() {
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
            )
        ]

        let segments = DashboardOverviewLayout.storageUsageSegments(for: metrics)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].kind, .disk)
        XCTAssertEqual(segments[0].startProgress, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].widthProgress, 0.8, accuracy: 0.001)
        XCTAssertEqual(segments[1].kind, .swap)
        XCTAssertEqual(segments[1].startProgress, 0.7, accuracy: 0.001)
        XCTAssertEqual(segments[1].widthProgress, 0.1, accuracy: 0.001)
    }

    func testOverviewStorageSwapSegmentOverlaysDiskInsteadOfExtendingUsage() throws {
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
                usedBytes: 300,
                totalBytes: 600,
                progress: 0.5
            )
        ]

        let segments = DashboardOverviewLayout.storageUsageSegments(for: metrics)
        let swapSegment = try XCTUnwrap(segments.first { $0.kind == .swap })

        XCTAssertEqual(swapSegment.startProgress, 0.5, accuracy: 0.001)
        XCTAssertEqual(swapSegment.widthProgress, 0.3, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(segments.map { $0.startProgress + $0.widthProgress }.max()),
            0.8,
            accuracy: 0.001
        )
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
            )
        ]

        XCTAssertEqual(
            DashboardOverviewLayout.storageUsageSegments(for: metrics),
            [
                DashboardStorageUsageSegment(kind: .disk, startProgress: 0.0, widthProgress: 0.4)
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
            )
        ]

        XCTAssertEqual(
            DashboardOverviewLayout.storageUsageSegments(for: smallSwapMetrics),
            [
                DashboardStorageUsageSegment(kind: .disk, startProgress: 0.0, widthProgress: 0.4),
                DashboardStorageUsageSegment(kind: .swap, startProgress: 0.38, widthProgress: 0.02)
            ]
        )
    }

    func testOverviewStorageSwapMinimumVisibleWidthDoesNotExtendBeyondDiskUsage() throws {
        let metrics = [
            DashboardMetric(
                kind: .disk,
                title: "Disk",
                value: "1%",
                usedBytes: 10,
                totalBytes: 1_000,
                progress: 0.01
            ),
            DashboardMetric(
                kind: .swap,
                title: "Swap",
                value: "1%",
                usedBytes: 1,
                totalBytes: 100,
                progress: 0.01
            )
        ]

        let segments = DashboardOverviewLayout.storageUsageSegments(for: metrics)
        let swapSegment = try XCTUnwrap(segments.first { $0.kind == .swap })

        XCTAssertEqual(swapSegment.startProgress, 0.0, accuracy: 0.001)
        XCTAssertEqual(swapSegment.widthProgress, 0.01, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(segments.map { $0.startProgress + $0.widthProgress }.max()),
            0.01,
            accuracy: 0.001
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
            )
        ]

        XCTAssertEqual(
            DashboardOverviewLayout.storageUsageSegments(for: metrics),
            [
                DashboardStorageUsageSegment(kind: .disk, startProgress: 0.0, widthProgress: 0.2),
                DashboardStorageUsageSegment(kind: .swap, startProgress: 0.5, widthProgress: 0.25)
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
            )
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
            )
        ]

        let labels = DashboardOverviewLayout.storageUsageLabels(for: metrics)

        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels[0].kind, .disk)
        XCTAssertEqual(labels[0].startProgress, 0.0, accuracy: 0.001)
        XCTAssertEqual(labels[0].rowIndex, 0)
        XCTAssertEqual(labels[0].endProgress, 0.8)
        XCTAssertEqual(labels[1].kind, .swap)
        XCTAssertEqual(labels[1].startProgress, 0.7, accuracy: 0.001)
        XCTAssertEqual(labels[1].rowIndex, 1)
        XCTAssertEqual(labels[1].endProgress, 0.8)
    }

    func testOverviewStorageConnectorsStartBelowTheirLabelRows() {
        let labels = [
            DashboardStorageUsageLabel(kind: .disk, startProgress: 0.0, rowIndex: 0),
            DashboardStorageUsageLabel(kind: .swap, startProgress: 0.8, rowIndex: 1)
        ]

        XCTAssertEqual(DashboardOverviewLayout.storageConnectorYPosition(for: labels[0]), 14, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.storageConnectorHeight(for: labels[0]), 20, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.storageConnectorYPosition(for: labels[1]), 30, accuracy: 0.001)
        XCTAssertEqual(DashboardOverviewLayout.storageConnectorHeight(for: labels[1]), 4, accuracy: 0.001)
    }

    func testOverviewStorageDetailMarkersAlignDiskIconAndSwapSegmentCenter() {
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
            )
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
            443,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailMarkerXPosition(
                for: swapLabel,
                containerWidth: 600
            ),
            450,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailRowXPosition(
                for: swapLabel,
                containerWidth: 600
            ) + DashboardOverviewLayout.storageDetailIconCenterOffset,
            DashboardOverviewLayout.storageDetailMarkerXPosition(
                for: swapLabel,
                containerWidth: 600
            ),
            accuracy: 0.001
        )
    }

    func testOverviewStorageSwapLabelFallsBackToTrailingWhenStartLeavesTooLittleRoom() {
        let diskLabel = DashboardStorageUsageLabel(kind: .disk, startProgress: 0.0, rowIndex: 0)
        let swapLabel = DashboardStorageUsageLabel(kind: .swap, startProgress: 0.9, rowIndex: 1, endProgress: 1.0)

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
            178,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailRowAlignment(
                for: swapLabel,
                containerWidth: 180
            ),
            .trailing
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailRowTextAlignment(
                for: swapLabel,
                containerWidth: 180
            ),
            .trailing
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailMarkerXPosition(
                for: swapLabel,
                containerWidth: 180
            ),
            171,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardOverviewLayout.storageDetailRowXPosition(
                for: swapLabel,
                containerWidth: 180
            ) + DashboardOverviewLayout.storageDetailRowWidth(
                for: swapLabel,
                containerWidth: 180
            ) - DashboardOverviewLayout.storageDetailIconCenterOffset,
            DashboardOverviewLayout.storageDetailMarkerXPosition(
                for: swapLabel,
                containerWidth: 180
            ),
            accuracy: 0.001
        )
    }

    func testOverviewCompactTrendCardsUseAdaptiveTextWidthForRequestedMetrics() {
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .temperature))
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .fan))
        XCTAssertTrue(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .battery))
        XCTAssertFalse(DashboardOverviewLayout.trendReadoutUsesIntrinsicWidth(for: .memory))
    }

    func testOverviewDataOnlyMetricHeadersHideTitleTextButKeepIcons() {
        XCTAssertFalse(DashboardOverviewLayout.overviewCardShowsTitleText(for: .memory))
        XCTAssertFalse(DashboardOverviewLayout.overviewCardShowsTitleText(for: .network))
        XCTAssertFalse(DashboardOverviewLayout.overviewCardShowsTitleText(for: .battery))
        XCTAssertTrue(DashboardOverviewLayout.overviewCardShowsTitleText(for: .temperature))
        XCTAssertTrue(DashboardOverviewLayout.overviewCardShowsTitleText(for: .fan))
    }

    func testOverviewFanReadoutValuesUseTwoRowsOnlyForDualFanMetrics() {
        let dualFan = DashboardMetric(
            kind: .fan,
            value: "1800 RPM",
            secondaryText: "3100 RPM",
            style: .chart
        )
        let singleFan = DashboardMetric(kind: .fan, value: "1800 RPM", style: .chart)
        let temperature = DashboardMetric(
            kind: .temperature,
            value: "42.0 C",
            secondaryText: "31.0 C",
            style: .chart
        )

        XCTAssertEqual(DashboardOverviewLayout.fanReadoutValues(for: dualFan), ["1800 RPM", "3100 RPM"])
        XCTAssertEqual(DashboardOverviewLayout.fanReadoutValues(for: singleFan), ["1800 RPM"])
        XCTAssertEqual(DashboardOverviewLayout.fanReadoutValues(for: temperature), ["42.0 C"])
        XCTAssertTrue(DashboardOverviewLayout.compactTrendUsesDualFanReadout(for: dualFan))
        XCTAssertFalse(DashboardOverviewLayout.compactTrendUsesDualFanReadout(for: singleFan))
        XCTAssertFalse(DashboardOverviewLayout.compactTrendUsesDualFanReadout(for: temperature))
    }

    func testOverviewFansUseTopReadoutAndShorterChartWithoutGrowingCard() {
        let dualFan = DashboardMetric(
            kind: .fan,
            value: "1800 RPM",
            secondaryText: "3100 RPM",
            style: .chart
        )
        let singleFan = DashboardMetric(kind: .fan, value: "1800 RPM", style: .chart)

        for metric in [singleFan, dualFan] {
            XCTAssertTrue(DashboardOverviewLayout.compactTrendUsesTopFanReadout(for: metric))
            XCTAssertTrue(DashboardOverviewLayout.compactTrendUsesTopReadout(for: metric))
            XCTAssertTrue(
                DashboardOverviewLayout.compactTrendShowsTopReadout(for: metric, isHovered: false)
            )
            XCTAssertFalse(
                DashboardOverviewLayout.compactTrendShowsTopReadout(for: metric, isHovered: true)
            )
            XCTAssertEqual(
                DashboardOverviewLayout.trendChartHeight(for: metric),
                DashboardOverviewLayout.compactFanTrendChartHeight
            )
            XCTAssertEqual(
                DashboardOverviewLayout.trendChartHeight(for: metric, isHovered: true),
                DashboardOverviewLayout.compactTrendChartHeight
            )
        }

        XCTAssertLessThan(
            DashboardOverviewLayout.compactFanTrendChartHeight,
            DashboardOverviewLayout.compactTrendChartHeight
        )
        XCTAssertEqual(DashboardOverviewLayout.metricTitleIconSpacing, 4)
        XCTAssertEqual(DashboardOverviewLayout.compactTrendCardHeight, 64)
    }

    func testOverviewCPUTemperatureUsesTopReadoutAndShorterChartWithoutGrowingCard() {
        let temperature = DashboardMetric(
            kind: .temperature,
            titleRole: .temperature(.smc),
            value: "42.0 C",
            style: .chart
        )
        let batteryTemperature = DashboardMetric(
            kind: .temperature,
            titleRole: .temperature(.battery),
            value: "31.0 C",
            style: .chart
        )
        let fallbackTemperature = DashboardMetric(
            kind: .temperature,
            value: "41.0 C",
            style: .chart
        )

        XCTAssertTrue(DashboardOverviewLayout.compactTrendUsesTopReadout(for: temperature))
        XCTAssertTrue(
            DashboardOverviewLayout.compactTrendShowsTopReadout(
                for: temperature,
                isHovered: false
            )
        )
        XCTAssertFalse(
            DashboardOverviewLayout.compactTrendShowsTopReadout(
                for: temperature,
                isHovered: true
            )
        )
        XCTAssertEqual(DashboardOverviewLayout.compactTrendReadoutTitle(for: temperature), "CPU")
        XCTAssertEqual(
            DashboardOverviewLayout.compactTrendReadoutTitle(for: batteryTemperature),
            AppLocalization.temperatureSourceTitle(for: .battery)
        )
        XCTAssertEqual(
            DashboardOverviewLayout.compactTrendReadoutTitle(for: fallbackTemperature),
            AppLocalization.dashboardMetricTitle(for: fallbackTemperature)
        )
        XCTAssertEqual(
            DashboardOverviewLayout.trendChartHeight(for: temperature),
            DashboardOverviewLayout.compactFanTrendChartHeight
        )
        XCTAssertEqual(
            DashboardOverviewLayout.trendChartHeight(for: temperature, isHovered: true),
            DashboardOverviewLayout.compactTrendChartHeight
        )
        XCTAssertEqual(DashboardOverviewLayout.metricIconName(for: .temperature), "thermometer")
        XCTAssertEqual(DashboardOverviewLayout.compactTrendCardHeight, 64)
    }

    func testDashboardRegionsRevealOneNativeBackdrop() throws {
        let source = try Self.dashboardViewSource()
        XCTAssertFalse(source.contains("DashboardCardChrome.canvasColor"))
        XCTAssertFalse(
            source.contains("GlassEffectContainer"),
            "glass cards must not be extracted into a container outside the scroll clip"
        )
        XCTAssertEqual(
            source.components(separatedBy: "DashboardRootGlassBackground(").count - 1,
            1,
            "the transparent style must add exactly one root glass background"
        )
        XCTAssertTrue(source.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(source.contains("dashboardShellSurface"))
    }

    func testDashboardKeepsMeasuredButInvisibleSeparators() throws {
        let source = try Self.dashboardViewSource()
        let start = try XCTUnwrap(source.range(of: "segment: .headerDivider,"))
        let remaining = source[start.upperBound...]
        let end = try XCTUnwrap(remaining.range(of: "}"))
        let separator = remaining[..<end.lowerBound]
        XCTAssertTrue(separator.contains("Divider()"))
        XCTAssertTrue(separator.contains(".hidden()"))
    }

    func testDashboardCardsShareActivesSurfaceChrome() {
        XCTAssertEqual(DashboardCardChrome.cornerRadius, ActiveCleanupChrome.cornerRadius)
        XCTAssertEqual(
            DashboardCardChrome.borderOpacity(isHovered: false),
            ActiveCleanupChrome.borderOpacity,
            accuracy: 0.001
        )
    }

    func testRaisedCardUsesCompactRadiusAndPreservesHoverEmphasis() {
        XCTAssertEqual(DashboardCardChrome.cornerRadius, 12)
        XCTAssertGreaterThan(
            DashboardCardChrome.borderOpacity(isHovered: true),
            DashboardCardChrome.borderOpacity(isHovered: false)
        )
    }

    func testReducedTransparencyCardHasOpaqueSurfaceAndExternalShadowInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let card = Color.clear
                .frame(width: 80, height: 40)
                .dashboardCardChrome()
                .padding(16)
                .environment(\.colorScheme, scheme)
                .environment(\._accessibilityReduceTransparency, true)
            let surface = try XCTUnwrap(Self.renderedColor(
                of: card, atTopLeft: CGPoint(x: 56, y: 36)
            ))
            let shadow = try XCTUnwrap(Self.renderedColor(
                of: card, atTopLeft: CGPoint(x: 56, y: 58)
            ))
            let expected = try XCTUnwrap(Self.renderedColor(
                of: DashboardCardChrome.surfaceColor(for: scheme)
                    .frame(width: 80, height: 40),
                atTopLeft: CGPoint(x: 40, y: 20)
            ))
            XCTAssertGreaterThan(surface.alphaComponent, 0.99)
            XCTAssertTrue(Self.colorsApproximatelyEqual(surface, expected, tolerance: 0.02))
            XCTAssertGreaterThan(shadow.alphaComponent, 0.001)
            XCTAssertLessThan(shadow.alphaComponent, 0.4)
        }
    }

    func testCleanupAndDashboardUseTheSameRenderedSurface() throws {
        for scheme in [ColorScheme.light, .dark] {
            let dashboard = Color.clear.frame(width: 80, height: 40)
                .dashboardCardChrome().padding(16)
                .environment(\.colorScheme, scheme)
                .environment(\._accessibilityReduceTransparency, true)
            let cleanup = Color.clear.frame(width: 80, height: 40)
                .activeCleanupCardChrome().padding(16)
                .environment(\.colorScheme, scheme)
                .environment(\._accessibilityReduceTransparency, true)
            for point in [CGPoint(x: 56, y: 36), CGPoint(x: 56, y: 58)] {
                let first = try XCTUnwrap(Self.renderedColor(of: dashboard, atTopLeft: point))
                let second = try XCTUnwrap(Self.renderedColor(of: cleanup, atTopLeft: point))
                XCTAssertTrue(Self.colorsApproximatelyEqual(first, second, tolerance: 0.02))
            }
        }
    }

    func testRaisedCardDoesNotChangeItsLayoutSize() throws {
        let plain = ImageRenderer(content: Color.clear.frame(width: 80, height: 40))
        let raised = ImageRenderer(content: Color.clear.frame(width: 80, height: 40)
            .dashboardCardChrome())
        XCTAssertEqual(try XCTUnwrap(plain.nsImage).size, try XCTUnwrap(raised.nsImage).size)
    }

    func testDashboardCardsIncreaseBorderEmphasisOnHover() {
        XCTAssertGreaterThan(
            DashboardCardChrome.borderOpacity(isHovered: true),
            DashboardCardChrome.borderOpacity(isHovered: false)
        )
    }

    func testHeaderUsesCompactInlineTitleAndTabPickerChrome() {
        XCTAssertEqual(DashboardHeaderChrome.horizontalPadding, 18)
        XCTAssertEqual(DashboardHeaderChrome.topPadding, 18)
        XCTAssertEqual(DashboardHeaderChrome.bottomPadding, 12)
        XCTAssertEqual(DashboardHeaderChrome.titlePickerSpacing, 12)
        XCTAssertEqual(DashboardHeaderChrome.tabPickerMinWidth, 160)
    }

    func testDashboardTabBarUsesCompactIconChrome() {
        XCTAssertEqual(DashboardTabChrome.iconButtonWidth, 30)
        XCTAssertEqual(DashboardTabChrome.iconButtonHeight, 20)
        XCTAssertEqual(DashboardTabChrome.itemSpacing, 2)
        XCTAssertEqual(DashboardTabChrome.trackPadding, 2)
        XCTAssertEqual(DashboardTabChrome.trackFillOpacity, 0.06, accuracy: 0.001)
        XCTAssertEqual(DashboardTabChrome.selectedFillOpacity, 0.12, accuracy: 0.001)
        XCTAssertEqual(DashboardTabChrome.hoverFillOpacity, 0.06, accuracy: 0.001)
        XCTAssertEqual(DashboardTabChrome.focusRingWidth, 2)
    }

    func testDashboardTabBarUsesIconButtonsWithAccessibilityAndMotion() throws {
        let dashboardSource = try Self.dashboardViewSource()

        XCTAssertTrue(dashboardSource.contains("DashboardTabBar(selection: selectedTabBinding)"))
        XCTAssertFalse(dashboardSource.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(dashboardSource.contains("matchedGeometryEffect(id: \"tabSelection\""))
        XCTAssertTrue(dashboardSource.contains("DashboardMotion.tabSelectionAnimation"))
        XCTAssertTrue(dashboardSource.contains(".help(tab.title)"))
        XCTAssertTrue(dashboardSource.contains(".accessibilityLabel(Text(tab.title))"))
        XCTAssertTrue(dashboardSource.contains(".accessibilityAddTraits(selection == tab ? .isSelected : [])"))
        XCTAssertTrue(dashboardSource.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(dashboardSource.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(dashboardSource.contains("accessibilityReduceMotion"))
        XCTAssertTrue(dashboardSource.contains(".onMoveCommand"))
        XCTAssertTrue(dashboardSource.contains("focusEffectDisabled()"))
        XCTAssertTrue(dashboardSource.contains("contentTransition(.symbolEffect(.replace))"))
        XCTAssertTrue(dashboardSource.contains("#available(macOS 14.0, *)"))
    }

    func testDashboardHeaderKeepsOnlyAppNameAndInlineTabPicker() throws {
        let dashboardSource = try Self.dashboardViewSource()

        XCTAssertFalse(dashboardSource.contains("summaryText"))
        XCTAssertFalse(dashboardSource.contains("liveIndicator"))
        XCTAssertFalse(dashboardSource.contains("DashboardOverviewChrome.liveIndicatorColor"))
        XCTAssertTrue(dashboardSource.contains("Text(AppLocalization.string(.appName))"))
        XCTAssertTrue(dashboardSource.contains("tabPicker"))
    }

    func testGlassAPIsAreAvailabilityGatedAndDoNotMergeCards() throws {
        let source = try Self.dashboardViewSource("ActiveCleanReleaseLayout.swift")
        XCTAssertTrue(source.contains("#available(macOS 26.0, *)"))
        XCTAssertTrue(source.contains(".glassEffect(.regular, in: shape)"))
        XCTAssertFalse(source.contains(".glassEffect(.clear"))
        XCTAssertTrue(source.contains("Color.primary.opacity"))
        XCTAssertFalse(
            source.contains("GlassEffectContainer"),
            "glass cards must render in place so the scroll clip can keep them inside the layout"
        )
        XCTAssertTrue(source.contains("accessibilityReduceTransparency"))
        XCTAssertFalse(source.contains(".interactive("))
        XCTAssertFalse(source.contains("glassEffectUnion"))
    }

    func testFallbackSurfaceRespectsReduceTransparency() throws {
        for scheme in [ColorScheme.light, .dark] {
            let surface = DashboardFallbackCardSurface()
                .frame(width: 80, height: 40)
                .padding(16)
                .environment(\.colorScheme, scheme)
                .environment(\._accessibilityReduceTransparency, true)
            let color = try XCTUnwrap(Self.renderedColor(
                of: surface, atTopLeft: CGPoint(x: 56, y: 36)
            ))
            let expected = try XCTUnwrap(Self.renderedColor(
                of: DashboardCardChrome.surfaceColor(for: scheme).frame(width: 80, height: 40),
                atTopLeft: CGPoint(x: 40, y: 20)
            ))
            XCTAssertGreaterThan(color.alphaComponent, 0.99)
            XCTAssertTrue(Self.colorsApproximatelyEqual(color, expected, tolerance: 0.02))
        }
    }

    func testActivesAndEnergyModulesUseSharedChromeWithoutRaisingRows() throws {
        for file in ["DiskCleanupStatusView.swift", "ActiveProcessMemoryList.swift"] {
            XCTAssertTrue(try Self.dashboardViewSource(file).contains(".activeCleanupCardChrome()"), file)
        }
        for file in ["PowerFlowView.swift", "EnergyImpactView.swift"] {
            XCTAssertTrue(try Self.dashboardViewSource(file).contains(".dashboardCardChrome()"), file)
        }
        let processRow = try Self.dashboardViewSource("ActiveProcessMemoryRow.swift")
        XCTAssertFalse(processRow.contains(".dashboardCardChrome("))
        XCTAssertFalse(processRow.contains(".activeCleanupCardChrome("))
        XCTAssertFalse(processRow.contains(".shadow("))
        let energy = try Self.dashboardViewSource("EnergyImpactView.swift")
        let row = try XCTUnwrap(energy.components(separatedBy: "struct EnergyImpactRow: View").last)
        XCTAssertFalse(row.contains(".dashboardCardChrome("))
        XCTAssertFalse(row.contains(".shadow("))
    }

    func testAudioRaisesSectionsAndPermissionGateButNotControlRows() throws {
        let source = try Self.dashboardViewSource("AudioDashboardView.swift")
        let sectionStart = try XCTUnwrap(source.range(of: "private struct AudioDashboardSection"))
        let rowsStart = try XCTUnwrap(source.range(of: "private struct AudioDeviceControlRow"))
        let gateStart = try XCTUnwrap(source.range(of: "private struct AudioSystemAccessPermissionGate: View"))
        let presentationStart = try XCTUnwrap(source.range(
            of: "struct AudioDashboardPresentation",
            range: gateStart.upperBound..<source.endIndex
        ))
        let sectionBody = source[sectionStart.lowerBound..<rowsStart.lowerBound]
        XCTAssertTrue(sectionBody.contains(".dashboardCardChrome()"))

        let gate = source[gateStart.lowerBound..<presentationStart.lowerBound]
        XCTAssertTrue(gate.contains(".dashboardCardChrome()"))
        XCTAssertFalse(source.contains(".quaternary.opacity(0.65)"))

        let rowsBeforeGate = source[rowsStart.lowerBound..<gateStart.lowerBound]
        XCTAssertFalse(rowsBeforeGate.contains(".dashboardCardChrome("))
        XCTAssertFalse(rowsBeforeGate.contains(".shadow("))
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

    func testDashboardRegionsLeaveClearMarginsAroundNativeBackdrop() throws {
        let model = DashboardModel(store: MetricsStore())
        let contentWidth: CGFloat = 420
        let contentHeight: CGFloat = 260
        for scheme in [ColorScheme.light, .dark] {
            let content = DashboardView(
                dashboardModel: model,
                preferencesController: Self.preferencesController(),
                audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator())
            )
            .frame(width: contentWidth, height: contentHeight)
            .environment(\.colorScheme, scheme)

            for point in [CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 130), CGPoint(x: 2, y: 254)] {
                let color = try XCTUnwrap(Self.renderedColor(of: content, atTopLeft: point))
                XCTAssertLessThan(
                    color.alphaComponent,
                    0.02,
                    "Expected a clear dashboard margin at \(point); got \(Self.debugColor(color))"
                )
            }
        }
    }

    func testRenderedOverviewDisplaysSplitStorageCardForDiskAndSwapMetrics() throws {
        let store = MetricsStore()
        store.apply(
            [
                .cpu(CPUReading(usagePercent: 25)),
                .gpu(GPUReading(usagePercent: 50)),
                .disk(DiskReading(usedBytes: 750, totalBytes: 1_000)),
                .swap(SwapReading(usedBytes: 256, totalBytes: 1_024)),
                .memory(MemoryReading(usedBytes: 600, totalBytes: 1_000))
            ],
            timestamp: Date(timeIntervalSince1970: 21)
        )
        let model = DashboardModel(store: store)
        let content = DashboardView(
            dashboardModel: model,
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
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
                .swap(SwapReading(usedBytes: 100, totalBytes: 1_000))
            ],
            timestamp: Date(timeIntervalSince1970: 22)
        )
        let storageOnlyModel = DashboardModel(store: storageOnlyStore)
        let storageOnlyContent = DashboardView(
            dashboardModel: storageOnlyModel,
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
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
                    )
                ]
            }
        )
        let content = DashboardView(
            dashboardModel: model,
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
        )
        .frame(width: 360, height: 320)

        XCTAssertNotNil(Self.renderedColor(of: content, atTopLeft: CGPoint(x: 270, y: 128)))
    }

    func testRenderedOverviewDisplaysTemperatureFanAndBatteryTrendCards() throws {
        let store = MetricsStore()
        store.apply(
            [
                .temperature(TemperatureReading(celsius: 42, source: .smc)),
                .fan(FanReading(rpm: 3_100, fanRPMs: [1_800, 3_100])),
                .battery(BatteryReading(percentage: 82, isCharging: false))
            ],
            timestamp: Date(timeIntervalSince1970: 24)
        )
        let model = DashboardModel(store: store)
        let content = DashboardView(
            dashboardModel: model,
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
        )
        .frame(width: 360, height: 320)

        let fanMetric = try XCTUnwrap(model.metrics.first { $0.kind == .fan })
        XCTAssertTrue(DashboardOverviewLayout.compactTrendUsesTopReadout(for: fanMetric))
        XCTAssertNotNil(Self.renderedColor(of: content, atTopLeft: CGPoint(x: 180, y: 128)))
    }

    func testRenderedDashboardCanStartOnActivesTab() throws {
        let store = MetricsStore()
        store.apply(
            [
                .memory(MemoryReading(usedBytes: 600, totalBytes: 1_000))
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
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            initialSelectedTab: .actives
        )
        .frame(width: 360, height: 320)

        XCTAssertNotNil(Self.renderedColor(of: content, atTopLeft: CGPoint(x: 180, y: 170)))
    }

    func testRenderedDashboardCanStartOnEnergyImpactTab() throws {
        let model = DashboardModel(store: MetricsStore())
        let content = DashboardView(
            dashboardModel: model,
            preferencesController: Self.preferencesController(
                initial: AppPreferences(
                    launchAtLoginEnabled: false,
                    selectedSummaryMetrics: AppPreferences.default.selectedSummaryMetrics,
                    showsProcessApplicationIdentifier: true
                )
            ),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            initialSelectedTab: .energyImpact
        )
        .frame(width: 360, height: 560)

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
                    )
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

    func testOverviewPrimaryLineGradientUsesNeutralTrailingToneWhenWindowIsInactive() throws {
        let inactiveColor = try XCTUnwrap(
            Self.renderedColor(
                of: Rectangle()
                    .fill(
                        DashboardOverviewChrome.chartPrimaryLineGradient(
                            baseColor: .red,
                            appearsActive: false
                        )
                    )
                    .frame(width: 24, height: 24),
                atTopLeft: CGPoint(x: 23, y: 12)
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
            Self.colorsApproximatelyEqual(inactiveColor, referenceColor, tolerance: 0.04),
            "Expected the inactive primary gradient to end with the neutral secondary tone. inactive=\(Self.debugColor(inactiveColor)) reference=\(Self.debugColor(referenceColor))"
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
            )
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
            )
        ]
        let updatedSamples = firstSamples + [
            DashboardMemoryTrendSample(
                timestamp: Date(timeIntervalSince1970: 330),
                pressurePercent: 20,
                usedBytes: 200,
                totalBytes: 1_000
            )
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
            )
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
            )
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
                )
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
            )
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
            )
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
            )
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
                RAMSegmentBarComponent(kind: .wired, bytes: 100)
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

    func testDashboardViewNoLongerRendersFooterActions() throws {
        let dashboardSource = try Self.dashboardViewSource()

        XCTAssertFalse(dashboardSource.contains("DashboardFooterChrome"))
        XCTAssertFalse(dashboardSource.contains("openPreferences"))
        XCTAssertFalse(dashboardSource.contains("quitApplication"))
        XCTAssertFalse(dashboardSource.contains("footerDivider"))
    }

    func testTranslucentCardChromePaintsAdaptivePrimaryFillWithoutGlass() throws {
        try Self.requireLiquidGlassRendering()

        let translucentAppearance = DashboardPresentationPolicy.translucentAppearance(
            moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
            strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
        )
        let card = Color.clear.frame(width: 80, height: 40)
            .dashboardCardChrome()
            .padding(16)
            .environment(\.dashboardStyleAppearance, translucentAppearance)

        let color = try XCTUnwrap(Self.renderedColor(
            of: card,
            atTopLeft: CGPoint(x: 56, y: 36)
        ))
        let expected = try XCTUnwrap(Self.renderedColor(
            of: Color.primary.opacity(DashboardPresentationPolicy.translucentModuleFillOpacity)
                .frame(width: 80, height: 40),
            atTopLeft: CGPoint(x: 40, y: 20)
        ))
        XCTAssertTrue(Self.colorsApproximatelyEqual(color, expected, tolerance: 0.03))
        XCTAssertLessThan(color.alphaComponent, 0.2)
        XCTAssertLessThan(color.redComponent, 0.3)
    }

    func testReduceTransparencyCardChromeIgnoresTranslucentAppearance() throws {
        try Self.requireLiquidGlassRendering()

        let translucentAppearance = DashboardPresentationPolicy.translucentAppearance(
            moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
            strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
        )
        let standard = Color.clear.frame(width: 80, height: 40)
            .dashboardCardChrome()
            .padding(16)
            .environment(\._accessibilityReduceTransparency, true)
        let withTranslucentEnvironment = Color.clear.frame(width: 80, height: 40)
            .dashboardCardChrome()
            .padding(16)
            .environment(\.dashboardStyleAppearance, translucentAppearance)
            .environment(\._accessibilityReduceTransparency, true)

        for point in [CGPoint(x: 56, y: 36), CGPoint(x: 56, y: 58)] {
            let expected = try XCTUnwrap(Self.renderedColor(of: standard, atTopLeft: point))
            let actual = try XCTUnwrap(Self.renderedColor(of: withTranslucentEnvironment, atTopLeft: point))
            XCTAssertTrue(Self.colorsApproximatelyEqual(expected, actual, tolerance: 0.02))
        }
    }

    func testTranslucentInactiveChromeUsesPrimaryDimming() throws {
        let translucentAppearance = DashboardPresentationPolicy.translucentAppearance(
            moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
            strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
        )
        let translucentPrimary = DashboardOverviewChrome.inactiveChartPrimaryStroke(for: translucentAppearance)
        let standardPrimary = DashboardOverviewChrome.inactiveChartPrimaryStroke(for: .standardAppearance)

        let translucentRendered = try XCTUnwrap(Self.renderedColor(
            of: Rectangle().fill(translucentPrimary).frame(width: 20, height: 20),
            atTopLeft: CGPoint(x: 10, y: 10)
        ))
        let expectedTranslucent = try XCTUnwrap(Self.renderedColor(
            of: Color.primary.opacity(0.56).frame(width: 20, height: 20),
            atTopLeft: CGPoint(x: 10, y: 10)
        ))
        let standardRendered = try XCTUnwrap(Self.renderedColor(
            of: Rectangle().fill(standardPrimary).frame(width: 20, height: 20),
            atTopLeft: CGPoint(x: 10, y: 10)
        ))
        let expectedStandard = try XCTUnwrap(Self.renderedColor(
            of: Color.black.opacity(0.56).frame(width: 20, height: 20),
            atTopLeft: CGPoint(x: 10, y: 10)
        ))

        XCTAssertTrue(Self.colorsApproximatelyEqual(translucentRendered, expectedTranslucent, tolerance: 0.02))
        XCTAssertTrue(Self.colorsApproximatelyEqual(standardRendered, expectedStandard, tolerance: 0.02))

        for (actual, expected) in [
            (
                DashboardOverviewChrome.inactiveChartSecondaryStroke(for: translucentAppearance),
                Color.primary.opacity(0.42)
            ),
            (
                DashboardOverviewChrome.inactiveMemorySegmentFill(for: translucentAppearance),
                Color.primary.opacity(0.38)
            ),
            (
                DashboardOverviewChrome.translucentInactiveEmphasisFill,
                Color.primary.opacity(0.22)
            ),
            (
                ActiveCleanupChrome.progressFillColor(appearsActive: false, appearance: translucentAppearance),
                Color.primary.opacity(0.22)
            ),
            (
                ActiveCleanupChrome.progressFillColor(appearsActive: false, appearance: .standardAppearance),
                Color.black.opacity(0.22)
            ),
        ] {
            let actualColor = try XCTUnwrap(Self.renderedColor(
                of: Rectangle().fill(actual).frame(width: 20, height: 20),
                atTopLeft: CGPoint(x: 10, y: 10)
            ))
            let expectedColor = try XCTUnwrap(Self.renderedColor(
                of: Rectangle().fill(expected).frame(width: 20, height: 20),
                atTopLeft: CGPoint(x: 10, y: 10)
            ))
            XCTAssertTrue(Self.colorsApproximatelyEqual(actualColor, expectedColor, tolerance: 0.02))
        }

        let translucentActiveProgress = try XCTUnwrap(Self.renderedColor(
            of: Rectangle()
                .fill(ActiveCleanupChrome.progressFillColor(appearsActive: true, appearance: translucentAppearance))
                .frame(width: 20, height: 20),
            atTopLeft: CGPoint(x: 10, y: 10)
        ))
        let standardActiveProgress = try XCTUnwrap(Self.renderedColor(
            of: Rectangle()
                .fill(ActiveCleanupChrome.progressFillColor(appearsActive: true, appearance: .standardAppearance))
                .frame(width: 20, height: 20),
            atTopLeft: CGPoint(x: 10, y: 10)
        ))
        XCTAssertTrue(Self.colorsApproximatelyEqual(translucentActiveProgress, standardActiveProgress, tolerance: 0.02))
    }

    func testTranslucentChromeKeepsHierarchicalForegroundStylesAdaptive() throws {
        let translucentAppearance = DashboardPresentationPolicy.translucentAppearance(
            moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
            strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
        )
        let translucentSecondary = Rectangle().fill(.secondary)
            .environment(\.dashboardStyleAppearance, translucentAppearance)
            .frame(width: 20, height: 20)
        let plainSecondary = Rectangle().fill(.secondary)
            .frame(width: 20, height: 20)
        let translucentTertiary = Rectangle().fill(.tertiary)
            .environment(\.dashboardStyleAppearance, translucentAppearance)
            .frame(width: 20, height: 20)
        let plainTertiary = Rectangle().fill(.tertiary)
            .frame(width: 20, height: 20)

        for (actual, expected) in [
            (translucentSecondary, plainSecondary),
            (translucentTertiary, plainTertiary),
        ] {
            let actualRendered = try XCTUnwrap(Self.renderedColor(of: actual, atTopLeft: CGPoint(x: 10, y: 10)))
            let expectedRendered = try XCTUnwrap(Self.renderedColor(of: expected, atTopLeft: CGPoint(x: 10, y: 10)))
            XCTAssertTrue(Self.colorsApproximatelyEqual(actualRendered, expectedRendered, tolerance: 0.02))
        }
    }

    func testRootGlassBackgroundBuildsLeafRegularGlass() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSGlassEffectView rendering requires macOS 26.")
        }

        let size = NSSize(width: 200, height: 120)
        let hosting = NSHostingView(
            rootView: DashboardRootGlassBackground(cornerRadius: 24)
                .frame(width: size.width, height: size.height)
        )
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()

        let glass = try XCTUnwrap(Self.firstGlassEffectView(in: hosting) as? NSGlassEffectView)
        XCTAssertEqual(glass.style, .regular)
        XCTAssertNil(glass.tintColor)
        XCTAssertEqual(glass.cornerRadius, 24, accuracy: 0.01)
        XCTAssertNil(glass.contentView)
        XCTAssertEqual(glass.frame.width, hosting.bounds.width, accuracy: 0.5)
        XCTAssertEqual(glass.frame.height, hosting.bounds.height, accuracy: 0.5)
        XCTAssertEqual(glass.intrinsicContentSize.width, -1, accuracy: 0.01)
        XCTAssertEqual(glass.intrinsicContentSize.height, -1, accuracy: 0.01)
    }

    func testRootGlassBackgroundDoesNotInflateMeasuredContent() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("NSGlassEffectView rendering requires macOS 26.")
        }

        let plain = NSHostingView(rootView: Text("Mac Activity"))
        let withBackdrop = NSHostingView(
            rootView: Text("Mac Activity")
                .background {
                    DashboardRootGlassBackground(cornerRadius: 24)
                }
        )
        let plainWindow = Self.hostForFittingSize(plain)
        let backdropWindow = Self.hostForFittingSize(withBackdrop)
        defer {
            plainWindow.close()
            backdropWindow.close()
        }
        plain.layoutSubtreeIfNeeded()
        withBackdrop.layoutSubtreeIfNeeded()

        let plainSize = plain.fittingSize
        let backdropSize = withBackdrop.fittingSize
        XCTAssertGreaterThan(plainSize.width, 0, "the plain control must measure a real non-zero width")
        XCTAssertGreaterThan(plainSize.height, 0, "the plain control must measure a real non-zero height")
        XCTAssertGreaterThan(backdropSize.width, 0, "the backdrop host must measure a real non-zero width")
        XCTAssertGreaterThan(backdropSize.height, 0, "the backdrop host must measure a real non-zero height")

        XCTAssertEqual(backdropSize.width, plainSize.width, accuracy: 0.5)
        XCTAssertEqual(backdropSize.height, plainSize.height, accuracy: 0.5)
    }

    func testDashboardHeaderPaintsNoPerAreaBacking() throws {
        let source = try Self.dashboardViewSource()
        let headerStart = try XCTUnwrap(source.range(of: "segment: .header,"))
        let headerEnd = try XCTUnwrap(source.range(
            of: "segment: .headerDivider,",
            range: headerStart.upperBound..<source.endIndex
        ))
        let header = source[headerStart.lowerBound..<headerEnd.lowerBound]
        XCTAssertTrue(header.contains(".padding(.horizontal, DashboardHeaderChrome.horizontalPadding)"))
        XCTAssertFalse(header.contains(".dashboardShellSurface"))
        XCTAssertFalse(header.contains(".background("))
        XCTAssertFalse(header.contains(".dashboardCardChrome("))
    }

    func testTrendChartGridLinesUseSystemSecondary() throws {
        let source = try Self.dashboardViewSource("DashboardTrendChart.swift")
        XCTAssertFalse(source.contains("secondaryForegroundColor"))
        XCTAssertEqual(
            source.components(separatedBy: "Color.secondary.opacity(0.14)").count - 1,
            2
        )
    }

    func testSettingsWindowDoesNotReceiveDashboardChromeEnvironment() throws {
        let packageRoot = Self.packageRootURL()
        for file in ["AppShell/PreferencesWindowController.swift", "Views/PreferencesView.swift"] {
            let source = try String(
                contentsOf: packageRoot.appendingPathComponent("Sources/MacActivityApp").appendingPathComponent(file),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("dashboardStyleAppearance"), file)
            XCTAssertFalse(source.contains("DashboardRootGlassBackground"), file)
        }
    }

    func testTranslucentSourceHasNoClearGlassOrForcedDarkScheme() throws {
        for file in [
            "DashboardView.swift",
            "ActiveCleanReleaseLayout.swift",
            "DashboardStyleAppearance.swift",
        ] {
            let source = try Self.dashboardViewSource(file)
            XCTAssertFalse(source.contains(".glassEffect(.clear"), file)
            XCTAssertFalse(source.contains("colorScheme, .dark"), file)
            XCTAssertFalse(source.contains("DashboardClearPalette"), file)
            XCTAssertFalse(source.contains("DashboardClearReadabilityModifier"), file)
            XCTAssertFalse(source.contains("moduleBackingOpacity"), file)
        }
    }

    func testPopoverRootDoesNotBranchAboveStatefulDashboard() throws {
        let packageRoot = Self.packageRootURL()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/MacActivityApp/AppShell/DashboardPopoverController.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "struct DashboardPopoverRootView"))
        let end = try XCTUnwrap(source.range(
            of: "final class DashboardPopoverController",
            range: start.upperBound..<source.endIndex
        ))
        let rootView = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(rootView.contains("content"))
        XCTAssertFalse(rootView.contains("if "))
        XCTAssertFalse(rootView.contains("switch "))
        XCTAssertFalse(rootView.contains(".id("))
    }

    private static func requireLiquidGlassRendering() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Liquid Glass rendering requires macOS 26.")
        }
    }

    private static func hostForFittingSize(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFront(nil)
        return window
    }

    private static func firstGlassEffectView(in view: NSView) -> NSView? {
        if #available(macOS 26.0, *), view is NSGlassEffectView {
            return view
        }
        for subview in view.subviews {
            if let found = firstGlassEffectView(in: subview) {
                return found
            }
        }
        return nil
    }

    private static func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    private static func hostedRenderedColor<Content: View>(
        of view: Content,
        size: NSSize,
        atTopLeft point: CGPoint
    ) -> NSColor? {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        let scale = CGFloat(bitmap.pixelsWide) / max(size.width, 1)
        let pixelX = Int((point.x * scale).rounded(.down))
        let pixelY = Int(((size.height - point.y) * scale).rounded(.down))

        guard (0..<bitmap.pixelsWide).contains(pixelX),
              (0..<bitmap.pixelsHigh).contains(pixelY)
        else {
            return nil
        }

        return bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
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

        let pixelX = Int(point.x.rounded(.down))
        let sourceY = Int(point.y.rounded(.down))
        let pixelY = bitmap.pixelsHigh - sourceY - 1

        guard (0..<bitmap.pixelsWide).contains(pixelX),
              (0..<bitmap.pixelsHigh).contains(pixelY)
        else {
            return nil
        }

        return bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
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

    private static func dashboardViewSource(_ fileName: String = "DashboardView.swift") throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/MacActivityApp/Views")
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
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
