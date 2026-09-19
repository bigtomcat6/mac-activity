import AppKit
import XCTest
@testable import DebugGlassPrototype

final class PrototypeAnchorPlausibilityTests: XCTestCase {
    private let mainScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private let leftScreen = NSRect(x: -1280, y: 0, width: 1280, height: 1024)

    func testMenuBarRectOnMainScreenIsPlausible() {
        XCTAssertTrue(
            PrototypeAnchorPlausibility.isPlausibleMenuBarRect(
                NSRect(x: 1860, y: 1052, width: 24, height: 24),
                screenFrames: [mainScreen]
            )
        )
    }

    func testBottomOfScreenRectIsNotPlausible() {
        XCTAssertFalse(
            PrototypeAnchorPlausibility.isPlausibleMenuBarRect(
                NSRect(x: 900, y: 20, width: 24, height: 24),
                screenFrames: [mainScreen]
            )
        )
    }

    func testOffscreenRectIsNotPlausible() {
        XCTAssertFalse(
            PrototypeAnchorPlausibility.isPlausibleMenuBarRect(
                NSRect(x: 3000, y: 1052, width: 24, height: 24),
                screenFrames: [mainScreen]
            )
        )
    }

    func testZeroRectIsNotPlausible() {
        XCTAssertFalse(
            PrototypeAnchorPlausibility.isPlausibleMenuBarRect(.zero, screenFrames: [mainScreen])
        )
    }

    func testEmptyScreensAreNotPlausible() {
        XCTAssertFalse(
            PrototypeAnchorPlausibility.isPlausibleMenuBarRect(
                NSRect(x: 1860, y: 1052, width: 24, height: 24),
                screenFrames: []
            )
        )
    }

    func testPlausibilityWorksOnNegativeOriginScreen() {
        XCTAssertTrue(
            PrototypeAnchorPlausibility.isPlausibleMenuBarRect(
                NSRect(x: -40, y: 1000, width: 24, height: 24),
                screenFrames: [mainScreen, leftScreen]
            )
        )
        XCTAssertFalse(
            PrototypeAnchorPlausibility.isPlausibleMenuBarRect(
                NSRect(x: -40, y: 20, width: 24, height: 24),
                screenFrames: [mainScreen, leftScreen]
            )
        )
    }
}
