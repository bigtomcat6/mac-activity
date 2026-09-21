import AppKit
import SwiftUI
import XCTest
@testable import MacActivityApp

@MainActor
final class DashboardPanelHostTests: XCTestCase {
    private let anchorRect = NSRect(x: 900, y: 1050, width: 24, height: 24)
    private let visibleFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
    private static var retainedWindows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func makeShownHost(
        makeMonitorBag: @escaping () -> DashboardEventMonitorBag = { .live() }
    ) -> DashboardPanelHost {
        let host = DashboardPanelHost(makeMonitorBag: makeMonitorBag)
        host.show(
            contentViewController: NSHostingController(rootView: Text("panel host test")),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: NSSize(width: 420, height: 320)
        )
        return host
    }

    private func drainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    func testPanelHostTracksMonitorsAndClearsPanelOnClose() {
        let host = makeShownHost()

        XCTAssertTrue(host.isVisible)
        XCTAssertNotNil(host.panel)
        XCTAssertEqual(host.activeMonitorCount, 6)
        XCTAssertTrue(visibleFrame.contains(host.panel?.frame ?? .zero))

        host.close()

        XCTAssertFalse(host.isVisible)
        XCTAssertNotNil(host.panel, "hidden panel is kept attached so SwiftUI visibility updates reach the shared root")
        XCTAssertEqual(host.activeMonitorCount, 0)

        host.destroy()
        XCTAssertNil(host.panel)
    }

    func testHiddenPanelIsReusedWithSameContentViewControllerOnReopen() throws {
        let host = DashboardPanelHost()
        let contentViewController = NSHostingController(rootView: Text("reused panel"))
        let show = {
            host.show(
                contentViewController: contentViewController,
                anchorRect: self.anchorRect,
                visibleFrame: self.visibleFrame,
                contentSize: NSSize(width: 420, height: 320)
            )
        }

        show()
        let firstPanel = try XCTUnwrap(host.panel)
        host.close()
        XCTAssertFalse(host.isVisible)

        show()

        let secondPanel = try XCTUnwrap(host.panel)
        XCTAssertTrue(secondPanel === firstPanel)
        XCTAssertTrue(secondPanel.contentViewController === contentViewController)
        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 6)

