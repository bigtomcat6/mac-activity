import XCTest
import MacActivityCore
import SwiftUI
@testable import MacActivityApp

@MainActor
final class DashboardTrendChartLayoutTests: XCTestCase {
    func testDisplaySamplesReduceDenseNonNetworkSeriesWithinBudget() {
        let samples = makeSamples(values: Array(0..<600).map(Double.init))
        let containerSize = CGSize(width: 280, height: 60)

        let displaySamples = DashboardTrendChartLayout.displaySamples(
            for: samples,
            kind: .cpu,
            containerSize: containerSize
        )

        XCTAssertLessThan(displaySamples.count, samples.count)
        XCTAssertLessThanOrEqual(
            displaySamples.count,
            DashboardTrendChartLayout.displaySampleBudget(for: containerSize)
        )
        XCTAssertEqual(displaySamples.first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(displaySamples.last?.timestamp, samples.last?.timestamp)
    }

    func testDisplaySamplesPreserveSpikeInOverviewSegment() {
        let values = Array(repeating: 12.0, count: 320) + [95.0] + Array(repeating: 12.0, count: 279)
        let samples = makeSamples(values: values)

        let displaySamples = DashboardTrendChartLayout.displaySamples(
            for: samples,
            kind: .cpu,
            containerSize: CGSize(width: 280, height: 60)
        )

        XCTAssertTrue(displaySamples.contains { $0.primaryValue == 95.0 })
    }

    func testDisplaySamplesDownsampleFlatSeriesWithinBudget() {
        let samples = makeSamples(values: Array(repeating: 42.0, count: 600))
        let containerSize = CGSize(width: 280, height: 60)

        let displaySamples = DashboardTrendChartLayout.displaySamples(
            for: samples,
            kind: .memory,
            containerSize: containerSize
        )

        XCTAssertLessThan(displaySamples.count, samples.count)
        XCTAssertLessThanOrEqual(
            displaySamples.count,
            DashboardTrendChartLayout.displaySampleBudget(for: containerSize)
        )
        XCTAssertEqual(displaySamples.first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(displaySamples.last?.timestamp, samples.last?.timestamp)
    }

    func testDisplaySamplesKeepFlatSeriesFromCollapsingIntoLargeTimeGap() {
        let samples = makeSamples(values: Array(repeating: 42.0, count: 600))

        let displaySamples = DashboardTrendChartLayout.displaySamples(
            for: samples,
            kind: .temperature,
            containerSize: CGSize(width: 280, height: 60)
        )
        let largestGap = zip(displaySamples, displaySamples.dropFirst())
            .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .max() ?? 0

        XCTAssertLessThanOrEqual(largestGap, 30)
    }

    func testDisplaySamplesReduceDenseNetworkSeriesAndPreservePeaks() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        var samples: [DashboardTrendSample] = []
        for index in 0..<600 {
            let sample = DashboardTrendSample(
                timestamp: base.addingTimeInterval(Double(index)),
                primaryValue: index == 240 ? 95_000 : Double(index % 9) * 1_000,
                secondaryValue: index == 360 ? 88_000 : Double(index % 7) * 500
            )
            samples.append(sample)
        }
        let containerSize = CGSize(width: 280, height: 60)
        let displaySamples = DashboardTrendChartLayout.displaySamples(
            for: samples,
            kind: .network,
            containerSize: containerSize
        )

        XCTAssertLessThan(displaySamples.count, samples.count)
        XCTAssertLessThanOrEqual(
            displaySamples.count,
            DashboardTrendChartLayout.displaySampleBudget(for: containerSize)
        )
        XCTAssertEqual(displaySamples.first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(displaySamples.last?.timestamp, samples.last?.timestamp)
        XCTAssertTrue(displaySamples.contains { $0.primaryValue == 95_000 })
        XCTAssertTrue(displaySamples.contains { $0.secondaryValue == 88_000 })
    }

    func testDisplaySampleBudgetUsesRestPlotWidthNotHoverWidth() {
        let containerSize = CGSize(width: 280, height: 60)
        let hoverPlotWidth = DashboardTrendChartLayout.plotFrame(
            in: containerSize,
            isHovering: true,
            yAxisLabelWidth: 54,
            xAxisLabelHeight: 14
        ).width

        XCTAssertEqual(
            DashboardTrendChartLayout.displayPlotWidth(for: containerSize),
            DashboardTrendChartLayout.plotFrame(
                in: containerSize,
                isHovering: false
            ).width,
            accuracy: 0.001
        )
        XCTAssertNotEqual(
            DashboardTrendChartLayout.displayPlotWidth(for: containerSize),
            hoverPlotWidth,
            accuracy: 0.001
        )
    }

    func testDisplaySamplesRemainChronological() {
        let values = (0..<600).map { index in
            index.isMultiple(of: 17) ? 90.0 : Double(index % 13)
        }
        let samples = makeSamples(values: values)

        let displaySamples = DashboardTrendChartLayout.displaySamples(
            for: samples,
            kind: .temperature,
            containerSize: CGSize(width: 280, height: 60)
        )

        for pair in zip(displaySamples, displaySamples.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.timestamp, pair.1.timestamp)
        }
    }

    func testAnnotationPositionTracksPointerYWithinPlotBounds() {
        let position = DashboardTrendChartLayout.annotationPosition(
            pointer: CGPoint(x: 80, y: 70),
            plotFrame: CGRect(x: 12, y: 10, width: 240, height: 120),
            annotationSize: CGSize(width: 96, height: 34)
        )

        XCTAssertEqual(position.y, 70, accuracy: 0.001)
        XCTAssertGreaterThan(position.x, 80)
    }

    func testAnnotationPositionClampsAndFlipsNearPlotEdges() {
        let position = DashboardTrendChartLayout.annotationPosition(
            pointer: CGPoint(x: 236, y: 18),
            plotFrame: CGRect(x: 12, y: 10, width: 240, height: 120),
            annotationSize: CGSize(width: 96, height: 34)
        )

        XCTAssertLessThan(position.x, 236)
        XCTAssertGreaterThanOrEqual(position.y, 31)
    }

    func testXAxisDatesUseFirstAndLastSamples() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = (0..<5).map { index in
            DashboardTrendSample(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                primaryValue: Double(index)
            )
        }

        XCTAssertEqual(
            DashboardTrendChartLayout.xAxisDates(for: samples),
            [samples[0].timestamp, samples[4].timestamp]
        )
    }

