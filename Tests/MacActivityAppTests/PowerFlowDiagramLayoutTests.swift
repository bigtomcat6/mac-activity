import CoreGraphics
import XCTest
@testable import MacActivityApp

final class PowerFlowDiagramLayoutTests: XCTestCase {
    private let expandedCases: [(mode: PowerFlowDiagramMode, sources: Int, sinks: Int, labels: Int)] = [
        (.expanded(.oneToOne), 1, 1, 1),
        (.expanded(.oneToMany), 1, 2, 2),
        (.expanded(.manyToOne), 2, 1, 3),
        (.expanded(.manyToMany), 2, 2, 4),
    ]
    private let expandedWidths = stride(from: CGFloat(320), through: 384, by: 0.5)

    func testExpandedTopologiesRemainExpandedThroughoutSupportedWidths() {
        for width in expandedWidths {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)

                XCTAssertEqual(layout.effectiveMode, item.mode, "width: \(width)")
                XCTAssertEqual(layout.cardFrame, CGRect(x: 0, y: 0, width: width, height: 104))
                XCTAssertEqual(layout.sourceFrames.count, item.sources)
                XCTAssertEqual(layout.sinkFrames.count, item.sinks)
                XCTAssertEqual(layout.flowLabelFrames.count, item.labels)
                XCTAssertNil(layout.groupedSourceFrame)
                XCTAssertNil(layout.groupedCenterFrame)
                XCTAssertNil(layout.groupedSinkFrame)
            }
        }
    }

    func testExpandedRegionsStayContainedAndSeparatedThroughoutSupportedWidths() {
        for width in expandedWidths {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)
                let context = "\(item.mode), width: \(width)"

                XCTAssertTrue(layout.cardFrame.contains(layout.statusFrame), context)
                XCTAssertTrue(layout.cardFrame.contains(layout.diagramFrame), context)
                XCTAssertFalse(layout.statusFrame.intersects(layout.diagramFrame), context)
                XCTAssertTrue(layout.diagramFrame.contains(layout.flowFrame), context)
                for node in layout.sourceFrames + layout.sinkFrames {
                    XCTAssertTrue(layout.diagramFrame.contains(node), context)
                    XCTAssertFalse(node.intersects(layout.flowFrame), context)
                    XCTAssertGreaterThanOrEqual(node.width, 40, context)
                    XCTAssertLessThanOrEqual(node.width, 48, context)
                    for label in layout.flowLabelFrames {
                        XCTAssertFalse(node.intersects(label), context)
                    }
                }
                assertPairwiseSeparated(layout.sourceFrames + layout.sinkFrames, context)
                for source in layout.sourceFrames {
                    XCTAssertGreaterThanOrEqual(layout.flowFrame.minX - source.maxX, 4, context)
                }
                for sink in layout.sinkFrames {
                    XCTAssertGreaterThanOrEqual(sink.minX - layout.flowFrame.maxX, 4, context)
                }
            }
        }
    }

    func testExpandedLabelsKeepMinimumWidthAndPairwiseSeparation() {
        for width in expandedWidths {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)
                let context = "\(item.mode), width: \(width)"

                XCTAssertEqual(layout.flowLabelFrames.count, item.labels, context)
                for label in layout.flowLabelFrames {
                    XCTAssertTrue(layout.flowFrame.contains(label), context)
                    XCTAssertGreaterThanOrEqual(label.width, 58, context)
                    XCTAssertGreaterThanOrEqual(label.width, PowerFlowDiagramLayout.minimumFlowLabelWidth, context)
                    XCTAssertEqual(label.height, 16, context)
                }
                assertPairwiseSeparated(layout.flowLabelFrames, context)
            }
        }
    }

    func testExpandedLaneSizingAndLabelAnchors() {
        for width in expandedWidths {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)
                for lanes in [layout.sourceFrames, layout.sinkFrames] {
                    if lanes.count == 1 {
                        XCTAssertEqual(lanes[0].height, 64)
                        XCTAssertEqual(lanes[0].midY, layout.diagramFrame.midY)
                    } else {
                        XCTAssertEqual(lanes.map(\.height), [28, 28])
                        XCTAssertEqual(lanes[1].minY - lanes[0].maxY, 8)
                        XCTAssertGreaterThanOrEqual(
                            lanes[1].minY - lanes[0].maxY,
                            PowerFlowDiagramLayout.minimumLaneGap
                        )
                    }
                }

                let expectedCenters: [CGFloat]
                switch item.mode {
                case .expanded(.oneToOne):
                    expectedCenters = [layout.flowFrame.midY]
                case .expanded(.oneToMany):
                    expectedCenters = layout.sinkFrames.map(\.midY)
                case .expanded(.manyToOne):
                    expectedCenters = layout.sourceFrames.map(\.midY) + [layout.flowFrame.midY]
                default:
                    expectedCenters = (layout.sourceFrames + layout.sinkFrames).map(\.midY)
                }
                XCTAssertEqual(layout.flowLabelFrames.map(\.midY), expectedCenters)
            }
        }
    }

    func testSharedBusIsCenteredAndOnlyPresentForManyToMany() throws {
        for width in expandedWidths {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)
                if item.mode == .expanded(.manyToMany) {
                    let bus = try XCTUnwrap(layout.busFrame)
                    XCTAssertEqual(bus.size, CGSize(width: 28, height: 24))
                    XCTAssertEqual(bus.midX, layout.flowFrame.midX)
                    XCTAssertEqual(bus.midY, layout.flowFrame.midY)
                    XCTAssertTrue(layout.flowFrame.contains(bus))
                    for label in layout.flowLabelFrames {
                        XCTAssertFalse(bus.intersects(label))
                    }
                } else {
                    XCTAssertNil(layout.busFrame)
                }
            }
        }
    }

    func testSub320ExpandedModesFallBackToGrouped() throws {
        for width: CGFloat in [280, 319, 319.5] {
            for item in expandedCases {
                let layout = resolve(width, item.mode, item.sources, item.sinks)

                XCTAssertEqual(layout.effectiveMode, .grouped)
                XCTAssertEqual(layout, resolve(width, .grouped, item.sources, item.sinks))
                try assertGroupedRegions(layout)
            }
        }
    }

    func testGroupedSummaryRegionsStayContainedAndSeparated() throws {
        for width: CGFloat in [280, 320, 384] {
            let layout = resolve(width, .grouped, 4, 3)

            XCTAssertEqual(layout.effectiveMode, .grouped)
            XCTAssertEqual(layout.cardFrame.height, 104)
            try assertGroupedRegions(layout)
        }
    }

    func testAllModesUseStableCardAndStatusGeometry() {
        let modes: [PowerFlowDiagramMode] = [.waiting, .idle, .unavailable, .grouped]
            + expandedCases.map(\.mode)

        for width: CGFloat in [280, 320, 384] {
            for mode in modes {
                let layout = resolve(width, mode, 2, 2)

                XCTAssertEqual(layout.cardFrame, CGRect(x: 0, y: 0, width: width, height: 104))
                XCTAssertEqual(layout.cardFrame.height, PowerFlowDiagramLayout.cardHeight)
                XCTAssertEqual(layout.statusFrame, CGRect(x: 8, y: 8, width: width - 16, height: 16))
                XCTAssertEqual(layout.diagramFrame, CGRect(x: 8, y: 30, width: width - 16, height: 64))
            }
        }
    }

    func testTerminalModesHaveNoActiveGeometryAndDoNotFallBack() {
        for width: CGFloat in [280, 320, 384] {
            for mode in [PowerFlowDiagramMode.waiting, .idle, .unavailable] {
                let layout = resolve(width, mode, 0, 0)

                XCTAssertEqual(layout.effectiveMode, mode)
                XCTAssertTrue(layout.sourceFrames.isEmpty)
                XCTAssertTrue(layout.sinkFrames.isEmpty)
                XCTAssertTrue(layout.flowLabelFrames.isEmpty)
                XCTAssertEqual(layout.flowFrame, layout.diagramFrame)
                XCTAssertNil(layout.busFrame)
                XCTAssertNil(layout.groupedSourceFrame)
                XCTAssertNil(layout.groupedCenterFrame)
                XCTAssertNil(layout.groupedSinkFrame)
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

    private func assertPairwiseSeparated(
        _ frames: [CGRect],
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (index, frame) in frames.enumerated() {
            for other in frames.dropFirst(index + 1) {
                XCTAssertFalse(frame.intersects(other), context, file: file, line: line)
            }
        }
    }

    private func assertGroupedRegions(
        _ layout: PowerFlowDiagramLayoutResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let source = try XCTUnwrap(layout.groupedSourceFrame, file: file, line: line)
        let center = try XCTUnwrap(layout.groupedCenterFrame, file: file, line: line)
        let sink = try XCTUnwrap(layout.groupedSinkFrame, file: file, line: line)

        assertPairwiseSeparated([source, center, sink], file: file, line: line)
        for region in [source, center, sink] {
            XCTAssertTrue(layout.diagramFrame.contains(region), file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(center.width, 56, file: file, line: line)
        XCTAssertEqual(center.minX - source.maxX, 6, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(sink.minX - center.maxX, 6, accuracy: 0.001, file: file, line: line)
        XCTAssertTrue(layout.sourceFrames.isEmpty, file: file, line: line)
        XCTAssertTrue(layout.sinkFrames.isEmpty, file: file, line: line)
        XCTAssertEqual(layout.flowFrame, center, file: file, line: line)
        XCTAssertEqual(layout.flowLabelFrames, [center.insetBy(dx: 4, dy: 20)], file: file, line: line)
        XCTAssertEqual(layout.busFrame, center.insetBy(dx: 0, dy: 20), file: file, line: line)
    }
}
