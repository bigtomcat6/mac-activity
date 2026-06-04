import CoreGraphics
import AppKit
import SwiftUI
import XCTest
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

    func testFooterUsesSameGrayOpacityTokenAsActivesChrome() {
        XCTAssertEqual(DashboardFooterChrome.backgroundOpacity, ActiveCleanupChrome.backgroundOpacity, accuracy: 0.001)
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

    func testRenderedFooterUsesOverviewGrayBackgroundTone() throws {
        let model = DashboardModel(store: MetricsStore())
        let content = DashboardView(
            dashboardModel: model,
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
