import Combine
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardPresentationPolicyTests: XCTestCase {
    private let standardEnvironment = DashboardPresentationAccessibilityEnvironment(
        reduceTransparency: false,
        increaseContrast: false,
        majorVersion: 26
    )

    func testTransparentSupportBoundary() {
        XCTAssertFalse(DashboardPresentationPolicy.isSupported(majorVersion: 13))
        XCTAssertFalse(DashboardPresentationPolicy.isSupported(majorVersion: 15))
        XCTAssertFalse(DashboardPresentationPolicy.isSupported(majorVersion: 25))
        XCTAssertTrue(DashboardPresentationPolicy.isSupported(majorVersion: 26))
        XCTAssertTrue(DashboardPresentationPolicy.isSupported(majorVersion: 27))
    }

    func testStandardStyleIsUnchangedByAccessibilityOptions() {
        for reduceTransparency in [false, true] {
            for increaseContrast in [false, true] {
                let resolution = DashboardPresentationPolicy.resolve(
                    style: .standard,
                    environment: DashboardPresentationAccessibilityEnvironment(
                        reduceTransparency: reduceTransparency,
                        increaseContrast: increaseContrast,
                        majorVersion: 26
                    )
                )
                XCTAssertEqual(resolution.requestedStyle, .standard)
                XCTAssertEqual(resolution.effectiveStyle, .standard)
                XCTAssertEqual(resolution.hostKind, .popover)
                XCTAssertEqual(resolution.appearance.glassKind, .perCardRegular)
                XCTAssertEqual(resolution.appearance.foregroundStyle, .system)
                XCTAssertEqual(resolution.appearance.moduleFillOpacity, 0)
                XCTAssertEqual(resolution.appearance.moduleCornerRadius, 12)
                XCTAssertFalse(resolution.appearance.usesRootGlass)
                XCTAssertEqual(
                    resolution.appearance.strokeOpacity,
                    increaseContrast
                        ? DashboardPresentationPolicy.increasedContrastStrokeOpacity
                        : DashboardPresentationPolicy.defaultStrokeOpacity
                )
            }
        }
    }

    func testTransparentStyleResolvesToRootGlassPanelWhenSupported() {
        let resolution = DashboardPresentationPolicy.resolve(
            style: .transparent,
            environment: standardEnvironment
        )

        XCTAssertEqual(resolution.requestedStyle, .transparent)
        XCTAssertEqual(resolution.effectiveStyle, .transparent)
        XCTAssertEqual(resolution.hostKind, .panel)
        XCTAssertEqual(resolution.appearance.glassKind, .rootRegular)
        XCTAssertEqual(resolution.appearance.foregroundStyle, .translucent)
        XCTAssertEqual(
            resolution.appearance.moduleFillOpacity,
            DashboardPresentationPolicy.translucentModuleFillOpacity
        )
        XCTAssertEqual(DashboardPresentationPolicy.translucentModuleFillOpacity, 0.08)
        XCTAssertEqual(resolution.appearance.moduleCornerRadius, 16)
        XCTAssertEqual(resolution.appearance.rootGlassCornerRadius, 24)
        XCTAssertEqual(
            resolution.appearance.strokeOpacity,
            DashboardPresentationPolicy.defaultStrokeOpacity
        )
        XCTAssertEqual(DashboardPresentationPolicy.defaultStrokeOpacity, 0.16)
        XCTAssertTrue(resolution.appearance.usesTranslucentChrome)
        XCTAssertTrue(resolution.appearance.usesRootGlass)
    }

    func testIncreaseContrastStrengthensTranslucentFillAndStroke() {
        let base = DashboardPresentationPolicy.resolve(style: .transparent, environment: standardEnvironment)
        let contrast = DashboardPresentationPolicy.resolve(
            style: .transparent,
            environment: DashboardPresentationAccessibilityEnvironment(
                reduceTransparency: false,
                increaseContrast: true,
                majorVersion: 26
            )
        )

        XCTAssertGreaterThan(
            contrast.appearance.moduleFillOpacity,
            base.appearance.moduleFillOpacity
        )
        XCTAssertEqual(
            contrast.appearance.moduleFillOpacity,
            DashboardPresentationPolicy.translucentModuleFillOpacityIncreasedContrast
        )
        XCTAssertEqual(DashboardPresentationPolicy.translucentModuleFillOpacityIncreasedContrast, 0.14)
        XCTAssertEqual(base.appearance.strokeOpacity, DashboardPresentationPolicy.defaultStrokeOpacity)
        XCTAssertEqual(contrast.appearance.strokeOpacity, DashboardPresentationPolicy.increasedContrastStrokeOpacity)
        XCTAssertEqual(DashboardPresentationPolicy.increasedContrastStrokeOpacity, 0.42)
    }

    func testReduceTransparencyAndUnsupportedOSResolveTransparentStyleToStandardPopover() {
        for environment in [
            DashboardPresentationAccessibilityEnvironment(
                reduceTransparency: true,
                increaseContrast: false,
                majorVersion: 26
            ),
            DashboardPresentationAccessibilityEnvironment(
                reduceTransparency: false,
                increaseContrast: false,
                majorVersion: 25
            ),
            DashboardPresentationAccessibilityEnvironment(
                reduceTransparency: true,
                increaseContrast: true,
                majorVersion: 25
            ),
        ] {
            let resolution = DashboardPresentationPolicy.resolve(style: .transparent, environment: environment)
            XCTAssertEqual(resolution.requestedStyle, .transparent)
            XCTAssertEqual(resolution.effectiveStyle, .standard)
            XCTAssertEqual(resolution.hostKind, .popover)
            XCTAssertEqual(
                resolution.appearance,
                DashboardPresentationPolicy.resolve(style: .standard, environment: environment).appearance
            )
        }
    }

    func testPresentationStatePublishesOnlyRealResolutionChanges() {
        let state = DashboardPresentationState(style: .standard, environment: standardEnvironment)
        var published: [DashboardPresentationResolution] = []
        let cancellable = state.$resolution.dropFirst().sink { published.append($0) }
        defer { cancellable.cancel() }

        state.apply(style: .standard, environment: standardEnvironment)
        XCTAssertTrue(published.isEmpty)

        state.apply(style: .transparent, environment: standardEnvironment)
        XCTAssertEqual(published.map(\.hostKind), [.panel])

        state.apply(style: .transparent, environment: standardEnvironment)
        XCTAssertEqual(published.map(\.hostKind), [.panel])
    }

    func testPresentationStateTracksPresentedOnlyOnExplicitSignal() {
        let state = DashboardPresentationState(style: .standard, environment: standardEnvironment)

        XCTAssertFalse(state.isPresented)

        state.setPresented(true)
        XCTAssertTrue(state.isPresented)

        state.setPresented(true)
        XCTAssertTrue(state.isPresented)

        state.setPresented(false)
        XCTAssertFalse(state.isPresented)
    }
}
