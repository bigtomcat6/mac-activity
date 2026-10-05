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
            (Fixtures.manyToOne, ["source:source", "source:battery"]),
            (Fixtures.manyToMany, ["source:source", "source:unknown", "sink:battery", "sink:mac"]),
        ]
        for (presentation, ids) in cases {
            let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: 320)
            XCTAssertEqual(plan.flowLabels.map(\.nodeID), ids)
            XCTAssertEqual(plan.flowLabels.count, plan.layout.flowLabelFrames.count)
            XCTAssertFalse(plan.exposesPairwiseEdges)
        }
    }

    func testRenderPlanFallsBackToGroupedBelowWidthFloor() {
        let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.manyToMany, width: 319)
        XCTAssertEqual(plan.layout.effectiveMode, .grouped)
        XCTAssertTrue(plan.flowLabels.isEmpty)
        XCTAssertNotNil(plan.totalsText)
    }

    func testTotalsIncludeBalancedManyToManyAndPartialGroupedValues() throws {
        let balanced = PowerFlowDiagramRenderPlan(presentation: Fixtures.manyToMany, width: 320)
        XCTAssertEqual(balanced.sourceTotalText, "57 W")
        XCTAssertEqual(balanced.sinkTotalText, "57 W")
        let grouped = PowerFlowDiagramRenderPlan(presentation: Fixtures.grouped, width: 320)
        XCTAssertEqual(grouped.sourceTotalText, "≥57 W")
        XCTAssertEqual(grouped.sinkTotalText, "57 W")
        XCTAssertTrue(try XCTUnwrap(grouped.totalsText).contains("≥57 W"))
        XCTAssertNil(PowerFlowDiagramRenderPlan(presentation: Fixtures.oneToOne, width: 320).totalsText)
        XCTAssertNil(PowerFlowDiagramRenderPlan(presentation: Fixtures.oneToOne, width: 320).qualityText)
    }

    func testPartialExpandedPresentationCarriesQualityTextInsideThePanel() throws {
        let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.missingSource, width: 320)
        XCTAssertNotNil(plan.qualityText)
        XCTAssertNotNil(plan.totalsText)
    }

    func testMissingCounterpartsDoNotAcquireInferredValues() {
        let source = PowerFlowDiagramRenderPlan(presentation: Fixtures.missingSource, width: 320)
        let sink = PowerFlowDiagramRenderPlan(presentation: Fixtures.missingSink, width: 320)
        XCTAssertEqual(source.sourceTotalText, "—")
        XCTAssertEqual(sink.sinkTotalText, "—")
        XCTAssertEqual(sink.flowLabels.map(\.text), ["—"])
    }

    func testScreenshotSplitAndMergeKeepTotalsInsideTheSingleEndpoint() {
        let split = PowerFlowDiagramRenderPlan(presentation: Fixtures.screenshotCharging, width: 384)
        let merge = PowerFlowDiagramRenderPlan(presentation: Fixtures.screenshotCombined, width: 384)
        XCTAssertEqual(split.endpointPowerLabels, ["source:source": "36W"])
        XCTAssertEqual(merge.endpointPowerLabels, ["sink:mac": "61W"])
        XCTAssertEqual(split.flowLabels.map(\.text), ["15.52 W", "20.10 W"])
        XCTAssertEqual(merge.flowLabels.map(\.text), ["28.39 W", "32.93 W"])
        for layout in [split.layout, merge.layout] {
            for label in layout.flowLabelFrames {
                XCTAssertEqual(label.midX, 192, accuracy: 0.001)
            }
        }
        // The screenshot's two input bands are ~112:128, not equal height.
        let bands = merge.layout.sourceFrames
        XCTAssertEqual(bands[0].height / bands[1].height, 28.39 / 32.93, accuracy: 0.001)
        XCTAssertEqual(PowerFlowDiagramPalette.symbol(for: .externalPower), "bolt.fill")
        XCTAssertEqual(PowerFlowDiagramPalette.symbol(for: .battery, charging: true), "battery.100.bolt")
    }

    func testReduceMotionDisablesGeometryAnimation() {
        XCTAssertNil(PowerFlowDiagramMotion.animation(reduceMotion: true))
        XCTAssertNotNil(PowerFlowDiagramMotion.animation(reduceMotion: false))
    }

    func testFlowGlowRunsOnlyWhileAnActiveDiagramIsVisibleAndMotionIsAllowed() {
        XCTAssertTrue(PowerFlowDiagramMotion.shouldAnimate(
            mode: .expanded(.oneToOne), isVisible: true, reduceMotion: false
        ))
        XCTAssertFalse(PowerFlowDiagramMotion.shouldAnimate(
            mode: .expanded(.oneToOne), isVisible: false, reduceMotion: false
        ))
        XCTAssertFalse(PowerFlowDiagramMotion.shouldAnimate(
            mode: .expanded(.oneToOne), isVisible: true, reduceMotion: true
        ))
        XCTAssertFalse(PowerFlowDiagramMotion.shouldAnimate(
            mode: .idle, isVisible: true, reduceMotion: false
        ))
    }

    func testFlowGlowPhaseAdvancesAndWrapsWithoutADataRefresh() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(PowerFlowDiagramMotion.glowPhase(at: start), 0, accuracy: 0.001)
        XCTAssertEqual(PowerFlowDiagramMotion.glowPhase(at: start.addingTimeInterval(0.9)), 0.25, accuracy: 0.001)
        XCTAssertEqual(PowerFlowDiagramMotion.glowPhase(at: start.addingTimeInterval(2.7)), 0.75, accuracy: 0.001)
        XCTAssertEqual(PowerFlowDiagramMotion.glowPhase(at: start.addingTimeInterval(3.6)), 0, accuracy: 0.001)
    }

    func testFlowPulseHighlightsSourceBeforeDestinationAndLeavesARest() {
        let departure = PowerFlowDiagramMotion.pulse(at: 0.4 / 3.6)
        XCTAssertGreaterThan(departure.sourceStrength, 0.95)
        XCTAssertEqual(departure.sinkStrength, 0)
        XCTAssertEqual(departure.opacity, 0)

        let transit = PowerFlowDiagramMotion.pulse(at: 1.6 / 3.6)
        XCTAssertEqual(transit.sourceStrength, 0)
        XCTAssertEqual(transit.sinkStrength, 0)
        XCTAssertGreaterThan(transit.opacity, 0.95)
        XCTAssertGreaterThan(transit.blueMix, 0.3)
        XCTAssertLessThan(transit.blueMix, 0.7)

        let arrival = PowerFlowDiagramMotion.pulse(at: 2.5 / 3.6)
        XCTAssertEqual(arrival.sourceStrength, 0)
        XCTAssertGreaterThan(arrival.sinkStrength, 0.95)
        XCTAssertGreaterThan(arrival.opacity, 0)
        XCTAssertLessThan(arrival.opacity, 0.6)

        let rest = PowerFlowDiagramMotion.pulse(at: 3.5 / 3.6)
        XCTAssertEqual(rest.sourceStrength, 0)
        XCTAssertEqual(rest.sinkStrength, 0)
        XCTAssertEqual(rest.opacity, 0)
    }

    func testActivityDistinguishesUnknownIdentityFromMissingPower() {
        XCTAssertTrue(PowerFlowDiagramActivity.hasKnownFlow(Fixtures.knownUnknownInput))
        XCTAssertTrue(PowerFlowDiagramActivity.hasKnownFlow(Fixtures.knownUnknownOutput))
        XCTAssertTrue(PowerFlowDiagramActivity.hasKnownFlow(Fixtures.partialMixed))
        XCTAssertFalse(PowerFlowDiagramActivity.isKnown(.source(1), in: Fixtures.partialMixed))
        XCTAssertTrue(PowerFlowDiagramActivity.isKnown(.source(0), in: Fixtures.partialMixed))
        for presentation in [Fixtures.missingSource, Fixtures.missingSink, Fixtures.unavailableActive] {
            XCTAssertFalse(PowerFlowDiagramActivity.hasKnownFlow(presentation))
            XCTAssertFalse(PowerFlowDiagramMotion.shouldAnimate(
                mode: presentation.preferredMode, isVisible: true, reduceMotion: false,
                hasKnownFlow: PowerFlowDiagramActivity.hasKnownFlow(presentation)
            ))
        }
    }

    func testCriticalBranchValuesFitTheirReadoutFramesAtMinimumScale() {
        for presentation in [Fixtures.oneToOne, Fixtures.oneToMany, Fixtures.manyToOne, Fixtures.manyToMany] {
            let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: 320)
            for (label, frame) in zip(plan.flowLabels, plan.layout.flowLabelFrames) {
                let width = (label.text as NSString).size(withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
                ]).width
                XCTAssertLessThanOrEqual(width * 0.72, frame.width, label.text)
            }
        }
    }

    func testThinRoundedBranchesKeepVisibleNumberBoundsAndZeroHundredTopology() {
        for pair in [[50.0, 50], [95, 5], [32.65, 9.70], [99.999, 0.001], [0, 100], [100, 0], [0, 0]] {
            let presentation = Fixtures.presentation(endpoints: [
                Fixtures.endpoint("source", type: .usbC, direction: .input, measurement: .watts(pair.reduce(0, +))),
                Fixtures.endpoint("battery", type: .battery, direction: .output, measurement: .watts(pair[0])),
                Fixtures.endpoint("mac", type: .mac, direction: .output, measurement: .watts(pair[1])),
            ])
            let expectedMode: PowerFlowDiagramMode = pair == [0, 0] ? .idle
                : pair.contains(0) ? .expanded(.oneToOne) : .expanded(.oneToMany)
            XCTAssertEqual(presentation.preferredMode, expectedMode)
            for width: CGFloat in [320, 384] {
                let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: width)
                XCTAssertEqual(plan.layout.effectiveMode, expectedMode)
                XCTAssertEqual(plan.flowLabels.count, pair == [0, 0] ? 0 : pair.contains(0) ? 1 : 2)
                let channel = PowerFlowDiagramSurfaceShape(layout: plan.layout, part: .channel).path(in: .zero).cgPath
                for (label, frame) in zip(plan.flowLabels, plan.layout.flowLabelFrames) {
                    let size = (label.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
                    XCTAssertLessThanOrEqual(size.width * 0.72, frame.width, label.text)
                    XCTAssertLessThanOrEqual(size.height, frame.height, label.text)
                    let halfWidth = min(size.width, frame.width) / 2
                    for x in [frame.midX - halfWidth, frame.midX + halfWidth] {
                        for y in [frame.midY - size.height / 2, frame.midY + size.height / 2] {
                            XCTAssertTrue(channel.contains(CGPoint(x: x, y: y)), "number ink escapes rounded branch: \(pair) \(label.text)")
                        }
                    }
                }
            }
        }
    }

    func testAllDiagramModesRenderAtRealEnergyWidthAndPressureWidth() throws {
        let presentations = [
            Fixtures.oneToOne, Fixtures.oneToMany, Fixtures.manyToOne, Fixtures.manyToMany,
            Fixtures.grouped, Fixtures.missingSource, Fixtures.missingSink,
            Fixtures.waiting, Fixtures.idle, Fixtures.unavailable,
        ]
        for colorScheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [384, 320, 319] {
                for presentation in presentations {
                    let renderer = ImageRenderer(content: PowerFlowDiagramView(presentation: presentation)
                        .frame(width: width)
                        .environment(\.colorScheme, colorScheme))
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.nsImage)
                    let expectedHeight: CGFloat = width >= 320 && presentation.sources.count + presentation.sinks.count > 2
                        && presentation.preferredMode != .grouped ? 97.5 : 78
                    XCTAssertEqual(image.size.height, expectedHeight, accuracy: 1)
                    XCTAssertEqual(image.size.width, width, accuracy: 1)
                    XCTAssertFalse(presentation.accessibilityLabel.isEmpty)
                }
            }
        }
    }

    // Measures the real production glyph ink rather than trusting a nominal
    // point size. The lightning bolt stays upright.
    func testNodeIconVisibleInkMatchesApprovedTargets() throws {
        let expectations: [(PowerFlowDiagramNodeKind, CGSize)] = [
            (.externalPower, CGSize(width: 9, height: 15)),
            (.mac, CGSize(width: 18, height: 11)),
        ]
        for (kind, target) in expectations {
            let ink = try measuredIconInk(kind: kind)
            XCTAssertEqual(
                ink.width, target.width, accuracy: 2.5,
                "\(kind) visible ink width \(ink.width) should track \(target.width)"
            )
            XCTAssertEqual(
                ink.height, target.height, accuracy: 2.5,
                "\(kind) visible ink height \(ink.height) should track \(target.height)"
            )
            XCTAssertEqual(ink.center.x, 0, accuracy: 1.0)
            XCTAssertEqual(ink.center.y, 0, accuracy: 1.0)
        }
    }

    // The moving gradient must retain a soft crest and vertical falloff.
    func testGlowHasASoftCrestAndVerticalFalloff() throws {
        let frame = CGRect(x: 0, y: 0, width: 270, height: 78)
        let canvas = ZStack {
            Color.black
            PowerFlowDiagramGlow(middle: frame)
        }
        .frame(width: frame.width, height: frame.height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        let core = blue(in: bitmap, at: CGPoint(x: frame.minX + frame.width * 0.83, y: frame.midY))
        let trailing = blue(in: bitmap, at: CGPoint(x: frame.minX + 4, y: frame.midY))
        let vertical = blue(
            in: bitmap,
            at: CGPoint(x: frame.minX + frame.width * 0.83, y: frame.midY - frame.height / 2 + 4)
        )

        XCTAssertGreaterThan(core, trailing + 0.05, "glow should crest in the middle-right, not at the left edge")
        XCTAssertGreaterThan(core, vertical + 0.02, "glow should fall off vertically before the panel edge")
        XCTAssertLessThan(core, 0.75, "glow must stay low-contrast without a saturated hard edge")
    }

    func testPowerFlowPulseTravelsFromYellowToBlueThenClears() throws {
        let frame = CGRect(x: 0, y: 0, width: 270, height: 78)
        func render(phase: CGFloat) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: ZStack {
                Color.black
                PowerFlowDiagramGlow(middle: frame, phase: phase)
            }
            .frame(width: frame.width, height: frame.height))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        }

        let yellowPhase = try render(phase: 1.05 / 3.6)
        let bluePhase = try render(phase: 2.1 / 3.6)
        let restPhase = try render(phase: 3.5 / 3.6)
        let yellow = color(in: yellowPhase, at: CGPoint(x: 70, y: 39), scale: 2)
        let blue = color(in: bluePhase, at: CGPoint(x: 224, y: 39), scale: 2)
        let ahead = color(in: yellowPhase, at: CGPoint(x: 224, y: 39), scale: 2)
        let rest = color(in: restPhase, at: CGPoint(x: 224, y: 39), scale: 2)
        XCTAssertGreaterThan(yellow.redComponent, yellow.blueComponent + 0.15)
        XCTAssertGreaterThan(yellow.greenComponent, yellow.blueComponent + 0.10)
        XCTAssertLessThan(ahead.redComponent, 0.03, "the pulse must not light the destination before arriving")
        XCTAssertGreaterThan(blue.blueComponent, blue.redComponent + 0.20)
        XCTAssertLessThan(max(rest.redComponent, rest.greenComponent, rest.blueComponent), 0.01,
                          "each pass ends with a clear interval")
    }

    func testSplitBranchesHaveGreenBatteryBlueMacAndAClearGap() throws {
        let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.oneToMany, width: 384)
        let renderer = ImageRenderer(content: PowerFlowDiagramView(presentation: Fixtures.oneToMany)
            .panel(plan: plan, phase: 2.1 / 3.6)
            .frame(width: 384, height: plan.layout.cardFrame.height)
            .background(Color.black))
        renderer.scale = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
        let upper = color(in: bitmap, at: CGPoint(x: 300, y: 18), scale: 2)
        let lower = color(in: bitmap, at: CGPoint(x: 300, y: 77), scale: 2)
        let gap = color(in: bitmap, at: CGPoint(x: 320, y: 52), scale: 2)
        XCTAssertGreaterThan(upper.greenComponent, upper.blueComponent + 0.08)
        XCTAssertGreaterThan(lower.blueComponent, lower.greenComponent + 0.08)
        XCTAssertLessThan(max(gap.redComponent, gap.greenComponent, gap.blueComponent), 0.02)
    }

    func testMergeDoesNotLeaveAVerticalBrightnessSeam() throws {
        let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.manyToMany, width: 384)
        let renderer = ImageRenderer(content: PowerFlowDiagramView(presentation: Fixtures.manyToMany)
            .flowLayer(plan: plan, phase: 2.1 / 3.6)
            .frame(width: 384, height: plan.layout.cardFrame.height).background(Color.black))
        renderer.scale = 2
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
        let junction = try XCTUnwrap(plan.layout.busFrame).minX
        let before = color(in: bitmap, at: CGPoint(x: junction - 1, y: 32), scale: 2).blueComponent
        let after = color(in: bitmap, at: CGPoint(x: junction + 1, y: 32), scale: 2).blueComponent
        for offset: CGFloat in [-0.5, 0, 0.5] {
            let atJoin = color(in: bitmap, at: CGPoint(x: junction + offset, y: 32), scale: 2).blueComponent
            XCTAssertGreaterThanOrEqual(atJoin, min(before, after) - 0.015,
                                       "adjoining paths must not create a dim vertical line")
        }
    }

    func testSegmentedShapeLeavesTransparentSeparators() throws {
        let layout = PowerFlowDiagramLayout.resolve(
            width: 384, preferredMode: .expanded(.oneToOne), sourceCount: 1, sinkCount: 1
        )
        let shape = PowerFlowDiagramSegmentedShape(
            source: layout.sourceSegment,
            middle: layout.middleSegment,
            sink: layout.sinkSegment,
            radius: layout.outerCornerRadius
        )
        let canvas = ZStack {
            Color.black
            shape.fill(Color.white)
        }
        .frame(width: 384, height: 78)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        // Sample inside each separator: it must stay dark (transparent over backdrop).
        for x in [52.0 + 2.5, 327.0 + 2.5] {
            let color = color(in: bitmap, at: CGPoint(x: x, y: 39), scale: 2)
            XCTAssertLessThan(color.redComponent, 0.1, "separator at x=\(x) must not be painted")
        }
        // Segment interiors are opaque.
        for x in [26.0, 192.0, 358.0] {
            let color = color(in: bitmap, at: CGPoint(x: x, y: 39), scale: 2)
            XCTAssertGreaterThan(color.redComponent, 0.9, "segment at x=\(x) should be filled")
        }
    }

    func testGlassSurfaceRoundsEveryPieceWithoutMovingTheSeparators() {
        let layout = PowerFlowDiagramLayout.resolve(
            width: 384, preferredMode: .expanded(.oneToOne), sourceCount: 1, sinkCount: 1
        )
        // CGPath hit testing: SwiftUI's Path.contains misreads multi-subpath rounded rects.
        let surface = PowerFlowDiagramSurfaceShape(layout: layout).path(in: .zero).cgPath
        let square = PowerFlowDiagramSegmentedShape(
            source: layout.sourceSegment,
            middle: layout.middleSegment,
            sink: layout.sinkSegment,
            radius: layout.outerCornerRadius
        ).path(in: .zero).cgPath

        // Corners facing the separators are rounded on the glass silhouette only.
        let innerCorners = [
            CGPoint(x: layout.sourceSegment.maxX - 1, y: layout.sourceSegment.minY + 1),
            CGPoint(x: layout.middleSegment.minX + 1, y: layout.middleSegment.minY + 1),
            CGPoint(x: layout.middleSegment.maxX - 1, y: layout.middleSegment.maxY - 1),
            CGPoint(x: layout.sinkSegment.minX + 1, y: layout.sinkSegment.maxY - 1),
        ]
        for corner in innerCorners {
            XCTAssertFalse(surface.contains(corner), "\(corner)")
            XCTAssertTrue(square.contains(corner), "\(corner)")
        }
        // Separators stay open and every piece keeps its frame.
        XCTAssertFalse(surface.contains(CGPoint(x: layout.sourceSegment.maxX + 1, y: layout.sourceSegment.midY)))
        XCTAssertFalse(surface.contains(CGPoint(x: layout.middleSegment.maxX + 1, y: layout.middleSegment.midY)))
        XCTAssertEqual(surface.boundingBoxOfPath, square.boundingBoxOfPath)
        for segment in [layout.sourceSegment, layout.middleSegment, layout.sinkSegment] {
            XCTAssertTrue(surface.contains(CGPoint(x: segment.midX, y: segment.minY + 0.5)))
            XCTAssertTrue(surface.contains(CGPoint(x: segment.midX, y: segment.maxY - 0.5)))
        }
    }

    func testFlowingChannelUsesModuleScrimInsteadOfSystemMaterial() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/MacActivityApp/Views/PowerFlowDiagramRibbon.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("Material"))
        XCTAssertTrue(source.contains("channel.fill(DashboardCardChrome.glassScrim(for: colorScheme, contrast: contrast))"))
        XCTAssertTrue(source.contains("Color.clear.glassEffect(.clear, in: channel)"))
        XCTAssertEqual(source.components(separatedBy: ".dashboardModuleGlass(in:").count - 1, 2)
    }

    func testGroupedSideSummaryContentHoldsTwoRepresentativesWithinDiagramHeight() throws {
        let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.grouped, width: 384)
        let cases: [(PowerFlowDiagramSideSummary, AppLocalization.Key, CGRect)] = [
            (Fixtures.grouped.sourceSummary, .powerFlowSourcesCount, try XCTUnwrap(plan.layout.groupedSourceFrame)),
            (Fixtures.grouped.sinkSummary, .powerFlowOutputsCount, try XCTUnwrap(plan.layout.groupedSinkFrame)),
        ]
        for (summary, key, frame) in cases {
            let host = NSHostingView(
                rootView: PowerFlowDiagramSideSummaryView(summary: summary, countKey: key)
                    .frame(width: frame.width, height: frame.height)
            )
            host.layoutSubtreeIfNeeded()
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
            .environment(\.colorScheme, .dark))
        XCTAssertNotNil(renderer.nsImage)
        XCTAssertFalse(presentation.accessibilityLabel.isEmpty)
    }

    // MARK: - Finding 1: expanded partial/unbalanced totals footer

    func testExpandedPartialRendersLocalizedInOutTotalsFooter() throws {
        let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.missingSource, width: 384)
        XCTAssertTrue(plan.showsExpandedTotalsFooter)
        let footer = try XCTUnwrap(plan.layout.totalsFooterFrame)
        XCTAssertEqual(footer.maxY, 78, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(footer.height, 18)
        XCTAssertTrue(plan.layout.middleSegment.contains(footer))

        let totals = try XCTUnwrap(plan.totalsText)
        XCTAssertEqual(totals, AppLocalization.string(.powerFlowTotals, "—", "24 W"))
        XCTAssertTrue(totals.contains("—"), "missing input must stay explicit: \(totals)")

        // Labels move above the footer: no overlap.
        for label in plan.layout.flowLabelFrames {
            XCTAssertFalse(label.intersects(footer), "\(label) overlaps \(footer)")
        }
        // Actually rendered ink exists in the footer band.
        let ink = try renderedInkCount(
            presentation: Fixtures.missingSource, width: 384, region: footer
        )
        XCTAssertGreaterThan(ink, 20, "footer totals must be visibly rendered")
    }

    func testExpandedUnbalancedRendersBothKnownTotals() throws {
        let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.unbalanced, width: 384)
        XCTAssertTrue(plan.showsExpandedTotalsFooter)
        XCTAssertEqual(plan.sourceTotalText, "45 W")
        XCTAssertEqual(plan.sinkTotalText, "27 W")
        let totals = try XCTUnwrap(plan.totalsText)
        XCTAssertTrue(totals.contains("45 W"), totals)
        XCTAssertTrue(totals.contains("27 W"), totals)

        let footer = try XCTUnwrap(plan.layout.totalsFooterFrame)
        let ink = try renderedInkCount(
            presentation: Fixtures.unbalanced, width: 384, region: footer
        )
        XCTAssertGreaterThan(ink, 20, "both totals must be visibly rendered")
    }

    func testNormalExpandedModesDoNotReserveAFooter() {
        for presentation in [Fixtures.oneToOne, Fixtures.oneToMany, Fixtures.manyToOne, Fixtures.manyToMany] {
            let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: 384)
            XCTAssertFalse(plan.showsExpandedTotalsFooter, presentation.accessibilityLabel)
            XCTAssertNil(plan.layout.totalsFooterFrame)
        }
    }

    // MARK: - Finding 2: grouped legibility

    func testGroupedSidesWidenAndActualGlyphsFit() throws {
        for width: CGFloat in [320, 384] {
            let plan = PowerFlowDiagramRenderPlan(presentation: Fixtures.grouped, width: width)
            let source = try XCTUnwrap(plan.layout.groupedSourceFrame)
            let center = try XCTUnwrap(plan.layout.groupedCenterFrame)
            let sink = try XCTUnwrap(plan.layout.groupedSinkFrame)
            XCTAssertGreaterThanOrEqual(source.width, 94, "width \(width)")
            XCTAssertLessThanOrEqual(source.width, 112.001, "width \(width)")
            XCTAssertEqual(source.height, 78, accuracy: 0.001)
            XCTAssertGreaterThan(center.width, 0)
            let separator = 5 * width / 384
            XCTAssertEqual(center.minX - source.maxX, separator, accuracy: 0.02)
            XCTAssertEqual(sink.minX - center.maxX, separator, accuracy: 0.02)

            try assertGroupedSummaryFits(
                summary: Fixtures.grouped.sourceSummary,
                countKey: .powerFlowSourcesCount,
                frame: source, edge: .leading, width: width
            )
            try assertGroupedSummaryFits(
                summary: Fixtures.grouped.sinkSummary,
                countKey: .powerFlowOutputsCount,
                frame: sink, edge: .trailing, width: width
            )
        }
    }

    // MARK: - Finding 3: unavailable / synthetic cues

    func testUnavailableNodeRendersDashedCueAndSyntheticUsesQuestionSymbol() throws {
        let unavailable = PowerFlowDiagramNode(
            id: "u", kind: .externalPower, title: "USB-C",
            measurement: .unavailable, provenance: .absent, isSynthetic: false
        )
        let measured = PowerFlowDiagramNode(
            id: "m", kind: .externalPower, title: "USB-C",
            measurement: .exact(10), provenance: .measured, isSynthetic: false
        )
        let unavailableInk = try measuredIconInk(node: unavailable)
        let measuredInk = try measuredIconInk(node: measured)
        XCTAssertGreaterThan(
            unavailableInk.height, measuredInk.height + 1,
            "unavailable must add a dashed cue below the glyph"
        )
        XCTAssertEqual(PowerFlowDiagramPalette.symbol(for: .unknown), "questionmark.circle")

        let synthetic = PowerFlowDiagramNode(
            id: "s", kind: .unknown, title: "Unknown Input",
            measurement: .unavailable, provenance: .absent, isSynthetic: true
        )
        XCTAssertTrue(PowerFlowDiagramHelp.node(synthetic).contains("Unknown Input"))
    }

    // Grouped representative rows must reuse the same node-aware compact icon as
    // the expanded lanes: a known-unavailable or synthetic representative keeps
    // the dashed cue and the endpoint help instead of a bare glyph.
    func testGroupedRepresentativeReusesCompactUnavailableCueAndNodeHelp() throws {
        let unavailableSynthetic = PowerFlowDiagramNode(
            id: "u", kind: .unknown, title: "Unknown Input",
            measurement: .unavailable, provenance: .absent, isSynthetic: true
        )
        let measured = PowerFlowDiagramNode(
            id: "m", kind: .unknown, title: "Unknown Input",
            measurement: .exact(10), provenance: .measured, isSynthetic: false
        )

        let unavailableInk = try measuredIconInk(node: unavailableSynthetic, compact: true)
        let measuredInk = try measuredIconInk(node: measured, compact: true)
        XCTAssertGreaterThan(unavailableInk.width, 0)
        XCTAssertGreaterThan(measuredInk.width, 0)
        XCTAssertGreaterThan(
            unavailableInk.height, measuredInk.height + 1,
            "compact grouped representative must keep the unavailable cue"
        )

        let help = PowerFlowDiagramHelp.node(unavailableSynthetic)
        XCTAssertTrue(help.contains("Unknown Input"), help)
        XCTAssertFalse(help.contains("10"), "synthetic help must not invent a value")

        // The production side summary renders the node-aware representative row.
        let summary = PowerFlowDiagramSideSummary(
            memberCount: 1, total: .unavailable, provenance: .absent,
            representatives: [unavailableSynthetic]
        )
        XCTAssertGreaterThan(
            try sideSummaryInk(summary: summary, countKey: .powerFlowSourcesCount), 20,
            "grouped representative row must render visible ink"
        )
    }

    // Composed containment (not just isolated glyph ink): in the real spacing-0
    // grouped summary the compact unavailable cue must reserve its own vertical
    // footprint instead of bleeding into the following representative row.
    func testCompactUnavailableCueStaysInsideItsComposedSummaryRow() throws {
        let unavailable = PowerFlowDiagramNode(
            id: "u", kind: .unknown, title: "Unknown Input",
            measurement: .unavailable, provenance: .absent, isSynthetic: false
        )
        let measuredSink = PowerFlowDiagramNode(
            id: "m", kind: .mac, title: "Mac",
            measurement: .exact(27), provenance: .measured, isSynthetic: false
        )
        let summary = PowerFlowDiagramSideSummary(
            memberCount: 2, total: .unavailable, provenance: .absent,
            representatives: [unavailable, measuredSink]
        )
        let runs = try iconBandRuns(summary: summary, countKey: .powerFlowSourcesCount)

        // The 1 pt dashed cue must render as its own short ink run between the
        // two glyphs. Without the reserved footprint it merged into the next row.
        guard let cueIndex = runs.firstIndex(where: { $0.maxY - $0.minY <= 2.5 }),
              cueIndex + 1 < runs.count else {
            XCTFail("compact unavailable cue did not render as a contained run: \(runs)")
            return
        }
        XCTAssertLessThanOrEqual(
            runs[cueIndex].maxY, runs[cueIndex + 1].minY,
            "cue must not intrude into the next representative row"
        )
    }

    // Native German captures must format values through the runtime locale, not
    // the explicitly-bundled builder strings. This locks the override contract
    // the fixture window relies on.
    func testGermanRuntimeFormatterUsesLocalizedDecimalSeparatorUnderOverride() {
        let previous = AppLocalization.explicitPreferredLanguageIdentifier()
        defer { AppLocalization.setPreferredLanguageIdentifier(previous) }

        // Explicit "en" baseline: `nil` falls back to the host system locale and
        // would render German/French separators on a non-English machine.
        AppLocalization.setPreferredLanguageIdentifier("en")
        let english = PowerFlowDiagramRenderPlan.powerText(.exact(21.46), provenance: .measured)
        AppLocalization.setPreferredLanguageIdentifier("de")
        let german = PowerFlowDiagramRenderPlan.powerText(.exact(21.46), provenance: .measured)

        XCTAssertEqual(english, "21.46 W")
        XCTAssertEqual(german, "21,46 W", "runtime value must use the active German locale")
    }

    // MARK: - Finding 4: endpoint help

    func testNodeHelpExplainsEndpointAndProvenanceNotJustNumber() {
        let usbC = PowerFlowDiagramNode(
            id: "a", kind: .externalPower, title: "USB-C",
            measurement: .exact(45), provenance: .measured, isSynthetic: false
        )
        let magSafe = PowerFlowDiagramNode(
            id: "b", kind: .externalPower, title: "MagSafe",
            measurement: .exact(45), provenance: .measured, isSynthetic: false
        )
        let derived = PowerFlowDiagramNode(
            id: "c", kind: .mac, title: "Mac",
            measurement: .exact(27), provenance: .derived, isSynthetic: false
        )
        XCTAssertTrue(PowerFlowDiagramHelp.node(usbC).contains("USB-C"))
        XCTAssertTrue(PowerFlowDiagramHelp.node(usbC).contains("45 W"))
        XCTAssertNotEqual(PowerFlowDiagramHelp.node(usbC), "45 W")
        XCTAssertNotEqual(PowerFlowDiagramHelp.node(usbC), PowerFlowDiagramHelp.node(magSafe))
        XCTAssertEqual(
            PowerFlowDiagramHelp.node(derived),
            AppLocalization.string(.powerFlowAccessibilityNodeDerived, "Mac", "27 W")
        )
    }

    // MARK: - Finding 5: idle context

    func testIdleCombinedAccessibilityIncludesIdleIdentities() {
        let presentation = Fixtures.idle
        XCTAssertFalse(presentation.idleEndpoints.isEmpty)
        let combined = PowerFlowDiagramHelp.combinedAccessibilityLabel(presentation)
        XCTAssertGreaterThan(combined.count, presentation.accessibilityLabel.count)
        XCTAssertTrue(combined.contains(PowerFlowDiagramHelp.node(presentation.idleEndpoints[0])))
        XCTAssertFalse(PowerFlowDiagramMode.idle.showsFlowGlow, "idle must not imply flow")
        XCTAssertFalse(PowerFlowDiagramMode.unavailable.showsFlowGlow)
        XCTAssertTrue(PowerFlowDiagramMode.grouped.showsFlowGlow)
        XCTAssertTrue(PowerFlowDiagramMode.expanded(.oneToOne).showsFlowGlow)
    }

    // MARK: - Finding 7 / C: glow clipped to middle

    func testGlowIsClippedToMiddleAndNeverTintsTheSink() throws {
        let layout = PowerFlowDiagramLayout.resolve(
            width: 384, preferredMode: .expanded(.oneToOne), sourceCount: 1, sinkCount: 1
        )
        let canvas = ZStack {
            Color.black
            PowerFlowDiagramGlow(middle: layout.middleSegment)
        }
        .frame(width: 384, height: 78)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        let scale = CGFloat(bitmap.pixelsWide) / 384
        func blueExcess(_ x: CGFloat) -> Double {
            let color = color(in: bitmap, at: CGPoint(x: x, y: 39), scale: scale)
            return Double(color.blueComponent) - Double(color.redComponent)
        }
        XCTAssertGreaterThan(blueExcess(281), 0.08, "glow crest must be visible at ~83%")
        XCTAssertLessThan(blueExcess(350), 0.02, "glow must not tint the sink segment")
        XCTAssertLessThan(blueExcess(50), 0.02, "glow must not tint the source segment")
    }

    // MARK: - Finding A: ordinary SF font contract

    func testWattLabelUsesOrdinarySFNotMonospacedAndCharcoalInk() throws {
        let production = try textInk(PowerFlowDiagramWattLabel(text: "41.5 W"))
        let monospaced = try textInk(
            Text("41.5 W").font(.system(size: 14, weight: .semibold, design: .monospaced))
        )
        XCTAssertLessThan(
            production.width, monospaced.width - 1.0,
            "ordinary SF must be narrower than .monospaced"
        )
        let ink = production.darkest
        XCTAssertGreaterThan(ink.redComponent, 0.10)
        XCTAssertLessThan(ink.redComponent, 0.32, "charcoal, not pure black")
        XCTAssertGreaterThan(ink.blueComponent, ink.redComponent, "charcoal has a cool bias")
    }

    // MARK: - helpers

    private struct TextInk {
        var width: CGFloat
        var height: CGFloat
        var darkest: NSColor
    }

    private func textInk(_ view: some View) throws -> TextInk {
        let canvasSize = CGSize(width: 120, height: 40)
        let renderer = ImageRenderer(content: ZStack {
            Color.white
            view
        }
        .frame(width: canvasSize.width, height: canvasSize.height))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let scale = CGFloat(bitmap.pixelsWide) / canvasSize.width
        var minX = bitmap.pixelsWide
        var maxX = -1
        var minY = bitmap.pixelsHigh
        var maxY = -1
        var darkest = NSColor.black
        var darkestLuminance: CGFloat = 1
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if luminance < 0.8 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                if luminance < darkestLuminance {
                    darkestLuminance = luminance
                    darkest = color
                }
            }
        }
        guard maxX >= minX else {
            XCTFail("no text ink found")
            return TextInk(width: 0, height: 0, darkest: .black)
        }
        return TextInk(
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale,
            darkest: darkest
        )
    }

    /// Renders the production view on the opaque fallback surface and counts
    /// dark pixels inside `region` — proves the totals are actually visible.
    private func renderedInkCount(
        presentation: PowerFlowDiagramPresentation,
        width: CGFloat,
        region: CGRect
    ) throws -> Int {
        let content = PowerFlowDiagramView(presentation: presentation)
            .frame(width: width)
            .environment(\._accessibilityReduceTransparency, true)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let scale = CGFloat(bitmap.pixelsWide) / width
        let minX = max(0, Int(region.minX * scale))
        let maxX = min(bitmap.pixelsWide - 1, Int(region.maxX * scale))
        let minY = max(0, Int(region.minY * scale))
        let maxY = min(bitmap.pixelsHigh - 1, Int(region.maxY * scale))
        var count = 0
        for x in minX...maxX {
            for y in minY...maxY {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if luminance < 0.6 { count += 1 }
            }
        }
        return count
    }

    /// Real glyph width check for a grouped side summary: counts, representatives
    /// values, the aggregate and the "N more" label must fit the padded frame.
    private func assertGroupedSummaryFits(
        summary: PowerFlowDiagramSideSummary,
        countKey: AppLocalization.Key,
        frame: CGRect,
        edge: PowerFlowDiagramSideEdge,
        width: CGFloat
    ) throws {
        let horizontalInset: CGFloat = 12
        let available = frame.width - horizontalInset
        let font = NSFont.systemFont(ofSize: 9)
        let semibold = NSFont.systemFont(ofSize: 9, weight: .semibold)

        func widthOf(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        let count = AppLocalization.string(countKey, Int64(summary.memberCount))
        XCTAssertLessThanOrEqual(widthOf(count, semibold), available, "\(count) @\(width)")

        for node in summary.representatives {
            if let value = PowerFlowDiagramRenderPlan.powerText(node.measurement, provenance: node.provenance) {
                let used = widthOf(value, semibold) + 12
                XCTAssertLessThanOrEqual(used, available, "\(value) @\(width)")
            }
        }
        if let total = PowerFlowDiagramRenderPlan.powerText(summary.total, provenance: summary.provenance) {
            XCTAssertLessThanOrEqual(widthOf(total, semibold), available, "\(total) @\(width)")
        }
        let hidden = summary.memberCount - summary.representatives.count
        if hidden > 0 {
            let more = AppLocalization.string(.powerFlowMoreCount, Int64(hidden))
            XCTAssertLessThanOrEqual(widthOf(more, font), available / 2, "\(more) @\(width)")
        }
    }

    private struct Ink {
        var width: CGFloat
        var height: CGFloat
        var center: CGPoint
    }

    private func measuredIconInk(kind: PowerFlowDiagramNodeKind) throws -> Ink {
        let node = PowerFlowDiagramNode(
            id: "icon", kind: kind, title: "Icon", measurement: .exact(1),
            provenance: .measured, isSynthetic: false
        )
        return try measuredIconInk(node: node)
    }

    private func measuredIconInk(node: PowerFlowDiagramNode, compact: Bool = false) throws -> Ink {
        let canvasSize = CGSize(width: 60, height: 60)
        let renderer = ImageRenderer(content: ZStack {
            Color.white
            PowerFlowDiagramNodeIcon(node: node, compact: compact)
        }
        .frame(width: canvasSize.width, height: canvasSize.height))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        let scale = CGFloat(bitmap.pixelsWide) / canvasSize.width
        var minX = bitmap.pixelsWide
        var minY = bitmap.pixelsHigh
        var maxX = -1
        var maxY = -1
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if luminance < 0.85 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            XCTFail("no visible ink found for \(node.kind)")
            return Ink(width: 0, height: 0, center: .zero)
        }
        let width = CGFloat(maxX - minX + 1) / scale
        let height = CGFloat(maxY - minY + 1) / scale
        let centerX = (CGFloat(minX + maxX) / 2) / scale - canvasSize.width / 2
        let centerY = (CGFloat(minY + maxY) / 2) / scale - canvasSize.height / 2
        return Ink(width: width, height: height, center: CGPoint(x: centerX, y: centerY))
    }

    /// Renders the production grouped side-summary and counts dark pixels. Used
    /// as a real-ink smoke regression for the node-aware representative row.
    private func sideSummaryInk(
        summary: PowerFlowDiagramSideSummary,
        countKey: AppLocalization.Key
    ) throws -> Int {
        let size = CGSize(width: 94, height: PowerFlowDiagramLayout.cardHeight)
        let renderer = ImageRenderer(content: ZStack {
            Color.white
            PowerFlowDiagramSideSummaryView(summary: summary, countKey: countKey)
        }
        .frame(width: size.width, height: size.height))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if luminance < 0.85 { count += 1 }
            }
        }
        return count
    }

    /// Renders the production grouped side summary and returns contiguous
    /// vertical ink runs inside the leading icon column. The dashed cue is the
    /// short run between the glyphs; if it bled into the following row the runs
    /// would merge instead of staying separated.
    private func iconBandRuns(
        summary: PowerFlowDiagramSideSummary,
        countKey: AppLocalization.Key
    ) throws -> [(minY: CGFloat, maxY: CGFloat)] {
        let size = CGSize(width: 94, height: PowerFlowDiagramLayout.cardHeight)
        let renderer = ImageRenderer(content: ZStack {
            Color.white
            PowerFlowDiagramSideSummaryView(summary: summary, countKey: countKey)
        }
        .frame(width: size.width, height: size.height))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        // 8 pt leading inset .. the compact glyph/cue right edge (~16 pt).
        let minX = max(0, Int((8 * scale).rounded(.down)))
        let maxX = min(bitmap.pixelsWide - 1, Int((16 * scale).rounded(.up)) - 1)

        var hasInk = [Bool](repeating: false, count: bitmap.pixelsHigh)
        for y in 0..<bitmap.pixelsHigh {
            for x in minX...maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent
                    + 0.7152 * color.greenComponent
                    + 0.0722 * color.blueComponent
                if luminance < 0.85 {
                    hasInk[y] = true
                    break
                }
            }
        }

        var runs: [(minY: CGFloat, maxY: CGFloat)] = []
        var start: Int?
        for y in 0..<bitmap.pixelsHigh {
            if hasInk[y] {
                if start == nil { start = y }
            } else if let s = start {
                runs.append((CGFloat(s) / scale, CGFloat(y - 1) / scale))
                start = nil
            }
        }
        if let s = start {
            runs.append((CGFloat(s) / scale, CGFloat(bitmap.pixelsHigh - 1) / scale))
        }
        return runs
    }

    private func blue(in bitmap: NSBitmapImageRep, at point: CGPoint) -> Double {
        let scale = CGFloat(bitmap.pixelsWide) / 270
        let color = color(in: bitmap, at: point, scale: scale)
        return Double(color.blueComponent) - Double(color.redComponent)
    }

    private func color(in representation: NSBitmapImageRep, at point: CGPoint, scale: CGFloat) -> NSColor {
        let x = min(representation.pixelsWide - 1, max(0, Int(point.x * scale)))
        let y = min(representation.pixelsHigh - 1, max(0, Int(point.y * scale)))
        return representation.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .clear
    }
}
