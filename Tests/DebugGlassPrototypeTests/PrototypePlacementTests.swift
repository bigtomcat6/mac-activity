import XCTest
@testable import DebugGlassPrototype

final class PrototypePlacementTests: XCTestCase {
    private let mainScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let leftScreen = NSRect(x: -1280, y: 0, width: 1280, height: 1024)

    func testScreenIndexPrefersScreenContainingAnchorCenter() {
        let anchor = NSRect(x: -640, y: 1000, width: 24, height: 24)
        XCTAssertEqual(
            PrototypePlacement.screenIndex(containing: anchor, screenFrames: [mainScreen, leftScreen]),
            1
        )
    }

    func testScreenIndexFallsBackToLargestIntersection() {
        let anchor = NSRect(x: -40, y: 500, width: 80, height: 40)
        XCTAssertEqual(
            PrototypePlacement.screenIndex(containing: anchor, screenFrames: [mainScreen, leftScreen]),
            0
        )
    }

    func testScreenIndexReturnsNilWithoutScreens() {
        XCTAssertNil(PrototypePlacement.screenIndex(containing: .zero, screenFrames: []))
    }

    func testPanelFrameCentersUnderAnchorWhenUnclamped() {
        let anchor = NSRect(x: 948, y: 1050, width: 24, height: 24)
        let frame = PrototypePlacement.panelFrame(
            anchorRect: anchor,
            visibleFrame: mainScreen,
            contentSize: NSSize(width: 420, height: 480)
        )
        XCTAssertEqual(frame, NSRect(x: 750, y: 564, width: 420, height: 480))
    }

    func testPanelFrameClampsToRightEdge() {
        let anchor = NSRect(x: 1888, y: 1050, width: 24, height: 24)
        let frame = PrototypePlacement.panelFrame(
            anchorRect: anchor,
            visibleFrame: mainScreen,
            contentSize: NSSize(width: 420, height: 480)
        )
        XCTAssertEqual(frame.maxX, mainScreen.maxX - PrototypePlacement.defaultEdgeMargin)
        XCTAssertEqual(frame.width, 420)
    }

    func testPanelFrameStaysInsideNegativeOriginSecondScreen() {
        let visible = NSRect(x: -1280, y: 0, width: 1280, height: 1024)
        let anchor = NSRect(x: -1270, y: 1000, width: 24, height: 24)
        let frame = PrototypePlacement.panelFrame(
            anchorRect: anchor,
            visibleFrame: visible,
            contentSize: NSSize(width: 420, height: 480)
        )
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + PrototypePlacement.defaultEdgeMargin)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - PrototypePlacement.defaultEdgeMargin)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - PrototypePlacement.defaultEdgeMargin)
    }

    func testPanelFrameClampsAboveBottomEdge() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 300)
        let anchor = NSRect(x: 948, y: 20, width: 24, height: 24)
        let frame = PrototypePlacement.panelFrame(
            anchorRect: anchor,
            visibleFrame: visible,
            contentSize: NSSize(width: 420, height: 480)
        )
        XCTAssertEqual(frame.minY, visible.minY + PrototypePlacement.defaultEdgeMargin)
    }

    func testPanelFrameClampsOversizedContentToVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 500, height: 800)
        let frame = PrototypePlacement.panelFrame(
            anchorRect: NSRect(x: 240, y: 780, width: 24, height: 24),
            visibleFrame: visible,
            contentSize: NSSize(width: 900, height: 2000)
        )
        XCTAssertEqual(frame.width, 500 - PrototypePlacement.defaultEdgeMargin * 2)
        XCTAssertEqual(frame.height, 800 - PrototypePlacement.defaultEdgeMargin * 2)
    }

    func testScreenIndexFallsBackToLargestIntersectionWhenNoScreenContainsCenter() {
        XCTAssertEqual(
            PrototypePlacement.screenIndex(
                containing: NSRect(x: -1500, y: 200, width: 400, height: 200),
                screenFrames: [mainScreen, leftScreen]
            ),
            1
        )
        XCTAssertNil(
            PrototypePlacement.screenIndex(
                containing: NSRect(x: 200, y: 1200, width: 40, height: 40),
                screenFrames: [mainScreen, leftScreen]
            )
        )
    }

    @MainActor
    func testVisibleFrameFallsBackToMainScreenWhenAnchorMatchesNoScreen() {
        let fallback = PrototypePlacement.visibleFrame(for: .zero, screens: [])
        XCTAssertEqual(fallback, (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero)
    }

    @MainActor
    func testVisibleFrameUsesScreenContainingAnchor() throws {
        let screens = NSScreen.screens
        try XCTSkipIf(screens.isEmpty, "a screen is required to resolve the containing visible frame")
        let anchor = NSRect(
            x: screens[0].frame.midX - 5,
            y: screens[0].frame.midY - 5,
            width: 10,
            height: 10
        )

        XCTAssertEqual(
            PrototypePlacement.visibleFrame(for: anchor, screens: screens),
            screens[0].visibleFrame
        )
    }
}
