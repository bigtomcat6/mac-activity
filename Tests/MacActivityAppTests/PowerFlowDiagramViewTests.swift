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

    // Measures the real production compact tile content (not constants) with the
    // production node widths/heights. This is the regression that catches the
    // horizontal icon+title arrangement exhausting the 40 pt node width.
    func testCompactNodeTileContentFitsProductionNodeWidths() {
        let shortKinds: Set<PowerFlowDiagramNodeKind> = [.externalPower, .battery, .mac]
        for width: CGFloat in [320, 384] {
            let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.manyToMany, width: width)
            let nodes = Fixtures.manyToMany.sources + Fixtures.manyToMany.sinks
            let frames = plan.layout.sourceFrames + plan.layout.sinkFrames
            for (node, frame) in zip(nodes, frames) {
                guard shortKinds.contains(node.kind) else { continue }
                XCTAssertTrue(
                    frame.height < PowerFlowDiagramNodeVisual.compactHeightThreshold,
                    "\(node.title) should use the compact tile at width \(width)"
                )
                let host = NSHostingView(
                    rootView: PowerFlowDiagramNodeTile(node: node, isCompact: true).content
                )
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                XCTAssertLessThanOrEqual(
                    size.width, frame.width - 2,
                    "compact '\(node.title)' content width \(size.width) overflows \(frame.width) at width \(width)"
                )
                XCTAssertLessThanOrEqual(
                    size.height, frame.height - 2,
                    "compact '\(node.title)' content height \(size.height) overflows \(frame.height)"
                )
            }
        }
    }

    func testRegularNodeTileContentStaysWithinSingleLaneFrames() {
        for width: CGFloat in [320, 384] {
            let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.oneToOne, width: width)
            let nodes = Fixtures.oneToOne.sources + Fixtures.oneToOne.sinks
            let frames = plan.layout.sourceFrames + plan.layout.sinkFrames
            for (node, frame) in zip(nodes, frames) {
                XCTAssertGreaterThanOrEqual(frame.height, PowerFlowDiagramNodeVisual.compactHeightThreshold)
                let host = NSHostingView(
                    rootView: PowerFlowDiagramNodeTile(node: node, isCompact: false).content
                )
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                XCTAssertLessThanOrEqual(size.height, frame.height - 2)
                XCTAssertLessThanOrEqual(size.width, frame.width)
            }
        }
    }

    // Rendered-content check: each sink lane must carry its endpoint tint at the
    // node end (battery green, Mac blue) rather than one uniform purple gradient.
    func testRenderedRibbonColorsFollowEndpointKinds() throws {
        let presentation = Fixtures.oneToMany
        let width: CGFloat = 384
        let appearance = DashboardPresentationPolicy.translucentAppearance(
            moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
            strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
        )
        let bitmap = try renderBitmap(
            presentation: presentation, width: width, appearance: appearance, backdrop: .white
        )
        let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: width)
        let scale = CGFloat(bitmap.pixelsWide) / width
        let flow = plan.layout.flowFrame
        // oneToMany sink order is battery, then Mac.
        let battery = try XCTUnwrap(plan.layout.sinkFrames.first)
        let mac = try XCTUnwrap(plan.layout.sinkFrames.dropFirst().first)
        let batteryColor = color(in: bitmap, at: CGPoint(x: flow.maxX - 3, y: battery.midY - 10), scale: scale)
        let macColor = color(in: bitmap, at: CGPoint(x: flow.maxX - 3, y: mac.midY - 10), scale: scale)

        XCTAssertGreaterThan(
            batteryColor.greenComponent, batteryColor.redComponent + 0.03,
            "battery lane should read green, got \(batteryColor)"
        )
        XCTAssertGreaterThan(
            batteryColor.greenComponent, batteryColor.blueComponent + 0.01,
            "battery lane should read green, got \(batteryColor)"
        )
        XCTAssertGreaterThan(
            macColor.blueComponent, macColor.greenComponent + 0.01,
            "Mac lane should read blue, got \(macColor)"
        )
        XCTAssertGreaterThan(
            macColor.blueComponent, macColor.redComponent + 0.03,
            "Mac lane should read blue, got \(macColor)"
        )
    }

    private func renderBitmap(
        presentation: PowerFlowDiagramPresentation,
        width: CGFloat,
        appearance: DashboardStyleAppearance,
        backdrop: Color
    ) throws -> NSBitmapImageRep {
        let content = ZStack {
            backdrop
            PowerFlowDiagramView(presentation: presentation)
                .environment(\.dashboardStyleAppearance, appearance)
                .frame(width: width)
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff))
    }

    private func color(in representation: NSBitmapImageRep, at point: CGPoint, scale: CGFloat) -> NSColor {
        let x = min(representation.pixelsWide - 1, max(0, Int(point.x * scale)))
        let y = min(representation.pixelsHigh - 1, max(0, Int(point.y * scale)))
        return representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
    }

    func testNodeSurfaceRemainsVisibleWhenStandardModuleFillIsZero() {
        let standard = DashboardPresentationPolicy.standardAppearance
        XCTAssertEqual(standard.moduleFillOpacity, 0)
        XCTAssertGreaterThan(PowerFlowDiagramNodeVisual.fillOpacity(for: standard), 0)
        XCTAssertGreaterThanOrEqual(
            PowerFlowDiagramNodeVisual.fillOpacity(for: standard),
            PowerFlowDiagramNodeVisual.baseFillOpacity
        )
    }

    func testGroupedSideSummaryContentHoldsTwoRepresentativesWithinDiagramHeight() throws {
        let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.grouped, width: 320)
        let cases: [(PowerFlowDiagramSideSummary, AppLocalization.Key, CGRect)] = [
            (Fixtures.grouped.sourceSummary, .powerFlowSourcesCount, try XCTUnwrap(plan.layout.groupedSourceFrame)),
            (Fixtures.grouped.sinkSummary, .powerFlowOutputsCount, try XCTUnwrap(plan.layout.groupedSinkFrame)),
        ]
        for (summary, key, frame) in cases {
            let host = NSHostingView(
                rootView: PowerFlowDiagramSideSummaryView(summary: summary, countKey: key)
                    .frame(width: frame.width)
                    .environment(\.dashboardStyleAppearance, DashboardPresentationPolicy.standardAppearance)
            )
            XCTAssertLessThanOrEqual(
                host.fittingSize.height,
                frame.height,
                "\(key) side summary should fit within \(frame.height) pt"
            )
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
