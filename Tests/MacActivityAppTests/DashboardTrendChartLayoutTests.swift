import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardTrendChartLayoutTests: XCTestCase {
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

    func testXAxisDatesUseFirstMiddleAndLastSamples() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = (0..<5).map { index in
            DashboardTrendSample(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                primaryValue: Double(index)
            )
        }

        XCTAssertEqual(
            DashboardTrendChartLayout.xAxisDates(for: samples),
            [samples[0].timestamp, samples[2].timestamp, samples[4].timestamp]
        )
    }

    func testYAxisValuesUseLowerMiddleUpperDomainValues() {
        XCTAssertEqual(
            DashboardTrendChartLayout.yAxisValues(for: 20...40),
            [20, 30, 40]
        )
    }

    func testAreaFillStaysDisabledForFlatFixedScaleTrend() {
        let samples = [
            DashboardTrendSample(timestamp: .now, primaryValue: 45),
            DashboardTrendSample(timestamp: .now.addingTimeInterval(60), primaryValue: 45),
        ]

        XCTAssertFalse(
            DashboardTrendChartLayout.showsAreaFill(
                kind: .battery,
                samples: samples,
                domain: 0...100
            )
        )
    }

    func testAreaFillReturnsForTrendWithMeaningfulVerticalSpread() {
        let samples = [
            DashboardTrendSample(timestamp: .now, primaryValue: 20),
            DashboardTrendSample(timestamp: .now.addingTimeInterval(60), primaryValue: 54),
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
            ),
        ]

        XCTAssertFalse(
            DashboardTrendChartLayout.showsAreaFill(
                kind: .network,
                samples: samples,
                domain: 0...2_600_000
            )
        )
    }

    func testNetworkTrendDisablesSampleAnimations() {
        XCTAssertFalse(DashboardTrendChartLayout.animatesSampleChanges(for: .network))
        XCTAssertTrue(DashboardTrendChartLayout.animatesSampleChanges(for: .cpu))
    }

    func testNetworkLinePointsUseDistinctSeriesForPrimaryAndSecondaryValues() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let samples = [
            DashboardTrendSample(timestamp: base, primaryValue: 2_000, secondaryValue: 500),
            DashboardTrendSample(timestamp: base.addingTimeInterval(1), primaryValue: 4_000, secondaryValue: 750),
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

    func testDateMappingRoundTripsAcrossPlotFrame() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let end = start.addingTimeInterval(120)
        let plotFrame = CGRect(x: 42, y: 4, width: 236, height: 38)
        let midpointDate = start.addingTimeInterval(60)
        let x = DashboardTrendChartLayout.xPosition(
            for: midpointDate,
            domain: start...end,
            plotFrame: plotFrame
        )

        let mappedDate = DashboardTrendChartLayout.date(
            atX: x,
            plotFrame: plotFrame,
            domain: start...end
        )

        XCTAssertEqual(
            mappedDate.timeIntervalSinceReferenceDate,
            midpointDate.timeIntervalSinceReferenceDate,
            accuracy: 0.001
        )
    }

    func testTopAxisLabelPositionStaysInsideContainer() {
        let plotFrame = CGRect(x: 42, y: 4, width: 236, height: 38)
        let y = DashboardTrendChartLayout.yAxisLabelPosition(
            for: 40,
            domain: 20...40,
            plotFrame: plotFrame,
            containerHeight: 60
        )

        XCTAssertGreaterThanOrEqual(y, 7)
        XCTAssertLessThanOrEqual(y, 53)
    }
}
