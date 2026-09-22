import AppKit
import SwiftUI
import XCTest
@testable import MacActivityApp

@MainActor
final class PowerFlowDiagramViewTests: XCTestCase {
    private typealias Fixtures = PowerFlowDiagramFixtures

    func testRenderPlanMapsLaneLabelsWithoutInventingEdges() {
        let cases: [(PowerFlowDiagramPresentation, [String])] = [
            (Fixtures.oneToOne, ["sink:mac"]),
            (Fixtures.oneToMany, ["sink:battery", "sink:mac"]),
            (Fixtures.manyToOne, ["source:source", "source:battery", "sink:mac"]),
            (Fixtures.manyToMany, ["source:source", "source:unknown", "sink:battery", "sink:mac"]),
        ]
        for (presentation, ids) in cases {
            let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: 320)
            XCTAssertEqual(plan.flowLabels.map(\.nodeID), ids)
            XCTAssertEqual(plan.flowLabels.count, plan.layout.flowLabelFrames.count)
            XCTAssertFalse(plan.exposesPairwiseEdges)
        }
        XCTAssertTrue(PowerFlowDiagramRenderPlan(presentation: Fixtures.manyToMany, width: 384).usesSharedBus)
    }

    func testRenderPlanFallsBackToGroupedBelowWidthFloor() {
        let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.manyToMany, width: 319)
        XCTAssertEqual(plan.layout.effectiveMode, .grouped)
        XCTAssertTrue(plan.flowLabels.isEmpty)
        XCTAssertNotNil(plan.totalsText)
    }

    func testTotalsIncludeBalancedManyToManyAndPartialGroupedValues() throws {
        let balanced = PowerFlowDiagramRenderPlan(presentation: Fixtures.manyToMany, width: 320)
        XCTAssertNotNil(balanced.totalsText)
        XCTAssertEqual(balanced.sourceTotalText, "57 W")
        XCTAssertEqual(balanced.sinkTotalText, "≈57 W")
        let grouped = PowerFlowDiagramRenderPlan(presentation: Fixtures.grouped, width: 320)
        XCTAssertEqual(grouped.sourceTotalText, "≥57 W")
        XCTAssertEqual(grouped.sinkTotalText, "≈57 W")
        XCTAssertTrue(try XCTUnwrap(grouped.totalsText).contains("≥57 W"))
        XCTAssertNil(PowerFlowDiagramRenderPlan(presentation: Fixtures.oneToOne, width: 320).totalsText)
    }

    func testMissingCounterpartsDoNotAcquireInferredValues() {
        let source = PowerFlowDiagramRenderPlan(presentation: Fixtures.missingSource, width: 320)
        let sink = PowerFlowDiagramRenderPlan(presentation: Fixtures.missingSink, width: 320)
        XCTAssertEqual(source.sourceTotalText, "—")
        XCTAssertEqual(sink.sinkTotalText, "—")
        XCTAssertEqual(sink.flowLabels.map(\.text), ["—"])
    }

    func testReduceMotionDisablesGeometryAnimation() {
        XCTAssertNil(PowerFlowDiagramMotion.animation(reduceMotion: true))
        XCTAssertNotNil(PowerFlowDiagramMotion.animation(reduceMotion: false))
    }

    func testCriticalBranchValuesFitTheir320PointFramesAtMinimumScale() {
        for presentation in [Fixtures.oneToOne, Fixtures.oneToMany, Fixtures.manyToOne, Fixtures.manyToMany] {
            let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: 320)
            for (label, frame) in zip(plan.flowLabels, plan.layout.flowLabelFrames) {
                let width = (label.text as NSString).size(withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                ]).width
                XCTAssertLessThanOrEqual(width * 0.78, frame.width, label.text)
            }
        }
    }

    func testAllDiagramModesRenderAtRealEnergyWidthAndPressureWidth() throws {
        let presentations = [
            Fixtures.oneToOne, Fixtures.oneToMany, Fixtures.manyToOne, Fixtures.manyToMany,
            Fixtures.grouped, Fixtures.missingSource, Fixtures.missingSink,
            Fixtures.waiting, Fixtures.idle, Fixtures.unavailable,
        ]
        // ImageRenderer cannot capture the native standard glass contents on macOS 26.
        // Also exercise root-glass module chrome, whose SwiftUI content is capturable.
        let appearances = [
            DashboardPresentationPolicy.standardAppearance,
            DashboardPresentationPolicy.translucentAppearance(
                moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
                strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
            ),
        ]
        for appearance in appearances {
            for width: CGFloat in [384, 320, 319] {
                for presentation in presentations {
                    let renderer = ImageRenderer(content: PowerFlowDiagramView(presentation: presentation)
                        .frame(width: width)
                        .environment(\.dashboardStyleAppearance, appearance))
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.nsImage)
                    XCTAssertEqual(image.size.height, PowerFlowDiagramLayout.cardHeight, accuracy: 1)
                    XCTAssertEqual(image.size.width, width, accuracy: 1)
                    XCTAssertFalse(presentation.accessibilityLabel.isEmpty)
                }
            }
        }
    }

    func testLongGermanLabelsStillRenderAt320Points() throws {
        let german = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "de"))
        let presentation = PowerFlowDiagramPresentationBuilder.build(
            snapshot: Fixtures.snapshot(
                .init(id: "unknown", type: .unknownExternalInterface, direction: .input, measurement: .unavailable),
                .init(id: "mac", type: .mac, direction: .output, measurement: .watts(21.46))
            ), isRefreshing: false, bundle: german
        )
        let renderer = ImageRenderer(content: PowerFlowDiagramView(presentation: presentation)
            .frame(width: 320)
            .environment(\.dashboardStyleAppearance, DashboardPresentationPolicy.translucentAppearance(
                moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacityIncreasedContrast,
                strokeOpacity: DashboardPresentationPolicy.increasedContrastStrokeOpacity
            ))
            .environment(\.colorScheme, .dark))
        XCTAssertNotNil(renderer.nsImage)
        XCTAssertFalse(presentation.accessibilityLabel.isEmpty)
    }
}
