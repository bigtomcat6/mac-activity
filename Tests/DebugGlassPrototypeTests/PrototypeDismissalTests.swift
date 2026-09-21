import AppKit
import SwiftUI
import XCTest
@testable import DebugGlassPrototype

@available(macOS 26.0, *)
@MainActor
final class PrototypeDismissalTests: XCTestCase {
    private let anchorRect = NSRect(x: 900, y: 1050, width: 24, height: 24)
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private static var retainedWindows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func makeShownHost(
        makeMonitorBag: @escaping () -> PrototypeMonitorBag = { PrototypeMonitorBag.live() }
    ) -> PrototypePanelHost {
        let host = PrototypePanelHost(makeMonitorBag: makeMonitorBag)
        host.show(
            content: Text("dismissal test").frame(width: 200, height: 80),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame
        )
        return host
    }

    private func drainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    private func mouseEvent(windowNumber: Int, location: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0
            )
        )
    }

    private func escapeEvent() throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
    }

    func testEventInsidePanelHierarchyDoesNotDismiss() throws {
        let host = makeShownHost()
        defer { host.close() }
        let panel = try XCTUnwrap(host.panel)
        let outside = NSPoint(x: 5, y: 5)

        XCTAssertFalse(host.shouldDismiss(forEventWindow: panel, mouseLocation: outside))

        let child = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        child.isReleasedWhenClosed = false
        Self.retainedWindows.append(child)
        panel.addChildWindow(child, ordered: .above)
        child.orderFront(nil)

        XCTAssertTrue(child.parent === panel)
        XCTAssertFalse(host.shouldDismiss(forEventWindow: child, mouseLocation: outside))
    }

    func testUnrelatedEventWindowOutsidePanelDismisses() {
        let host = makeShownHost()
        defer { host.close() }
        let unrelated = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        unrelated.isReleasedWhenClosed = false
        Self.retainedWindows.append(unrelated)

        XCTAssertTrue(host.shouldDismiss(forEventWindow: unrelated, mouseLocation: NSPoint(x: 5, y: 5)))
    }

    func testMouseInsidePanelFrameOrAnchorDoesNotDismiss() throws {
        let host = makeShownHost()
        defer { host.close() }
        let panel = try XCTUnwrap(host.panel)

        XCTAssertFalse(
            host.shouldDismiss(
                forEventWindow: nil,
                mouseLocation: NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            )
        )
        XCTAssertFalse(
            host.shouldDismiss(
                forEventWindow: nil,
                mouseLocation: NSPoint(x: anchorRect.midX, y: anchorRect.midY)
            )
        )
        XCTAssertTrue(host.shouldDismiss(forEventWindow: nil, mouseLocation: NSPoint(x: 5, y: 5)))
    }

    func testMenuTrackingSuppressesDismissalUntilTrackingEnds() throws {
        let recorder = PrototypeRecordingBag()
        let host = makeShownHost(makeMonitorBag: { recorder.makeBag() })
        defer { host.close() }
        let beginTracking = try XCTUnwrap(recorder.lastObserver(NSMenu.didBeginTrackingNotification))
        let endTracking = try XCTUnwrap(recorder.lastObserver(NSMenu.didEndTrackingNotification))
        let outside = NSPoint(x: 5, y: 5)

        beginTracking(Notification(name: NSMenu.didBeginTrackingNotification))
        XCTAssertFalse(host.shouldDismiss(forEventWindow: nil, mouseLocation: outside))

        endTracking(Notification(name: NSMenu.didEndTrackingNotification))
        XCTAssertTrue(host.shouldDismiss(forEventWindow: nil, mouseLocation: outside))
    }

    func testMenuTrackingLetsMenuHandleEscape() throws {
        let recorder = PrototypeRecordingBag()
        let host = makeShownHost(makeMonitorBag: { recorder.makeBag() })
        defer { host.close() }
        let keyHandler = try XCTUnwrap(recorder.localHandler(for: .keyDown))
        let beginTracking = try XCTUnwrap(recorder.lastObserver(NSMenu.didBeginTrackingNotification))
        let endTracking = try XCTUnwrap(recorder.lastObserver(NSMenu.didEndTrackingNotification))
        let escape = try escapeEvent()

        beginTracking(Notification(name: NSMenu.didBeginTrackingNotification))
        let returnedDuringTracking = keyHandler(escape)
        XCTAssertTrue(returnedDuringTracking === escape)
        XCTAssertNotNil(host.panel)

        endTracking(Notification(name: NSMenu.didEndTrackingNotification))
        let returnedAfterTracking = keyHandler(escape)
        XCTAssertNil(returnedAfterTracking)
        drainRunLoop()
        XCTAssertNil(host.panel)
        XCTAssertFalse(host.isVisible)
    }

    func testExternalLocalMouseClickReturnsOriginalEventAndCloses() throws {
        let recorder = PrototypeRecordingBag()
        let host = makeShownHost(makeMonitorBag: { recorder.makeBag() })
        let mouseHandler = try XCTUnwrap(recorder.localHandler(for: .leftMouseDown))
        let event = try mouseEvent(windowNumber: 0, location: NSPoint(x: 5, y: 5))

        let returned = mouseHandler(event)

        XCTAssertTrue(returned === event)
        drainRunLoop()
        XCTAssertNil(host.panel)
        XCTAssertFalse(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 0)
    }

    func testLocalMouseClickInsidePanelHierarchyDoesNotClose() throws {
        let recorder = PrototypeRecordingBag()
        let host = makeShownHost(makeMonitorBag: { recorder.makeBag() })
        defer { host.close() }
        let mouseHandler = try XCTUnwrap(recorder.localHandler(for: .leftMouseDown))
        let panel = try XCTUnwrap(host.panel)
        let panelEvent = try mouseEvent(
            windowNumber: panel.windowNumber,
            location: NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        )
        XCTAssertTrue(panelEvent.window === panel)

        let returned = mouseHandler(panelEvent)

        XCTAssertTrue(returned === panelEvent)
        XCTAssertNotNil(host.panel)
        XCTAssertTrue(host.isVisible)
    }

    func testMenuTrackingStateIsClearedWithMonitorsOnClose() {
        let host = makeShownHost()
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        drainRunLoop()
        XCTAssertFalse(host.shouldDismiss(forEventWindow: nil, mouseLocation: NSPoint(x: 5, y: 5)))

        host.close()
        drainRunLoop()
        XCTAssertEqual(host.activeMonitorCount, 0)

        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        drainRunLoop()
        XCTAssertTrue(host.shouldDismiss(forEventWindow: nil, mouseLocation: NSPoint(x: 5, y: 5)))
    }
}
