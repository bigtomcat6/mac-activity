import AppKit
import XCTest
@testable import MacActivityApp

@MainActor
final class DashboardPanelSupportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testPanelUsesPublicTransparentNonactivatingConfiguration() {
        let panel = DashboardPanelFactory.makePanel(
            contentRect: NSRect(x: 100, y: 200, width: 420, height: 480)
        )
        defer { panel.close() }

        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, NSColor.clear)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.level, .popUpMenu)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(panel.identifier?.rawValue, DashboardPanelFactory.identifier)
    }

    func testAnchorResolverConvertsViewBoundsIntoScreenCoordinates() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        Self.retainedWindows.append(window)
        let view = NSView(frame: NSRect(x: 20, y: 30, width: 40, height: 20))
        window.contentView = view

        let expected = window.convertToScreen(view.convert(view.bounds, to: nil))

        XCTAssertEqual(DashboardPanelAnchor.screenRect(for: view), expected)
        XCTAssertNil(DashboardPanelAnchor.screenRect(for: nil))
        XCTAssertNil(DashboardPanelAnchor.screenRect(for: NSView()))
    }

    func testMenuBarPlausibilityFollowsScreenBandAndBounds() {
        let mainScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let leftScreen = NSRect(x: -1280, y: 0, width: 1280, height: 1024)

        XCTAssertTrue(DashboardPanelAnchor.isPlausibleMenuBarRect(
            NSRect(x: 1860, y: 1052, width: 24, height: 24),
            screenFrames: [mainScreen]
        ))
        XCTAssertFalse(DashboardPanelAnchor.isPlausibleMenuBarRect(
            NSRect(x: 900, y: 20, width: 24, height: 24),
            screenFrames: [mainScreen]
        ))
        XCTAssertFalse(DashboardPanelAnchor.isPlausibleMenuBarRect(
            NSRect(x: 3000, y: 1052, width: 24, height: 24),
            screenFrames: [mainScreen]
        ))
        XCTAssertFalse(DashboardPanelAnchor.isPlausibleMenuBarRect(.zero, screenFrames: [mainScreen]))
        XCTAssertFalse(DashboardPanelAnchor.isPlausibleMenuBarRect(
            NSRect(x: 1860, y: 1052, width: 24, height: 24),
            screenFrames: []
        ))
        XCTAssertTrue(DashboardPanelAnchor.isPlausibleMenuBarRect(
            NSRect(x: -40, y: 1000, width: 24, height: 24),
            screenFrames: [mainScreen, leftScreen]
        ))
    }

    func testPanelFramePlacementCentersAndClamps() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let centered = DashboardPanelPlacement.panelFrame(
            anchorRect: NSRect(x: 948, y: 1050, width: 24, height: 24),
            visibleFrame: visible,
            contentSize: NSSize(width: 420, height: 480)
        )
        XCTAssertEqual(centered, NSRect(x: 750, y: 564, width: 420, height: 480))

        let rightClamped = DashboardPanelPlacement.panelFrame(
            anchorRect: NSRect(x: 1888, y: 1050, width: 24, height: 24),
            visibleFrame: visible,
            contentSize: NSSize(width: 420, height: 480)
        )
        XCTAssertEqual(rightClamped.maxX, visible.maxX - DashboardPanelPlacement.defaultEdgeMargin)

        let bottomClamped = DashboardPanelPlacement.panelFrame(
            anchorRect: NSRect(x: 948, y: 20, width: 24, height: 24),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 300),
            contentSize: NSSize(width: 420, height: 480)
        )
        XCTAssertEqual(bottomClamped.minY, DashboardPanelPlacement.defaultEdgeMargin)

        let oversized = DashboardPanelPlacement.panelFrame(
            anchorRect: NSRect(x: 240, y: 780, width: 24, height: 24),
            visibleFrame: NSRect(x: 0, y: 0, width: 500, height: 800),
            contentSize: NSSize(width: 900, height: 2000)
        )
        XCTAssertEqual(oversized.width, 500 - DashboardPanelPlacement.defaultEdgeMargin * 2)
        XCTAssertEqual(oversized.height, 800 - DashboardPanelPlacement.defaultEdgeMargin * 2)
    }

    func testScreenIndexPrefersScreenContainingAnchorCenterAndFallsBackToIntersection() {
        let mainScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let leftScreen = NSRect(x: -1280, y: 0, width: 1280, height: 1024)

        XCTAssertEqual(
            DashboardPanelPlacement.screenIndex(
                containing: NSRect(x: -640, y: 1000, width: 24, height: 24),
                screenFrames: [mainScreen, leftScreen]
            ),
            1
        )
        XCTAssertEqual(
            DashboardPanelPlacement.screenIndex(
                containing: NSRect(x: -40, y: 500, width: 80, height: 40),
                screenFrames: [mainScreen, leftScreen]
            ),
            0
        )
        XCTAssertNil(DashboardPanelPlacement.screenIndex(containing: .zero, screenFrames: []))
    }

    func testPanelFrameStaysInsideNegativeOriginSecondScreen() {
        let visible = NSRect(x: -1280, y: 0, width: 1280, height: 1024)
        let anchor = NSRect(x: -1270, y: 1000, width: 24, height: 24)

        let frame = DashboardPanelPlacement.panelFrame(
            anchorRect: anchor,
            visibleFrame: visible,
            contentSize: NSSize(width: 420, height: 480)
        )

        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX + DashboardPanelPlacement.defaultEdgeMargin)
        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX - DashboardPanelPlacement.defaultEdgeMargin)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY - DashboardPanelPlacement.defaultEdgeMargin)
    }

    func testMenuBarPlausibilityWorksOnNegativeOriginScreen() {
        let mainScreen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let leftScreen = NSRect(x: -1280, y: 0, width: 1280, height: 1024)

        XCTAssertFalse(DashboardPanelAnchor.isPlausibleMenuBarRect(
            NSRect(x: -40, y: 20, width: 24, height: 24),
            screenFrames: [mainScreen, leftScreen]
        ))
        XCTAssertTrue(DashboardPanelAnchor.isPlausibleMenuBarRect(
            NSRect(x: -40, y: 1000, width: 24, height: 24),
            screenFrames: [mainScreen, leftScreen]
        ))
    }

    func testMonitorBagRemovesRegistrationsAndIsIdempotent() {
        let recorder = DashboardMonitorRecorder()
        let bag = Self.makeBag(recorder)
        let center = NotificationCenter()
        let name = Notification.Name("DashboardEventMonitorBagTest")
        var observed = 0

        bag.addGlobal(mask: [.leftMouseDown]) { _ in }
        bag.addLocal(mask: [.keyDown]) { $0 }
        bag.observe(center: center, name: name) { _ in observed += 1 }
        center.post(name: name, object: nil)
        XCTAssertEqual(observed, 1)
        XCTAssertEqual(bag.activeCount, 3)

        bag.removeAll()
        center.post(name: name, object: nil)
        XCTAssertEqual(observed, 1)
        XCTAssertEqual(bag.activeCount, 0)
        XCTAssertEqual(recorder.installed, 3)
        XCTAssertEqual(recorder.removed, 2)

        bag.removeAll()
        XCTAssertEqual(recorder.removed, 2)
    }

    func testMonitorBagIgnoresNilTokens() {
        let recorder = DashboardMonitorRecorder()
        let bag = DashboardEventMonitorBag(
            installGlobal: { _, _ in nil },
            installLocal: { _, _ in nil },
            removeMonitor: { _ in recorder.removed += 1 },
            installObserver: { _, _, _, _ in NSObject() }
        )
        bag.addGlobal(mask: [.leftMouseDown]) { _ in }
        bag.addLocal(mask: [.keyDown]) { $0 }
        XCTAssertEqual(bag.activeCount, 0)
        bag.removeAll()
        XCTAssertEqual(recorder.removed, 0)
    }

    static func makeBag(_ recorder: DashboardMonitorRecorder) -> DashboardEventMonitorBag {
        DashboardEventMonitorBag(
            installGlobal: { _, _ in
                recorder.installed += 1
                return NSObject()
            },
            installLocal: { _, _ in
                recorder.installed += 1
                return NSObject()
            },
            removeMonitor: { _ in recorder.removed += 1 },
            installObserver: { center, name, object, handler in
                recorder.installed += 1
                return center.addObserver(forName: name, object: object, queue: nil, using: handler)
            }
        )
    }

    static var retainedWindows: [NSWindow] = []
}

@MainActor
final class DashboardMonitorRecorder {
    var installed = 0
    var removed = 0
}
