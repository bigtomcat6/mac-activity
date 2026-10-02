import CoreGraphics
import SwiftUI
import XCTest
@testable import MacActivityApp

// Stable panel dimensions, smooth branch boundaries and shared-bus semantics.
final class PowerFlowDiagramLayoutTests: XCTestCase {
    private let expandedCases: [(mode: PowerFlowDiagramMode, sources: Int, sinks: Int, labels: Int)] = [
        (.expanded(.oneToOne), 1, 1, 1),
        (.expanded(.oneToMany), 1, 2, 2),
        (.expanded(.manyToOne), 2, 1, 2),
        (.expanded(.manyToMany), 2, 2, 4),
    ]
    private let expandedWidths = stride(from: CGFloat(320), through: 384, by: 0.5)

    func testOnlyAdditionalBranchesIncreaseTheCompactPanelHeight() {
        for width: CGFloat in [320, 384] {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)
                let expectedHeight: CGFloat = item.mode == .expanded(.oneToOne) ? 78 : 97.5
                XCTAssertEqual(layout.cardFrame.height, expectedHeight)
                XCTAssertEqual(layout.diagramFrame, layout.cardFrame)
            }
            for mode in [PowerFlowDiagramMode.waiting, .idle, .unavailable, .grouped] {
                XCTAssertEqual(resolve(width, mode, 3, 3).cardFrame.height, 78)
            }
        }
    }

    func testApprovedSegmentGeometryAtReferenceWidth() {
        let layout = resolve(384, .expanded(.oneToOne), 1, 1)

        // left 52, sep 5, middle 270, sep 5, right 52.
        XCTAssertEqual(layout.sourceFrames.first?.minX ?? .nan, 0, accuracy: 0.001)
        XCTAssertEqual(layout.sourceFrames.first?.maxX ?? .nan, 52, accuracy: 0.001)
        XCTAssertEqual(layout.flowFrame.minX, 57, accuracy: 0.001)
        XCTAssertEqual(layout.flowFrame.width, 270, accuracy: 0.001)
        XCTAssertEqual(layout.flowFrame.maxX, 327, accuracy: 0.001)
        XCTAssertEqual(layout.sinkFrames.first?.minX ?? .nan, 332, accuracy: 0.001)
        XCTAssertEqual(layout.sinkFrames.first?.maxX ?? .nan, 384, accuracy: 0.001)

        // The separators are transparent gaps, not painted stripes.
        XCTAssertEqual(layout.sourceSeparator, CGRect(x: 52, y: 0, width: 5, height: 78))
        XCTAssertEqual(layout.sinkSeparator, CGRect(x: 327, y: 0, width: 5, height: 78))
        XCTAssertEqual(layout.outerCornerRadius, 21, accuracy: 0.001)
        XCTAssertEqual(layout.flowFrame.minX - (layout.sourceFrames.first?.maxX ?? .nan), 5, accuracy: 0.001)
        XCTAssertEqual((layout.sinkFrames.first?.minX ?? .nan) - layout.flowFrame.maxX, 5, accuracy: 0.001)
        for frame in layout.sourceFrames + layout.sinkFrames {
            XCTAssertEqual(frame.height, 78, accuracy: 0.001)
            XCTAssertEqual(frame.minY, 0, accuracy: 0.001)
        }
    }

    func testSegmentGeometryScalesProportionallyAtPressureWidth() {
        let layout = resolve(320, .expanded(.oneToOne), 1, 1)
        let scale = 320.0 / 384.0

        XCTAssertEqual(layout.sourceFrames.first?.width ?? .nan, 52 * scale, accuracy: 0.01)
        XCTAssertEqual(layout.flowFrame.minX, 57 * scale, accuracy: 0.01)
        XCTAssertEqual(layout.flowFrame.width, 270 * scale, accuracy: 0.01)
        XCTAssertEqual(layout.sinkFrames.first?.minX ?? .nan, 332 * scale, accuracy: 0.01)
        XCTAssertEqual(layout.sourceFrames.first?.height ?? .nan, 78, accuracy: 0.001)
        XCTAssertEqual(layout.sinkFrames.first?.height ?? .nan, 78, accuracy: 0.001)
    }

    func testSingleNodeSidesAreCenteredOnTheApprovedCenters() {
        let layout = resolve(384, .expanded(.oneToOne), 1, 1)
        XCTAssertEqual(layout.sourceFrames.count, 1)
        XCTAssertEqual(layout.sinkFrames.count, 1)
        XCTAssertEqual(layout.sourceFrames[0].midX, 26, accuracy: 0.001)
        XCTAssertEqual(layout.sourceFrames[0].midY, 39, accuracy: 0.001)
        XCTAssertEqual(layout.sinkFrames[0].midX, 358, accuracy: 0.001)
        XCTAssertEqual(layout.sinkFrames[0].midY, 39, accuracy: 0.001)
    }

    func testEachTwoNodeSideSplitsIntoTwoEqualFullWidthLanes() {
        let layout = resolve(384, .expanded(.manyToMany), 2, 2)

        XCTAssertEqual(layout.sourceFrames.map(\.height), [39, 39])
        XCTAssertEqual(layout.sinkFrames.map(\.height), [39, 39])
        XCTAssertEqual(layout.sourceFrames.map(\.midY), [19.5, 78])
        XCTAssertEqual(layout.sinkFrames.map(\.midY), [19.5, 78])
        XCTAssertEqual(layout.sourceFrames.map(\.midX), [26, 26])
        XCTAssertEqual(layout.sinkFrames.map(\.midX), [358, 358])
        XCTAssertEqual(layout.sourceFrames[1].minY - layout.sourceFrames[0].maxY, 19.5, accuracy: 0.001)
    }

    func testReadoutsFollowTheirCurvedBranchCenters() {
        let manyToOne = resolve(384, .expanded(.manyToOne), 2, 1)
        XCTAssertEqual(manyToOne.flowLabelFrames.count, 2)
        for (label, ribbon) in zip(manyToOne.flowLabelFrames, manyToOne.ribbons) {
            XCTAssertEqual(label.midY, ribbon.centerY(atX: label.midX), accuracy: 0.001)
        }
        XCTAssertTrue(manyToOne.flowLabelFrames[0].intersects(manyToOne.flowFrame))
        XCTAssertTrue(manyToOne.flowLabelFrames[1].intersects(manyToOne.flowFrame))

        let oneToMany = resolve(384, .expanded(.oneToMany), 1, 2)
        for (label, ribbon) in zip(oneToMany.flowLabelFrames, oneToMany.ribbons) {
            XCTAssertEqual(label.midY, ribbon.centerY(atX: label.midX), accuracy: 0.001)
        }

        let oneToOne = resolve(384, .expanded(.oneToOne), 1, 1)
        XCTAssertEqual(oneToOne.flowLabelFrames.count, 1)
        XCTAssertEqual(oneToOne.flowLabelFrames[0].midX, 192, accuracy: 0.001)
        XCTAssertEqual(oneToOne.flowLabelFrames[0].midY, 39, accuracy: 0.001)
    }

    func testOnlyManyToManyExposesASharedBus() {
        for width: CGFloat in [320, 384] {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)
                if item.mode == .expanded(.manyToMany) {
                    XCTAssertNotNil(layout.busFrame)
                } else {
                    XCTAssertNil(layout.busFrame)
                }
            }
        }
    }

    func testLabelsStayInsideTheMiddleSegmentAndNeverOverlap() {
        for width in expandedWidths {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)
                let context = "\(item.mode), width: \(width)"
                XCTAssertEqual(layout.flowLabelFrames.count, item.labels, context)
                for label in layout.flowLabelFrames {
                    XCTAssertTrue(layout.flowFrame.insetBy(dx: -0.001, dy: -0.001).contains(label), context)
                }
            }
        }
    }

    func testSub320ExpandedModesFallBackToGrouped() {
        for width: CGFloat in [280, 319, 319.5] {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)
                XCTAssertEqual(layout.effectiveMode, .grouped)
                XCTAssertEqual(layout, resolve(width, .grouped, item.sources, item.sinks))
            }
        }
    }

    func testGroupedAndTerminalModesKeepPanelHeightAndNoActiveFrames() {
        for width: CGFloat in [280, 320, 384] {
            for mode in [PowerFlowDiagramMode.grouped, .waiting, .idle, .unavailable] {
                let layout = resolve(width, mode, 0, 0)
                XCTAssertEqual(layout.cardFrame.height, 78)
                XCTAssertEqual(layout.diagramFrame, layout.cardFrame)
                XCTAssertEqual(layout.flowFrame.height, 78)
                if mode != .grouped {
                    XCTAssertTrue(layout.sourceFrames.isEmpty)
                    XCTAssertTrue(layout.sinkFrames.isEmpty)
                    XCTAssertTrue(layout.flowLabelFrames.isEmpty)
                }
            }
        }
    }

    func testReferenceCurvesBendByHalfTheGapWithoutChangingBranchThickness() {
        for width: CGFloat in [320, 384] {
            for item in expandedCases where item.mode != .expanded(.oneToOne) {
                let layout = resolve(width, item.mode, item.sources, item.sinks)
                for ribbon in layout.ribbons where ribbon.role != .bus {
                    XCTAssertEqual(abs(ribbon.endCenterY - ribbon.startCenterY), 9.75, accuracy: 0.001)
                    XCTAssertEqual(ribbon.startHeight, ribbon.endHeight, accuracy: 0.001)
                    // Sampled screenshot profile: halfway along the channel,
                    // half the vertical offset has occurred; the ends are flat.
                    XCTAssertEqual(ribbon.centerY(atX: (ribbon.startX + ribbon.endX) / 2),
                                   (ribbon.startCenterY + ribbon.endCenterY) / 2, accuracy: 0.001)
                }
            }
        }
    }

    func testReferenceSplitAndMergeUseTheFullChannelLength() throws {
        for (mode, sources, sinks) in [(PowerFlowDiagramMode.expanded(.oneToMany), 1, 2),
                                       (.expanded(.manyToOne), 2, 1)] {
            let layout = resolve(384, mode, sources, sinks)
            XCTAssertEqual(layout.ribbons.count, 2, "no straight trunk before splitting or after merging")
            for ribbon in layout.ribbons {
                XCTAssertEqual(ribbon.startX, layout.middleSegment.minX, accuracy: 0.001)
                XCTAssertEqual(ribbon.endX, layout.middleSegment.maxX, accuracy: 0.001)
                XCTAssertEqual(ribbon.startHeight, ribbon.endHeight, accuracy: 0.001)
            }
        }
    }

    func testBothRibbonContoursMeetWithHorizontalTangents() {
        for item in expandedCases {
            let layout = resolve(384, item.mode, item.sources, item.sinks)
            for ribbon in layout.ribbons {
                var current = CGPoint.zero
                var curves = 0
                PowerFlowRibbonShape(geometry: ribbon).path(in: layout.cardFrame).forEach { element in
                    switch element {
                    case .move(let point), .line(let point): current = point
                    case .curve(let end, let control1, let control2):
                        XCTAssertEqual(control1.y, current.y, accuracy: 0.001)
                        XCTAssertEqual(control2.y, end.y, accuracy: 0.001)
                        current = end
                        curves += 1
                    default: break
                    }
                }
                XCTAssertEqual(curves, 2, "upper and lower boundaries must both be smooth")
            }
        }
    }

    func testBranchesJoinTheBusWithoutGapsAndKeepEndpointAlignment() throws {
        let layout = resolve(384, .expanded(.manyToMany), 2, 2)
        let bus = try XCTUnwrap(layout.busFrame)
        XCTAssertEqual(layout.ribbons.count, 5, "two inputs, one shared bus, two outputs")
        for ribbon in layout.ribbons {
            switch ribbon.role {
            case .source(let index):
                XCTAssertEqual(ribbon.startCenterY, layout.sourceFrames[index].midY)
                XCTAssertEqual(ribbon.endX, bus.minX)
                XCTAssertEqual(ribbon.endHeight, bus.height / 2)
                XCTAssertEqual(ribbon.endCenterY, bus.minY + bus.height * (CGFloat(index) + 0.5) / 2)
            case .sink(let index):
                XCTAssertEqual(ribbon.endCenterY, layout.sinkFrames[index].midY)
                XCTAssertEqual(ribbon.startX, bus.maxX)
                XCTAssertEqual(ribbon.startHeight, bus.height / 2)
                XCTAssertEqual(ribbon.startCenterY, bus.minY + bus.height * (CGFloat(index) + 0.5) / 2)
            default: break
            }
        }
    }

    func testPartialTopologyKeepsPathsAndLabelsAboveTheFooter() throws {
        for width: CGFloat in [320, 384] {
            for item in expandedCases {
                let layout = PowerFlowDiagramLayout.resolve(
                    width: width, preferredMode: item.mode, sourceCount: item.sources,
                    sinkCount: item.sinks, reservesTotalsFooter: true
                )
                let footer = try XCTUnwrap(layout.totalsFooterFrame)
                for frame in layout.sourceFrames + layout.sinkFrames + layout.flowLabelFrames
                    + layout.ribbons.map(\.bounds) {
                    XCTAssertLessThanOrEqual(frame.maxY, footer.minY + 0.001)
                }
            }
        }
    }

    private func resolve(
        _ width: CGFloat,
        _ mode: PowerFlowDiagramMode,
        _ sources: Int,
        _ sinks: Int
    ) -> PowerFlowDiagramLayoutResult {
        PowerFlowDiagramLayout.resolve(
            width: width,
            preferredMode: mode,
            sourceCount: sources,
            sinkCount: sinks
        )
    }
}
