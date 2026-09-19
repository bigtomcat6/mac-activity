import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardStyleAppearanceTests: XCTestCase {
    private var translucentAppearance: DashboardStyleAppearance {
        DashboardPresentationPolicy.translucentAppearance(
            moduleFillOpacity: DashboardPresentationPolicy.translucentModuleFillOpacity,
            strokeOpacity: DashboardPresentationPolicy.defaultStrokeOpacity
        )
    }

    func testTranslucentAppearanceMatchesApprovedCalibration() {
        let appearance = translucentAppearance

        XCTAssertEqual(appearance.glassKind, .rootRegular)
        XCTAssertEqual(appearance.foregroundStyle, .translucent)
        XCTAssertEqual(appearance.moduleFillOpacity, 0.08)
        XCTAssertEqual(appearance.strokeOpacity, 0.16)
        XCTAssertEqual(appearance.moduleCornerRadius, 16)
        XCTAssertEqual(appearance.rootGlassCornerRadius, 24)
        XCTAssertTrue(appearance.usesTranslucentChrome)
        XCTAssertTrue(appearance.usesRootGlass)
    }

    func testEnvironmentDefaultIsStandardAppearance() {
        var values = EnvironmentValues()
        XCTAssertEqual(values.dashboardStyleAppearance, DashboardPresentationPolicy.standardAppearance)
        XCTAssertEqual(values.dashboardStyleAppearance.glassKind, .perCardRegular)
        XCTAssertEqual(values.dashboardStyleAppearance.foregroundStyle, .system)
        XCTAssertEqual(values.dashboardStyleAppearance.moduleFillOpacity, 0)
        XCTAssertEqual(values.dashboardStyleAppearance.strokeOpacity, 0.16)
        XCTAssertEqual(values.dashboardStyleAppearance.moduleCornerRadius, 12)
        XCTAssertFalse(values.dashboardStyleAppearance.usesTranslucentChrome)
        XCTAssertFalse(values.dashboardStyleAppearance.usesRootGlass)
    }

    func testPresentationVisibilityEnvironmentDefaultsToTrue() {
        let values = EnvironmentValues()

        XCTAssertTrue(values.dashboardPresentationIsPresented)
    }

    func testTranslucentModuleFillKeepsAdaptivePrimaryInsteadOfForcedWhite() throws {
        let fillOpacity = DashboardPresentationPolicy.translucentModuleFillOpacity
        let lightFill = try XCTUnwrap(Self.renderedColor(
            of: Rectangle()
                .fill(Color.primary.opacity(fillOpacity))
                .frame(width: 20, height: 20)
                .environment(\.colorScheme, .light),
            atTopLeft: CGPoint(x: 10, y: 10)
        ))
        let darkFill = try XCTUnwrap(Self.renderedColor(
            of: Rectangle()
                .fill(Color.primary.opacity(fillOpacity))
                .frame(width: 20, height: 20)
                .environment(\.colorScheme, .dark),
            atTopLeft: CGPoint(x: 10, y: 10)
        ))

        XCTAssertLessThan(lightFill.redComponent, 0.3)
        XCTAssertGreaterThan(darkFill.redComponent, 0.5)
        XCTAssertGreaterThan(lightFill.alphaComponent, 0.01)
        XCTAssertGreaterThan(darkFill.alphaComponent, 0.01)
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

        let pixelX = Int(point.x.rounded(.down))
        let sourceY = Int(point.y.rounded(.down))
        let pixelY = bitmap.pixelsHigh - sourceY - 1

        guard (0..<bitmap.pixelsWide).contains(pixelX),
              (0..<bitmap.pixelsHigh).contains(pixelY)
        else {
            return nil
        }

        return bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
    }
}
