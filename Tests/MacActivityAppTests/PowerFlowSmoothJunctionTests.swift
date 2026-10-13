import AppKit
import SwiftUI
import XCTest
@testable import MacActivityApp

final class PowerFlowSmoothJunctionTests: XCTestCase {
    @MainActor
    func testLocalJoinLightDoesNotDoubleNormalBusLightOrIlluminateFooter() throws {
        let f = PowerFlowDiagramFixtures.self
        let presentation = f.presentation(endpoints: [
            f.endpoint("a", type: .usbC, direction: .input, measurement: .watts(50)),
            f.endpoint("b", type: .battery, direction: .input, measurement: .watts(50)),
            f.endpoint("c", type: .battery, direction: .output, measurement: .watts(30)),
            f.endpoint("d", type: .mac, direction: .output, measurement: .watts(30)),
        ])
        let plan = PowerFlowDiagramRenderPlan(presentation: presentation, width: 384)
        let layout = plan.layout, bus = try XCTUnwrap(layout.busFrame)
        func bitmap(_ view: some View) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view.frame(width: 384, height: layout.cardFrame.height).background(.black))
            renderer.scale = 4
            return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(renderer.nsImage?.tiffRepresentation)))
        }
        let actual = try bitmap(PowerFlowDiagramRibbonLayer(presentation: presentation, layout: layout, phase: 2.1 / 3.6))
        let reference = try bitmap(PowerFlowDiagramGlow(middle: layout.middleSegment, phase: 2.1 / 3.6,
            tint: PowerFlowDiagramPalette.neutral, sourceTint: PowerFlowDiagramPalette.neutral))
        func brightness(_ image: NSBitmapImageRep, _ p: CGPoint) -> CGFloat {
            let c = image.colorAt(x: Int(p.x * 4), y: Int(p.y * 4))!.usingColorSpace(.sRGB)!
            return c.redComponent + c.greenComponent + c.blueComponent
        }
        let center = CGPoint(x: bus.midX, y: bus.midY)
        XCTAssertEqual(brightness(actual, center), brightness(reference, center), accuracy: 0.02,
                       "local rounding must not stack a second pulse over the normal bus")
        let footer = try XCTUnwrap(layout.totalsFooterFrame)
        XCTAssertLessThan(brightness(actual, CGPoint(x: footer.midX, y: footer.midY)), 0.01)
        XCTAssertGreaterThan(brightness(actual, CGPoint(x: bus.minX - 1, y: layout.ribbons[0].endCenterY + layout.ribbons[0].endHeight / 2)), 0.02,
                             "the newly filled old cusp must receive actual light")
    }

    func testExposedRibbonCapsUseFullLayoutRadiusClampedToHalfThickness() {
        for width: CGFloat in [320, 384] {
            for topology in [PowerFlowDiagramTopology.oneToMany, .manyToOne, .manyToMany] {
                let layout = PowerFlowDiagramLayout.resolve(width: width, preferredMode: .expanded(topology),
                    sourceCount: topology == .oneToMany ? 1 : 2,
                    sinkCount: topology == .manyToOne ? 1 : 2,
                    sourceWatts: [31.5, 10.55], sinkWatts: [31.5, 10.55])
                for ribbon in layout.ribbons where ribbon.role != .bus {
                    let path = PowerFlowRibbonShape(geometry: ribbon, layout: layout).path(in: .zero)
                    var start: CGPoint?
                    var outerEnd: CGPoint?
                    path.forEach {
                        if case .move(let p) = $0 { start = p }
                        if case .quadCurve(let p, _) = $0, p.x == ribbon.endX { outerEnd = outerEnd ?? p }
                    }
                    if ribbon.startX == layout.middleSegment.minX {
                        XCTAssertEqual(start!.y - (ribbon.startCenterY - ribbon.startHeight / 2),
                                       min(layout.outerCornerRadius, ribbon.startHeight / 2), accuracy: 0.0001)
                    }
                    if ribbon.endX == layout.middleSegment.maxX {
                        XCTAssertEqual(outerEnd!.y - (ribbon.endCenterY - ribbon.endHeight / 2),
                                       min(layout.outerCornerRadius, ribbon.endHeight / 2), accuracy: 0.0001)
                    }
                }
            }
        }
    }

    func testScaledShortAndThinBusContoursRemainFiniteSimpleAndTangentContinuous() throws {
        for (xScale, yScale): (CGFloat, CGFloat) in [(0.001, 1), (1, 0.001), (0.01, 0.01), (0.0001, 0.001)] {
            var layout = PowerFlowDiagramLayout.resolve(width: 384, preferredMode: .expanded(.manyToMany),
                sourceCount: 2, sinkCount: 2, sourceWatts: [95, 5], sinkWatts: [5, 95])
            func frame(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX * xScale, y: r.minY * yScale, width: r.width * xScale, height: r.height * yScale)
            }
            layout.middleSegment = frame(layout.middleSegment)
            layout.cardFrame = frame(layout.cardFrame)
            layout.busFrame = frame(try XCTUnwrap(layout.busFrame))
            layout.ribbons = layout.ribbons.map {
                let bus = layout.busFrame!
                let startX: CGFloat, endX: CGFloat
                switch $0.role {
                case .source: startX = layout.middleSegment.minX; endX = bus.minX
                case .sink: startX = bus.maxX; endX = layout.middleSegment.maxX
                case .bus: startX = bus.minX; endX = bus.maxX
                case .direct: startX = layout.middleSegment.minX; endX = layout.middleSegment.maxX
                }
                return PowerFlowRibbonGeometry(role: $0.role, startX: startX, endX: endX,
                    startCenterY: $0.startCenterY * yScale, endCenterY: $0.endCenterY * yScale,
                    startHeight: $0.startHeight * yScale, endHeight: $0.endHeight * yScale)
            }
            // Oversized external request deliberately exercises existing guards.
            layout.outerCornerRadius = 1000
            let path = PowerFlowDiagramSurfaceShape(layout: layout, part: .channel).path(in: .zero)
            let contour = try XCTUnwrap(SmoothPathProbe(path).contours.first)
            XCTAssertFalse(contour.hasStationaryCurveEndpoint, "no zero-length derivative at a closed tip")
            XCTAssertLessThan(contour.maximumJoinAngle, 0.001, "scaled \(xScale),\(yScale): \(contour.segments.map(\.controls))")
            XCTAssertFalse(contour.selfIntersects, "scaled \(xScale),\(yScale)")
            XCTAssertTrue(contour.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            XCTAssertTrue(layout.middleSegment.insetBy(dx: -0.00001, dy: -0.00001).contains(path.cgPath.boundingBoxOfPath))
            let bus = try XCTUnwrap(layout.busFrame)
            XCTAssertTrue(path.cgPath.contains(CGPoint(x: bus.midX, y: bus.midY)))
        }
    }

    func testBusChannelIsOneSmoothClosedContourWithRoundedNegativeSpaceAndSolidJoins() throws {
        for width: CGFloat in [320, 384] {
            for pair in [[50.0, 50], [95, 5], [31.5, 10.55], [0.001, 99.999]] {
                for footer in [false, true] {
                    let layout = PowerFlowDiagramLayout.resolve(width: width, preferredMode: .expanded(.manyToMany),
                        sourceCount: 2, sinkCount: 2, reservesTotalsFooter: footer,
                        sourceWatts: pair, sinkWatts: pair.reversed())
                    let path = PowerFlowDiagramSurfaceShape(layout: layout, part: .channel).path(in: .zero)
                    let probe = SmoothPathProbe(path)
                    XCTAssertEqual(probe.contours.count, footer ? 2 : 1, "no separately stroked internal edges")
                    let channel = try XCTUnwrap(probe.contours.first)
                    XCTAssertFalse(channel.hasStationaryCurveEndpoint, "fillet and thin closed cap need nonzero derivatives")
                    XCTAssertLessThan(channel.maximumJoinAngle, 0.001, "G1 joins including closed thin cap and notch")
                    XCTAssertLessThan(channel.maximumFlattenedTurn, 0.35, "finite adaptive contour reveals cusp")
                    XCTAssertFalse(channel.selfIntersects)
                    XCTAssertTrue(channel.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                    XCTAssertTrue(layout.middleSegment.insetBy(dx: -0.001, dy: -0.001).contains(path.cgPath.boundingBoxOfPath))
                    let bus = try XCTUnwrap(layout.busFrame)
                    for x in [bus.minX - 0.01, bus.minX, bus.midX, bus.maxX, bus.maxX + 0.01] {
                        for y in stride(from: bus.minY + 0.1, through: bus.maxY - 0.1, by: 0.5) {
                            XCTAssertTrue(path.cgPath.contains(CGPoint(x: x, y: y)), "hidden join must remain solid")
                        }
                    }
                    // Both notches remain open to the backdrop, but close BEFORE
                    // the packed end. A tiny sample at the old cusp must be fill.
                    let sources = layout.ribbons.filter { if case .source = $0.role { return true }; return false }
                    let sinks = layout.ribbons.filter { if case .sink = $0.role { return true }; return false }
                    for (bands, left) in [(sources, true), (sinks, false)] {
                        let y = left ? bands[0].endCenterY + bands[0].endHeight / 2
                            : bands[0].startCenterY + bands[0].startHeight / 2
                        let joinX = left ? bus.minX : bus.maxX
                        XCTAssertTrue(path.cgPath.contains(CGPoint(x: joinX + (left ? -1 : 1), y: y)))
                        let x = left ? bands[0].startX + 25 : bands[0].endX - 25
                        let gapY = (bands[0].centerY(atX: x) + bands[0].startHeight / 2
                                    + bands[1].centerY(atX: x) - bands[1].startHeight / 2) / 2
                        XCTAssertFalse(path.cgPath.contains(CGPoint(x: x, y: gapY)), "notch must not become a hole or disappear")
                    }
                }
            }
        }
    }
}
