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
        XCTAssertFalse(host.isShown)
        XCTAssertNotNil(host.panel, "hidden panel is kept attached so SwiftUI visibility updates reach the shared root")
        XCTAssertEqual(host.activeMonitorCount, 0)
        drainRunLoop()
        XCTAssertFalse(host.isVisible)

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
        XCTAssertFalse(host.isShown)

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

    func testNormalCloseKeepsPhysicalWindowVisibleUntilNativeFadeCompletes() throws {
        let host = makeShownHost()
        defer { host.destroy() }
        let panel = try XCTUnwrap(host.panel)
        host.close()
        XCTAssertTrue(panel.isVisible, "whole-window fade must finish before physical hide")
        XCTAssertEqual(host.activeMonitorCount, 0, "monitor cleanup is immediate, not delayed to hide")
    }

    // Missing fade/intent separation would hide immediately and repeat-close on a reopen.
    func testFadeClosesLogicallyBeforePhysicalHideAndReopenRejectsOldCompletion() throws {
        var completions: [@MainActor () -> Void] = []
        var requests: [(CGFloat, Double)] = []
        let host = DashboardPanelHost(shouldReduceMotion: { false }, animateAlpha: { panel, alpha, duration, completion in
            requests.append((alpha, duration))
            panel.alphaValue = alpha
            completions.append(completion)
        })
        defer { host.destroy() }
        var closes = 0
        host.onClose = { closes += 1 }
        let content = NSHostingController(rootView: Text("fade"))
        var alphaAtPresentation: CGFloat?
        host.presentPanel = { panel in
            alphaAtPresentation = panel.alphaValue
            panel.makeKeyAndOrderFront(nil)
        }
        func show() {
            host.show(contentViewController: content, anchorRect: anchorRect,
                      visibleFrame: visibleFrame, contentSize: NSSize(width: 420, height: 320))
        }
        show()
        let panel = try XCTUnwrap(host.panel)
        XCTAssertEqual(alphaAtPresentation, 0)
        XCTAssertTrue(host.isShown)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(requests.first?.0, 1)
        XCTAssertEqual(requests.first?.1, 0.14)
        XCTAssertEqual(host.activeMonitorCount, 6)
        host.close() // Also exercises show -> close before open completion.
        XCTAssertFalse(host.isShown)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(host.activeMonitorCount, 0)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(requests.last?.0, 0)
        XCTAssertEqual(requests.last?.1, 0.11)
        host.close()
        XCTAssertEqual(completions.count, 2)
        completions[0]()
        XCTAssertTrue(panel.isVisible)
        show()
        XCTAssertTrue(host.panel === panel)
        XCTAssertTrue(panel.contentViewController === content)
        XCTAssertTrue(host.isShown)
        XCTAssertFalse(panel.ignoresMouseEvents)
        completions[1]()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(host.isShown)
        completions[2]()
        XCTAssertEqual(panel.alphaValue, 1)
        host.close()
        completions[3]()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertEqual(closes, 2)
    }

    func testClosingKeyPanelRejectsNativeKeyboardActionsAndReopenRestoresInput() throws {
        var completions: [@MainActor () -> Void] = []
        let host = DashboardPanelHost(shouldReduceMotion: { false }, animateAlpha: { panel, alpha, _, completion in
            panel.alphaValue = alpha
            completions.append(completion)
        })
        defer { host.destroy() }
        let target = DashboardKeyboardActionCounter()
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        let button = NSButton(title: "Audio action", target: target, action: #selector(DashboardKeyboardActionCounter.activate(_:)))
        button.frame = NSRect(x: 10, y: 260, width: 160, height: 32)
        button.keyEquivalent = "k"
        button.keyEquivalentModifierMask = .command
        content.view.addSubview(button)
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 10, width: 380, height: 220))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 1200))
        content.view.addSubview(scroll)
        func show() {
            host.show(contentViewController: content, anchorRect: anchorRect, visibleFrame: visibleFrame,
                      contentSize: NSSize(width: 420, height: 320))
        }
        show()
        let panel = try XCTUnwrap(host.panel)
        completions[0]()
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertTrue(panel.makeFirstResponder(button))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        let offset = scroll.contentView.bounds.origin
        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        let space = try key(" ", code: 49)
        let command = try key("k", code: 40, modifiers: .command)
        panel.sendEvent(space)
        XCTAssertEqual(target.actions, 1, "positive oracle: a real focused NSButton accepts native space dispatch")
        XCTAssertTrue(panel.performKeyEquivalent(with: command))
        XCTAssertEqual(target.actions, 2, "positive oracle: the window's native command route reaches the button")
        host.close()
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow, "close intent must surrender key status without focusing another app")
        panel.sendEvent(space)
        XCTAssertFalse(panel.performKeyEquivalent(with: command))
        XCTAssertEqual(target.actions, 2, "closing Dashboard controls must not send model/audio actions")
        show()
        completions[1]() // Old close must not suppress reopened input or hide the window.
        completions[2]()
        XCTAssertTrue(host.panel === panel)
        XCTAssertTrue(panel.contentViewController === content)
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertTrue(panel.firstResponder === button)
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertEqual(scroll.contentView.bounds.origin, offset)
        panel.sendEvent(space)
        XCTAssertTrue(panel.performKeyEquivalent(with: command))
        XCTAssertEqual(target.actions, 4)
    }

    func testExternalPanelCloseDuringFadeOutInvalidatesPhysicalCompletion() throws {
        var completions: [@MainActor () -> Void] = []
        let host = DashboardPanelHost(shouldReduceMotion: { false }, animateAlpha: { _, _, _, completion in
            completions.append(completion)
        })
        var closes = 0
        var didCloses = 0
        host.onClose = { closes += 1 }
        host.onDidClose = { didCloses += 1 }
        let content = NSHostingController(rootView: Text("direct close"))
        host.show(contentViewController: content, anchorRect: anchorRect, visibleFrame: visibleFrame,
                  contentSize: NSSize(width: 420, height: 320))
        let panel = try XCTUnwrap(host.panel)
        host.close()
        panel.close()
        XCTAssertNil(host.panel)
        XCTAssertFalse(host.isShown)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(didCloses, 1, "external close must finish the pending physical lifecycle once")
        completions.forEach { $0() }
        XCTAssertEqual(didCloses, 1)
        XCTAssertFalse(panel.isVisible)
        host.destroy()
    }

    func testReduceMotionAndAnimatesFalseSnapWithoutRequestingFade() throws {
        for reduceMotion in [false, true] {
            var requests = 0
            let host = DashboardPanelHost(shouldReduceMotion: { reduceMotion }, animateAlpha: { _, _, _, _ in requests += 1 })
            host.animates = reduceMotion
            host.show(contentViewController: NSHostingController(rootView: Text("snap")), anchorRect: anchorRect,
                      visibleFrame: visibleFrame, contentSize: NSSize(width: 420, height: 320))
            let panel = try XCTUnwrap(host.panel)
            XCTAssertTrue(host.isShown)
            XCTAssertEqual(panel.alphaValue, 1)
            host.close()
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(host.isShown)
            XCTAssertEqual(panel.alphaValue, 1)
            XCTAssertEqual(requests, 0)
            host.destroy()
        }
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
private final class DashboardKeyboardActionCounter: NSObject {
    private(set) var actions = 0
    @objc func activate(_ sender: Any?) { actions += 1 }
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
