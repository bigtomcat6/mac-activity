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

    // Regression: omitting the multi-node inner radius leaves the two corners
    // facing the channel square; rounding a bus join would instead open a crack.
    func testMultiBranchSurfaceCutsAllExposedCornersButKeepsBusJoinsFilled() throws {
        for width: CGFloat in [320, 384] {
            for item in expandedCases where item.mode != .expanded(.oneToOne) {
                for watts in [[50.0, 50], [95, 5], [32.65, 9.70], [99.999, 0.001]] {
                    for footer in [false, true] {
                        let layout = PowerFlowDiagramLayout.resolve(
                            width: width, preferredMode: item.mode, sourceCount: item.sources,
                            sinkCount: item.sinks, reservesTotalsFooter: footer,
                            sourceWatts: item.sources == 2 ? watts : [watts.reduce(0, +)],
                            sinkWatts: item.sinks == 2 ? watts : [watts.reduce(0, +)]
                        )
                        let nodes = PowerFlowDiagramSurfaceShape(layout: layout, part: .endpoints)
                            .path(in: .zero).cgPath
                        for frame in layout.sourceFrames + layout.sinkFrames {
                            for x in [frame.minX + 0.25, frame.maxX - 0.25] {
                                for y in [frame.minY + 0.25, frame.maxY - 0.25] {
                                    XCTAssertFalse(nodes.contains(CGPoint(x: x, y: y)), "square node corner: \(item.mode) \(frame)")
                                }
                            }
                            XCTAssertTrue(nodes.contains(CGPoint(x: frame.midX, y: frame.midY)))
                            // Small lanes must still contain the visible icon footprint.
                            XCTAssertTrue(nodes.contains(CGPoint(x: frame.midX - 9, y: frame.midY - 7.5)))
                            XCTAssertTrue(nodes.contains(CGPoint(x: frame.midX + 9, y: frame.midY + 7.5)))
                            if frame.height == 22 {
                                // A height-adaptive cap, not the old 0.28 * h bevel.
                                XCTAssertFalse(nodes.contains(CGPoint(x: frame.minX + 1, y: frame.minY + 3)))
                                XCTAssertFalse(nodes.contains(CGPoint(x: frame.maxX - 1, y: frame.minY + 3)))
                            }
                        }
                        let channel = PowerFlowDiagramSurfaceShape(layout: layout, part: .channel)
                            .path(in: .zero).cgPath
                        for ribbon in layout.ribbons where ribbon.role != .bus {
                            if ribbon.startX == layout.middleSegment.minX {
                                XCTAssertFalse(channel.contains(CGPoint(x: ribbon.startX + 0.1,
                                    y: ribbon.startCenterY - ribbon.startHeight / 2 + 0.1)), "sharp flow start")
                            }
                            if ribbon.endX == layout.middleSegment.maxX {
                                XCTAssertFalse(channel.contains(CGPoint(x: ribbon.endX - 0.1,
                                    y: ribbon.endCenterY + ribbon.endHeight / 2 - 0.1)), "sharp flow end")
                            }
                        }
                        if let bus = layout.busFrame {
                            for x in [bus.minX - 0.01, bus.minX + 0.01, bus.maxX - 0.01, bus.maxX + 0.01] {
                                for y in stride(from: bus.minY + 0.1, through: bus.maxY - 0.1, by: 0.5) {
                                    XCTAssertTrue(channel.contains(CGPoint(x: x, y: y)), "crack at bus \(x),\(y)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testUserPairKeepsOriginalFramesThicknessAndReadoutSpace() {
        let layout = PowerFlowDiagramLayout.resolve(width: 384, preferredMode: .expanded(.oneToMany),
            sourceCount: 1, sinkCount: 2, sourceWatts: [42.35], sinkWatts: [32.65, 9.70])
        XCTAssertEqual(layout.sourceFrames, [CGRect(x: 0, y: 9.75, width: 52, height: 78)])
        XCTAssertEqual(layout.sinkFrames, [CGRect(x: 332, y: 0, width: 52, height: 56),
                                         CGRect(x: 332, y: 75.5, width: 52, height: 22)])
        XCTAssertEqual(layout.middleSegment, CGRect(x: 57, y: 0, width: 270, height: 97.5))
        XCTAssertEqual(layout.ribbons.map(\.startHeight), [56, 22])
        XCTAssertEqual(layout.ribbons.map(\.endHeight), [56, 22])
        XCTAssertEqual(layout.flowLabelFrames.map(\.size), Array(repeating: CGSize(width: 262, height: 18), count: 2))
    }

    func testRoundedRibbonsPreserveCubicTrackAndHaveNoFoldedOrOutOfBoundsSections() {
        for width: CGFloat in [320, 384] {
            for item in expandedCases {
                let layout = PowerFlowDiagramLayout.resolve(width: width, preferredMode: item.mode,
                    sourceCount: item.sources, sinkCount: item.sinks,
                    sourceWatts: [32.65, 9.70], sinkWatts: [95, 5])
                for ribbon in layout.ribbons {
                    let path = PowerFlowRibbonShape(geometry: ribbon, layout: layout).path(in: .zero).cgPath
                    XCTAssertTrue(ribbon.bounds.insetBy(dx: -0.001, dy: -0.001).contains(path.boundingBoxOfPath))
                    // The interior still follows the original two cubic boundaries,
                    // not a straight rounded rectangle or a stroked centreline.
                    for t: CGFloat in [0.25, 0.5, 0.75] {
                        let x = ribbon.startX + (ribbon.endX - ribbon.startX) * (1.5 * t - 1.5 * t * t + t * t * t)
                        let center = ribbon.startCenterY + (ribbon.endCenterY - ribbon.startCenterY) * t * t * (3 - 2 * t)
                        let half = (ribbon.startHeight + (ribbon.endHeight - ribbon.startHeight) * t * t * (3 - 2 * t)) / 2
                        XCTAssertTrue(path.contains(CGPoint(x: x, y: center - half + 0.01)))
                        XCTAssertTrue(path.contains(CGPoint(x: x, y: center + half - 0.01)))
                        XCTAssertFalse(path.contains(CGPoint(x: x, y: center - half - 0.01)))
                        XCTAssertFalse(path.contains(CGPoint(x: x, y: center + half + 0.01)))
                    }
                    assertFiniteAndSimple(path)
                }
            }
        }
        // Short/very thin geometry with an excessively large requested radius.
        for width: CGFloat in [0, 0.01, 2, 10] {
            for height: CGFloat in [0, 0.01, 2, 22] {
                let g = PowerFlowRibbonGeometry(role: .sink(0), startX: 10, endX: 10 + width,
                    startCenterY: 12, endCenterY: 12, startHeight: height, endHeight: height)
                let shapePath = PowerFlowRibbonShape(geometry: g, startRadius: 1000, endRadius: 1000).path(in: .zero)
                let path = shapePath.cgPath
                if width == 0 || height == 0 {
                    // Path().cgPath reports isEmpty=false on this SDK despite a
                    // null ink bounds. Check the actual Shape result before bridging.
                    XCTAssertTrue(shapePath.isEmpty)
                    XCTAssertTrue(path.boundingBoxOfPath.isNull)
                }
                else {
                    XCTAssertTrue(g.bounds.insetBy(dx: -0.001, dy: -0.001).contains(path.boundingBoxOfPath))
                    XCTAssertTrue(path.contains(CGPoint(x: g.bounds.midX, y: 12)))
                    assertFiniteAndSimple(path)
                }
            }
        }
    }

    private func assertFiniteAndSimple(_ path: CGPath, file: StaticString = #filePath, line: UInt = #line) {
        // Flatten for a geometric edge-intersection check, not source inspection.
        var vertices: [CGPoint] = []
        path.flattened(threshold: 0.01).applyWithBlock { pointer in
            let element = pointer.pointee
            if element.type == .moveToPoint || element.type == .addLineToPoint {
                let p = element.points[0]
                XCTAssertTrue(p.x.isFinite && p.y.isFinite, file: file, line: line)
                if vertices.last != p { vertices.append(p) }
            }
        }
        if vertices.first == vertices.last { vertices.removeLast() }
        guard vertices.count > 3 else { return }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        for i in vertices.indices {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            for j in vertices.indices where j > i + 1 && !(i == 0 && j == vertices.count - 1) {
                let c = vertices[j], d = vertices[(j + 1) % vertices.count]
                XCTAssertFalse(cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0,
                               "self-intersecting contour", file: file, line: line)
            }
        }
    }

    func testOversizedCapsOnShortBentRibbonsDoNotOvershootOrIntersect() {
        for width: CGFloat in [0.01, 2, 10] {
            for height: CGFloat in [0.01, 2, 22] {
                let g = PowerFlowRibbonGeometry(role: .sink(0), startX: 10, endX: 10 + width,
                    startCenterY: 12, endCenterY: 21.75, startHeight: height, endHeight: height)
                let path = PowerFlowRibbonShape(geometry: g, startRadius: 1000, endRadius: 1000).path(in: .zero).cgPath
                XCTAssertTrue(g.bounds.insetBy(dx: -0.00001, dy: -0.00001).contains(path.boundingBoxOfPath),
                              "cap overshoot on bent \(width)x\(height): \(path.boundingBoxOfPath)")
                XCTAssertTrue(path.contains(CGPoint(x: g.bounds.midX, y: 16.875)))
                assertFiniteAndSimple(path)
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