    func testXAxisDatesDeduplicateMatchingEdgeSamples() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = (0..<2).map { index in
            DashboardTrendSample(
                timestamp: base,
                primaryValue: Double(index)
            )
        }

        XCTAssertEqual(
            DashboardTrendChartLayout.xAxisDates(for: samples),
            [base]
        )
    }

    func testYAxisValuesUseLowerMiddleUpperDomainValues() {
        XCTAssertEqual(
            DashboardTrendChartLayout.yAxisValues(for: 20...40),
            [20, 30, 40]
        )
    }

    func testAreaFillAppliesToFlatNonNetworkTrend() {
        let samples = [
            DashboardTrendSample(timestamp: .now, primaryValue: 45),
            DashboardTrendSample(timestamp: .now.addingTimeInterval(60), primaryValue: 45)
        ]

        XCTAssertTrue(
            DashboardTrendChartLayout.showsAreaFill(
                kind: .battery,
                samples: samples,
                domain: 0...100
            )
        )
    }

    func testAreaFillAppliesToNonNetworkTrendWithSpread() {
        let samples = [
            DashboardTrendSample(timestamp: .now, primaryValue: 20),
            DashboardTrendSample(timestamp: .now.addingTimeInterval(60), primaryValue: 54)
        ]

        XCTAssertTrue(
            DashboardTrendChartLayout.showsAreaFill(
                kind: .cpu,
                samples: samples,
                domain: 0...100
            )
        )
    }

    func testAreaFillStaysDisabledForNetworkTrendEvenWithLargeSpread() {
        let samples = [
            DashboardTrendSample(timestamp: .now, primaryValue: 0, secondaryValue: 0),
            DashboardTrendSample(
                timestamp: .now.addingTimeInterval(60),
                primaryValue: 2_600_000,
                secondaryValue: 120_000
            )
        ]

        XCTAssertFalse(
            DashboardTrendChartLayout.showsAreaFill(
                kind: .network,
                samples: samples,
                domain: 0...2_600_000
            )
        )
    }

    func testRenderedCPUTrendChartBuildsLocalizedAreaAndPrimaryMarks() {
        let chart = DashboardTrendChart(
            metric: DashboardMetric(
                kind: .cpu,
                title: MetricKind.cpu.title,
                value: "42%",
                style: .chart,
                trend: DashboardTrend(
                    samples: makeSamples(values: [10, 40, 20, 70]),
                    scale: .fixed(lowerBound: 0, upperBound: 100)
                )
            ),
            color: .blue,
            isCardHovered: true,
            showsYAxisLabels: true
        )
        .frame(width: 280, height: 90)

        let renderer = ImageRenderer(content: chart)
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
    }

    func testRenderedNetworkTrendChartBuildsLocalizedSecondaryAndHoverMarks() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = [
            DashboardTrendSample(timestamp: base, primaryValue: 2_000, secondaryValue: 500),
            DashboardTrendSample(timestamp: base.addingTimeInterval(1), primaryValue: 4_000, secondaryValue: 750),
            DashboardTrendSample(timestamp: base.addingTimeInterval(2), primaryValue: 1_000, secondaryValue: 250)
        ]
        let chart = DashboardTrendChart(
            metric: DashboardMetric(
                kind: .network,
                title: MetricKind.network.title,
                value: "↑ 750 B/s ↓ 1 KB/s",
                style: .chart,
                trend: DashboardTrend(samples: samples, scale: .automatic)
            ),
            color: .green,
            isCardHovered: true,
            showsYAxisLabels: true
        )
        .frame(width: 280, height: 90)

        let renderer = ImageRenderer(content: chart)
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
    }

    func testOverviewTrendChartsAnimateSampleChangesIncludingNetwork() {
        XCTAssertTrue(DashboardTrendChartLayout.animatesSampleChanges(for: .network))
        XCTAssertTrue(DashboardTrendChartLayout.animatesSampleChanges(for: .cpu))
    }

    func testNetworkLinePointsUseDistinctSeriesForPrimaryAndSecondaryValues() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = [
            DashboardTrendSample(timestamp: base, primaryValue: 2_000, secondaryValue: 500),
            DashboardTrendSample(timestamp: base.addingTimeInterval(1), primaryValue: 4_000, secondaryValue: 750)
        ]

        let primaryPoints = DashboardTrendChartLayout.linePoints(
            for: samples,
            series: .primary
        )
        let secondaryPoints = DashboardTrendChartLayout.linePoints(
            for: samples,
            series: .secondary
        )

        XCTAssertEqual(primaryPoints.map(\.series), [.primary, .primary])
        XCTAssertEqual(secondaryPoints.map(\.series), [.secondary, .secondary])
        XCTAssertNotEqual(primaryPoints.last?.series, secondaryPoints.first?.series)
        XCTAssertEqual(
            Set((primaryPoints + secondaryPoints).map(\.id)).count,
            primaryPoints.count + secondaryPoints.count
        )
    }

    func testNetworkLinePointsMirrorDownloadBelowUploadAboveBaseline() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = [
            DashboardTrendSample(timestamp: base, primaryValue: 2_000, secondaryValue: 500),
            DashboardTrendSample(timestamp: base.addingTimeInterval(1), primaryValue: 4_000, secondaryValue: 750)
        ]

        let downloadPoints = DashboardTrendChartLayout.linePoints(
            for: samples,
            kind: .network,
            series: .primary
        )
        let uploadPoints = DashboardTrendChartLayout.linePoints(
            for: samples,
            kind: .network,
            series: .secondary
        )

        XCTAssertEqual(downloadPoints.map(\.value), [-2_000, -4_000])
        XCTAssertEqual(uploadPoints.map(\.value), [500, 750])
    }

    func testNetworkAutomaticDomainMirrorsAroundZero() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = [
            DashboardTrendSample(timestamp: base, primaryValue: 2_000, secondaryValue: 500),
            DashboardTrendSample(timestamp: base.addingTimeInterval(1), primaryValue: 4_000, secondaryValue: 750)
        ]

        let domain = DashboardTrendChartLayout.valueDomain(
            for: samples,
            kind: .network,
            scale: .automatic
        )

        XCTAssertLessThan(domain.lowerBound, 0)
        XCTAssertGreaterThan(domain.upperBound, 0)
        XCTAssertEqual(abs(domain.lowerBound), domain.upperBound, accuracy: 0.001)
        XCTAssertGreaterThan(domain.upperBound, 4_000)
    }

    func testNetworkDomainSmoothingExpandsImmediatelyButContractsGradually() {
        let previous = -2_000_000.0...2_000_000.0
        let expanded = DashboardTrendChartLayout.smoothedDomain(
            previous: -12_000.0...12_000.0,
            next: previous,
            kind: .network
        )
        XCTAssertEqual(expanded.lowerBound, previous.lowerBound, accuracy: 0.001)
        XCTAssertEqual(expanded.upperBound, previous.upperBound, accuracy: 0.001)

        let contracted = DashboardTrendChartLayout.smoothedDomain(
            previous: previous,
            next: -100_000.0...100_000.0,
            kind: .network
        )

        XCTAssertEqual(abs(contracted.lowerBound), contracted.upperBound, accuracy: 0.001)
        XCTAssertGreaterThan(contracted.upperBound, 100_000)
        XCTAssertLessThan(contracted.upperBound, previous.upperBound)
    }

    func testAutomaticDomainSmoothingOnlyEasesContractions() {
        let expanded = DashboardTrendChartLayout.smoothedDomain(
            previous: 40.0...50.0,
            next: 30.0...80.0,
            kind: .temperature
        )
        XCTAssertEqual(expanded.lowerBound, 30, accuracy: 0.001)
        XCTAssertEqual(expanded.upperBound, 80, accuracy: 0.001)

        let contracted = DashboardTrendChartLayout.smoothedDomain(
            previous: 30.0...80.0,
            next: 45.0...55.0,
            kind: .temperature
        )
        XCTAssertGreaterThan(contracted.lowerBound, 30)
        XCTAssertLessThan(contracted.lowerBound, 45)
        XCTAssertGreaterThan(contracted.upperBound, 55)
        XCTAssertLessThan(contracted.upperBound, 80)
    }

    func testNetworkHoverIndicatorsIncludeBaselineAndBothMirroredSeriesPoints() {
        let sample = DashboardTrendSample(
            timestamp: Date(timeIntervalSinceReferenceDate: 1_000),
            primaryValue: 2_000,
            secondaryValue: 500
        )

        let points = DashboardTrendChartLayout.hoverIndicatorPoints(
            for: sample,
            kind: .network
        )

        XCTAssertEqual(DashboardTrendChartLayout.hoverBaselineValue(for: .network), 0)
        XCTAssertEqual(points.map(\.series), [.primary, .secondary])
        XCTAssertEqual(points.map(\.value), [-2_000, 500])
        XCTAssertTrue(points.allSatisfy { $0.timestamp == sample.timestamp })
    }

    func testNonNetworkHoverIndicatorsUseSinglePrimaryPointAndNoBaseline() {
        let sample = DashboardTrendSample(
            timestamp: Date(timeIntervalSinceReferenceDate: 1_000),
            primaryValue: 42,
            secondaryValue: 7
        )

        let points = DashboardTrendChartLayout.hoverIndicatorPoints(
            for: sample,
            kind: .cpu
        )

        XCTAssertNil(DashboardTrendChartLayout.hoverBaselineValue(for: .cpu))
        XCTAssertEqual(points.map(\.series), [.primary])
        XCTAssertEqual(points.map(\.value), [42])
    }

    func testLinePointIDsStayStableForSamplesThatRemainAfterHistoryRolls() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let initialSamples = (0..<60).map { index in
            DashboardTrendSample(
                timestamp: base.addingTimeInterval(Double(index)),
                primaryValue: Double(index)
            )
        }
        let rolledSamples = (1..<61).map { index in
            DashboardTrendSample(
                timestamp: base.addingTimeInterval(Double(index)),
                primaryValue: Double(index)
            )
        }

        let initialIDsByTimestamp = Dictionary(
            uniqueKeysWithValues: DashboardTrendChartLayout.linePoints(
                for: initialSamples,
                series: .primary
            ).map { ($0.timestamp, $0.id) }
        )
        let rolledIDsByTimestamp = Dictionary(
            uniqueKeysWithValues: DashboardTrendChartLayout.linePoints(
                for: rolledSamples,
                series: .primary
            ).map { ($0.timestamp, $0.id) }
        )

        for timestamp in rolledSamples.dropLast().map(\.timestamp) {
            XCTAssertEqual(
                rolledIDsByTimestamp[timestamp],
                initialIDsByTimestamp[timestamp]
            )
        }
    }

    func testHoverPlotFrameShrinksFromLeftAndBottomOnly() {
        let restFrame = DashboardTrendChartLayout.plotFrame(
            in: CGSize(width: 280, height: 60),
            isHovering: false
        )
        let hoverFrame = DashboardTrendChartLayout.plotFrame(
            in: CGSize(width: 280, height: 60),
            isHovering: true
        )

        XCTAssertEqual(hoverFrame.minY, restFrame.minY, accuracy: 0.001)
        XCTAssertEqual(hoverFrame.maxX, restFrame.maxX, accuracy: 0.001)
        XCTAssertGreaterThan(hoverFrame.minX, restFrame.minX)
        XCTAssertLessThan(hoverFrame.maxY, restFrame.maxY)
    }

    func testRestPlotFrameReservesStrokeBleedInsideContainer() {
        let containerSize = CGSize(width: 280, height: 60)
        let frame = DashboardTrendChartLayout.plotFrame(
            in: containerSize,
            isHovering: false
        )

        XCTAssertGreaterThanOrEqual(frame.minX, 2)
        XCTAssertLessThanOrEqual(frame.maxX, containerSize.width - 2)
    }

    func testHoverPlotFrameUsesDynamicAxisReservations() {
        let compactAxisFrame = DashboardTrendChartLayout.plotFrame(
            in: CGSize(width: 280, height: 60),
            isHovering: true,
            yAxisLabelWidth: 24,
            xAxisLabelHeight: 10
        )
        let expandedAxisFrame = DashboardTrendChartLayout.plotFrame(
            in: CGSize(width: 280, height: 60),
            isHovering: true,
            yAxisLabelWidth: 66,
            xAxisLabelHeight: 18
        )

        XCTAssertEqual(expandedAxisFrame.minY, compactAxisFrame.minY, accuracy: 0.001)
        XCTAssertEqual(expandedAxisFrame.maxX, compactAxisFrame.maxX, accuracy: 0.001)
        XCTAssertGreaterThan(expandedAxisFrame.minX, compactAxisFrame.minX)
        XCTAssertLessThan(expandedAxisFrame.maxY, compactAxisFrame.maxY)
    }

    func testYAxisLabelReservationCanBeSuppressedForChartsWithoutLeftAxisText() {
        let visibleWidth = DashboardTrendChartLayout.yAxisLabelWidth(
            for: ["100%", "50%", "0%"],
            showsLabels: true
        )
        let hiddenWidth = DashboardTrendChartLayout.yAxisLabelWidth(
            for: ["100%", "50%", "0%"],
            showsLabels: false
        )

        XCTAssertGreaterThan(visibleWidth, 0)
        XCTAssertEqual(hiddenWidth, 0)
    }

    func testHiddenYAxisLabelsDoNotReserveExtraLeadingHoverSpace() {
        let restFrame = DashboardTrendChartLayout.plotFrame(
            in: CGSize(width: 280, height: 60),
            isHovering: false
        )
        let hiddenYAxisFrame = DashboardTrendChartLayout.plotFrame(
            in: CGSize(width: 280, height: 60),
            isHovering: true,
            yAxisLabelWidth: 0,
            xAxisLabelHeight: 14
        )

        XCTAssertEqual(hiddenYAxisFrame.minX, restFrame.minX, accuracy: 0.001)
    }

    func testYAxisLabelFrameTouchesContainerLeadingEdge() {
        let plotFrame = DashboardTrendChartLayout.plotFrame(
            in: CGSize(width: 280, height: 60),
            isHovering: true,
            yAxisLabelWidth: 54,
            xAxisLabelHeight: 14
        )
        let labelWidth = DashboardTrendChartLayout.yAxisLabelWidth(for: plotFrame)
        let labelCenterX = DashboardTrendChartLayout.yAxisLabelCenterX(for: plotFrame)

        XCTAssertEqual(labelCenterX - labelWidth / 2, 0, accuracy: 0.001)
    }

    func testXAxisLabelFrameTouchesContainerBottomEdge() {
        let containerHeight: CGFloat = 60
        let plotFrame = DashboardTrendChartLayout.plotFrame(
            in: CGSize(width: 280, height: containerHeight),
            isHovering: true,
            yAxisLabelWidth: 54,
            xAxisLabelHeight: 14
        )
        let labelCenterY = DashboardTrendChartLayout.xAxisLabelY(
            for: plotFrame,
            containerHeight: containerHeight
        )

        XCTAssertEqual(
            labelCenterY + DashboardTrendChartLayout.xAxisLabelHalfHeight,
            containerHeight,
            accuracy: 0.001
        )
    }

    func testSingleXAxisLabelPinsToTrailingEdge() {
        let plotFrame = CGRect(x: 12, y: 4, width: 90, height: 38)
        let centerX = DashboardTrendChartLayout.xAxisLabelCenterX(
            for: plotFrame.maxX,
            plotFrame: plotFrame,
            index: 0,
            count: 1
        )

        XCTAssertEqual(
            centerX,
            plotFrame.maxX - DashboardTrendChartLayout.xAxisLabelWidth / 2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            DashboardTrendChartLayout.xAxisLabelAlignment(for: 0, count: 1),
            .trailing
        )
    }

    func testDateMappingRoundTripsAcrossPlotFrame() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let end = start.addingTimeInterval(120)
        let plotFrame = CGRect(x: 42, y: 4, width: 236, height: 38)
        let midpointDate = start.addingTimeInterval(60)
        let xPosition = DashboardTrendChartLayout.xPosition(
            for: midpointDate,
            domain: start...end,
            plotFrame: plotFrame
        )

        let mappedDate = DashboardTrendChartLayout.date(
            atX: xPosition,
            plotFrame: plotFrame,
            domain: start...end
        )

        XCTAssertEqual(
            mappedDate.timeIntervalSinceReferenceDate,
            midpointDate.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }

    func testHoverSelectionUsesChartLocalCoordinates() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let middle = start.addingTimeInterval(60)
        let end = start.addingTimeInterval(120)
        let samples = [
            DashboardTrendSample(timestamp: start, primaryValue: 10),
            DashboardTrendSample(timestamp: middle, primaryValue: 40),
            DashboardTrendSample(timestamp: end, primaryValue: 20)
        ]
        let plotFrame = CGRect(x: 42, y: 4, width: 236, height: 38)

        let selection = DashboardTrendChartLayout.hoverSelection(
            localX: plotFrame.width / 2,
            samples: samples,
            xDomain: start...end,
            yDomain: 0...100,
            plotFrame: plotFrame
        )

        XCTAssertEqual(selection?.sampleIndex, 1)
        XCTAssertEqual(
            selection?.location.x ?? 0,
            DashboardTrendChartLayout.xPosition(
                for: middle,
                domain: start...end,
                plotFrame: plotFrame
            ),
            accuracy: 0.001
        )
        XCTAssertEqual(
            selection?.location.y ?? 0,
            DashboardTrendChartLayout.yPosition(
                for: 40,
                domain: 0...100,
                plotFrame: plotFrame
            ),
            accuracy: 0.001
        )
    }

    func testTopAxisLabelPositionStaysInsideContainer() {
        let plotFrame = CGRect(x: 42, y: 4, width: 236, height: 38)
        let yPosition = DashboardTrendChartLayout.yAxisLabelPosition(
            for: 40,
            domain: 20...40,
            plotFrame: plotFrame,
            containerHeight: 60
        )

        XCTAssertGreaterThanOrEqual(yPosition, 7)
        XCTAssertLessThanOrEqual(yPosition, 53)
    }

    private func makeSamples(values: [Double]) -> [DashboardTrendSample] {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        return values.enumerated().map { index, value in
            DashboardTrendSample(
                timestamp: base.addingTimeInterval(Double(index)),
                primaryValue: value
            )
        }
    }
}