        host.destroy()
        XCTAssertNil(host.panel)
    }

    func testDestroyDetachesContentViewControllerAndClosesWindow() throws {
        let host = DashboardPanelHost()
        let contentViewController = NSHostingController(rootView: Text("destroyed panel"))
        host.show(
            contentViewController: contentViewController,
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: NSSize(width: 420, height: 320)
        )
        let panel = try XCTUnwrap(host.panel)

        host.destroy()

        XCTAssertNil(host.panel)
        XCTAssertNil(panel.contentViewController)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 0)
    }

    func testPanelHostCleansUpWhenPanelClosedDirectly() throws {
        let host = makeShownHost()
        var closeCount = 0
        host.onClose = { closeCount += 1 }

        let panel = try XCTUnwrap(host.panel)
        panel.close()
        drainRunLoop()

        XCTAssertNil(host.panel)
        XCTAssertFalse(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 0)
        XCTAssertEqual(closeCount, 1)

        host.close()
        XCTAssertEqual(closeCount, 1)
    }

    func testPanelHostReopensAfterDirectPanelClose() throws {
        let host = makeShownHost()
        var closeCount = 0
        host.onClose = { closeCount += 1 }
        let firstPanel = try XCTUnwrap(host.panel)
        firstPanel.close()
        drainRunLoop()

        host.show(
            contentViewController: NSHostingController(rootView: Text("second panel")),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: NSSize(width: 420, height: 320)
        )

        XCTAssertTrue(host.isVisible)
        let secondPanel = try XCTUnwrap(host.panel)
        XCTAssertFalse(secondPanel === firstPanel)
        XCTAssertEqual(host.activeMonitorCount, 6)
        XCTAssertEqual(closeCount, 1)

        host.close()
        drainRunLoop()
        XCTAssertFalse(host.isVisible)
        XCTAssertNotNil(host.panel, "close hides and keeps the panel for reuse")
        XCTAssertEqual(host.activeMonitorCount, 0)
        XCTAssertEqual(closeCount, 2)

        host.destroy()
        XCTAssertNil(host.panel)
    }

    func testRepeatedShowRemovesPreviousMonitorBagBeforeInstallingNew() throws {
        let recorder = DashboardRecordingMonitorBag()
        let host = DashboardPanelHost(makeMonitorBag: { recorder.makeBag() })
        defer { host.destroy() }
        let contentViewController = NSHostingController(rootView: Text("repeated show"))
        let show = {
            host.show(
                contentViewController: contentViewController,
                anchorRect: self.anchorRect,
                visibleFrame: self.visibleFrame,
                contentSize: NSSize(width: 420, height: 320)
            )
        }

        show()
        XCTAssertEqual(host.activeMonitorCount, 6)

        show()

        XCTAssertEqual(host.activeMonitorCount, 6)
        XCTAssertEqual(
            recorder.removedMonitorCount,
            3,
            "a repeated public show must remove the previous monitor bag instead of leaking its event monitors"
        )
    }

    func testStalePanelWillCloseHandlerDoesNotAffectReopenedSession() throws {
        let recorder = DashboardRecordingMonitorBag()
        let host = DashboardPanelHost(makeMonitorBag: { recorder.makeBag() })
        var closeCount = 0
        host.onClose = { closeCount += 1 }

        host.show(
            contentViewController: NSHostingController(rootView: Text("first panel")),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: NSSize(width: 420, height: 320)
        )
        let staleHandler = try XCTUnwrap(recorder.firstObserver(NSWindow.willCloseNotification))
        let firstPanel = try XCTUnwrap(host.panel)
        host.close()
        drainRunLoop()

        host.show(
            contentViewController: NSHostingController(rootView: Text("second panel")),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: NSSize(width: 420, height: 320)
        )
        let secondPanel = try XCTUnwrap(host.panel)

        staleHandler(Notification(name: NSWindow.willCloseNotification, object: firstPanel))
        drainRunLoop()

        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(host.panel === secondPanel)
        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 6)

        host.close()
        drainRunLoop()
        XCTAssertEqual(closeCount, 2)

        host.destroy()
    }

    func testResizeContentKeepsTopAnchorAndClampsToVisibleFrame() throws {
        let host = makeShownHost()
        defer { host.close() }
        let panel = try XCTUnwrap(host.panel)
        let topEdge = panel.frame.maxY

        host.resizeContent(to: NSSize(width: 420, height: 480))

        XCTAssertEqual(panel.frame.maxY, topEdge, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, 480, accuracy: 0.5)
        XCTAssertTrue(visibleFrame.contains(panel.frame))

        host.resizeContent(to: NSSize(width: 420, height: visibleFrame.height))

        XCTAssertEqual(panel.frame.height, visibleFrame.height - DashboardPanelPlacement.defaultEdgeMargin * 2, accuracy: 0.5)
        XCTAssertTrue(visibleFrame.contains(panel.frame))
    }

    func testMenuTrackingSuppressesDismissalUntilTrackingEnds() throws {
        let recorder = DashboardRecordingMonitorBag()
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

    func testContentSizeReportsAttachedPanelFrameAndNilBeforeShow() throws {
        let host = DashboardPanelHost()
        XCTAssertNil(host.contentSize)

        host.show(
            contentViewController: NSHostingController(rootView: Text("content size")),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: NSSize(width: 420, height: 320)
        )
        defer { host.destroy() }

        let contentSize = try XCTUnwrap(host.contentSize)
        XCTAssertEqual(contentSize.width, 420, accuracy: 0.5)
        XCTAssertEqual(contentSize.height, 320, accuracy: 0.5)
    }

    func testGlobalMouseClickClosesShownPanel() throws {
        let recorder = DashboardRecordingMonitorBag()
        let host = makeShownHost(makeMonitorBag: { recorder.makeBag() })
        defer { host.destroy() }
        let globalHandler = try XCTUnwrap(recorder.globalHandler(for: .leftMouseDown))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))

        globalHandler(event)
        drainRunLoop()

        XCTAssertNotNil(host.panel, "global dismissal hides the panel; it is kept attached for reuse")
        XCTAssertFalse(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 0)
    }

    func testLocalMouseClickInsidePanelWindowKeepsPanelVisible() throws {
        let recorder = DashboardRecordingMonitorBag()
        let host = makeShownHost(makeMonitorBag: { recorder.makeBag() })
        defer { host.destroy() }
        let mouseHandler = try XCTUnwrap(recorder.localHandler(for: .leftMouseDown))
        let panel = try XCTUnwrap(host.panel)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: panel.frame.midX, y: panel.frame.midY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))
        XCTAssertTrue(event.window === panel)

        let returned = mouseHandler(event)
        drainRunLoop()

        XCTAssertTrue(returned === event)
        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 6)
    }

    func testExternalLocalMouseClickReturnsOriginalEventAndCloses() throws {
        let recorder = DashboardRecordingMonitorBag()
        let host = makeShownHost(makeMonitorBag: { recorder.makeBag() })
        let mouseHandler = try XCTUnwrap(recorder.localHandler(for: .leftMouseDown))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ))

        let returned = mouseHandler(event)

        XCTAssertTrue(returned === event)
        drainRunLoop()
        XCTAssertNotNil(host.panel, "dismissal hides the panel; it is kept attached for reuse")
        XCTAssertFalse(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 0)
    }

    func testMenuTrackingLetsMenuHandleEscape() throws {
        let recorder = DashboardRecordingMonitorBag()
        let host = makeShownHost(makeMonitorBag: { recorder.makeBag() })
        defer { host.close() }
        let keyHandler = try XCTUnwrap(recorder.localHandler(for: .keyDown))
        let beginTracking = try XCTUnwrap(recorder.lastObserver(NSMenu.didBeginTrackingNotification))
        let endTracking = try XCTUnwrap(recorder.lastObserver(NSMenu.didEndTrackingNotification))
        let escape = try XCTUnwrap(NSEvent.keyEvent(
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
        ))

        beginTracking(Notification(name: NSMenu.didBeginTrackingNotification))
        XCTAssertTrue(keyHandler(escape) === escape)
        XCTAssertNotNil(host.panel)

        endTracking(Notification(name: NSMenu.didEndTrackingNotification))
        XCTAssertNil(keyHandler(escape))
        drainRunLoop()
        XCTAssertNotNil(host.panel)
        XCTAssertFalse(host.isVisible)
    }

    func testMouseInsidePanelFrameOrAnchorDoesNotDismiss() throws {
        let host = makeShownHost()
        defer { host.close() }
        let panel = try XCTUnwrap(host.panel)

        XCTAssertFalse(host.shouldDismiss(
            forEventWindow: nil,
            mouseLocation: NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        ))
        XCTAssertFalse(host.shouldDismiss(
            forEventWindow: nil,
            mouseLocation: NSPoint(x: anchorRect.midX, y: anchorRect.midY)
        ))
        XCTAssertTrue(host.shouldDismiss(forEventWindow: nil, mouseLocation: NSPoint(x: 5, y: 5)))
    }

    func testEventInsidePanelHierarchyDoesNotDismiss() throws {
        let host = makeShownHost()
        defer { host.close() }
        let panel = try XCTUnwrap(host.panel)

        XCTAssertFalse(host.shouldDismiss(forEventWindow: panel, mouseLocation: NSPoint(x: 5, y: 5)))

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
        XCTAssertFalse(host.shouldDismiss(forEventWindow: child, mouseLocation: NSPoint(x: 5, y: 5)))
    }

    func testMenuTrackingStateIsClearedWithMonitorsOnClose() {
        let host = makeShownHost()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        drainRunLoop()
        XCTAssertFalse(host.shouldDismiss(forEventWindow: nil, mouseLocation: NSPoint(x: 5, y: 5)))

        host.close()
        drainRunLoop()
        XCTAssertEqual(host.activeMonitorCount, 0)
        XCTAssertTrue(host.shouldDismiss(forEventWindow: nil, mouseLocation: NSPoint(x: 5, y: 5)))
    }
}

@MainActor
final class DashboardRecordingMonitorBag {
    private var observers: [(Notification.Name, (Notification) -> Void)] = []
    private var globalHandlers: [(mask: NSEvent.EventTypeMask, handler: (NSEvent) -> Void)] = []
    private var localHandlers: [(mask: NSEvent.EventTypeMask, handler: (NSEvent) -> NSEvent?)] = []
    private(set) var removedMonitorCount = 0

    func makeBag() -> DashboardEventMonitorBag {
        DashboardEventMonitorBag(
            installGlobal: { [weak self] mask, handler in
                self?.globalHandlers.append((mask, handler))
                return NSObject()
            },
            installLocal: { [weak self] mask, handler in
                self?.localHandlers.append((mask, handler))
                return NSObject()
            },
            removeMonitor: { [weak self] _ in
                self?.removedMonitorCount += 1
            },
            installObserver: { [weak self] _, name, _, handler in
                self?.observers.append((name, handler))
                return NSObject()
            }
        )
    }

    func firstObserver(_ name: Notification.Name) -> ((Notification) -> Void)? {
        observers.first { $0.0 == name }?.1
    }

    func lastObserver(_ name: Notification.Name) -> ((Notification) -> Void)? {
        observers.last { $0.0 == name }?.1
    }

    func localHandler(for mask: NSEvent.EventTypeMask) -> ((NSEvent) -> NSEvent?)? {
        localHandlers.first { $0.mask.contains(mask) }?.handler
    }

    func globalHandler(for mask: NSEvent.EventTypeMask) -> ((NSEvent) -> Void)? {
        globalHandlers.first { $0.mask.contains(mask) }?.handler
    }
}
