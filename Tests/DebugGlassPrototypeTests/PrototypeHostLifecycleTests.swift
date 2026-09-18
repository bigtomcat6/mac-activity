import AppKit
import SwiftUI
import XCTest
@testable import DebugGlassPrototype

@available(macOS 26.0, *)
@MainActor
final class PrototypeHostLifecycleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testPopoverHostInstallsObserverOnShowAndRemovesItOnClose() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        Self.retainedWindows.append(window)
        let anchorView = NSView(frame: NSRect(x: 20, y: 30, width: 24, height: 24))
        window.contentView = anchorView
        window.orderFront(nil)

        let host = PrototypePopoverHost()
        host.show(content: Text("host test").frame(width: 200, height: 80), anchorView: anchorView)

        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 1)

        host.close()
        drainRunLoop()

        XCTAssertFalse(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 0)

        host.show(content: Text("host test again").frame(width: 200, height: 80), anchorView: anchorView)
        XCTAssertEqual(host.activeMonitorCount, 1)
        host.close()
        drainRunLoop()
        XCTAssertEqual(host.activeMonitorCount, 0)
        XCTAssertFalse(host.isVisible)
    }

    private func drainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    func testPanelHostCleansUpWhenPanelClosedDirectly() throws {
        let host = PrototypePanelHost()
        var closeCount = 0
        host.onClose = { closeCount += 1 }
        let anchorRect = NSRect(x: 900, y: 1050, width: 24, height: 24)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)

        host.show(
            content: Text("panel direct close").frame(width: 200, height: 80),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame
        )
        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 6)

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
        let host = PrototypePanelHost()
        var closeCount = 0
        host.onClose = { closeCount += 1 }
        let anchorRect = NSRect(x: 900, y: 1050, width: 24, height: 24)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)

        host.show(
            content: Text("first panel").frame(width: 200, height: 80),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame
        )
        let firstPanel = try XCTUnwrap(host.panel)
        firstPanel.close()
        drainRunLoop()

        host.show(
            content: Text("second panel").frame(width: 200, height: 80),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame
        )
        XCTAssertTrue(host.isVisible)
        let secondPanel = try XCTUnwrap(host.panel)
        XCTAssertFalse(secondPanel === firstPanel)
        XCTAssertEqual(host.activeMonitorCount, 6)
        XCTAssertEqual(closeCount, 1)

        host.close()
        drainRunLoop()
        XCTAssertFalse(host.isVisible)
        XCTAssertNil(host.panel)
        XCTAssertEqual(host.activeMonitorCount, 0)
        XCTAssertEqual(closeCount, 2)
    }

    func testStalePanelWillCloseHandlerDoesNotAffectReopenedSession() throws {
        let recorder = PrototypeRecordingBag()
        let host = PrototypePanelHost(makeMonitorBag: { recorder.makeBag() })
        var closeCount = 0
        host.onClose = { closeCount += 1 }
        let anchorRect = NSRect(x: 900, y: 1050, width: 24, height: 24)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)

        host.show(
            content: Text("first panel").frame(width: 200, height: 80),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame
        )
        let staleHandler = try XCTUnwrap(recorder.firstObserver(NSWindow.willCloseNotification))
        let firstPanel = try XCTUnwrap(host.panel)
        host.close()
        drainRunLoop()

        host.show(
            content: Text("second panel").frame(width: 200, height: 80),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame
        )
        let secondPanel = try XCTUnwrap(host.panel)
        XCTAssertEqual(closeCount, 1)

        staleHandler(Notification(name: NSWindow.willCloseNotification, object: firstPanel))
        drainRunLoop()

        XCTAssertEqual(closeCount, 1)
        XCTAssertTrue(host.panel === secondPanel)
        XCTAssertTrue(host.isVisible)
        XCTAssertEqual(host.activeMonitorCount, 6)

        host.close()
        drainRunLoop()
        XCTAssertFalse(host.isVisible)
        XCTAssertEqual(closeCount, 2)
    }

    func testCoordinatorClearsStateWhenPanelClosedDirectly() throws {
        let coordinator = PrototypeHostCoordinator(
            contextProvider: {
                PrototypeHostCoordinator.Context(
                    anchorView: nil,
                    anchorRect: NSRect(x: 900, y: 1050, width: 24, height: 24),
                    visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                    resolution: PrototypePolicy.resolve(
                        mode: .transparentPanel,
                        reduceTransparency: false,
                        increaseContrast: false
                    )
                )
            },
            quit: {}
        )
        coordinator.setMode(.transparentPanel)
        coordinator.show()
        XCTAssertTrue(coordinator.isVisible)
        XCTAssertEqual(coordinator.activeMonitorCount, 6)

        let panel = try XCTUnwrap(coordinator.currentPanel)
        panel.close()
        drainRunLoop()

        XCTAssertFalse(coordinator.isVisible)
        XCTAssertNil(coordinator.currentPanel)
        XCTAssertEqual(coordinator.activeMonitorCount, 0)

        coordinator.toggle()
        XCTAssertTrue(coordinator.isVisible)
        XCTAssertNotNil(coordinator.currentPanel)
        XCTAssertEqual(coordinator.activeMonitorCount, 6)

        coordinator.close()
        drainRunLoop()
        XCTAssertFalse(coordinator.isVisible)
        XCTAssertEqual(coordinator.activeMonitorCount, 0)
    }

    func testPanelHostTracksMonitorsAndClearsPanelOnClose() {
        let host = PrototypePanelHost()
        let anchorRect = NSRect(x: 900, y: 1050, width: 24, height: 24)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)

        host.show(
            content: Text("panel test").frame(width: 200, height: 80),
            anchorRect: anchorRect,
            visibleFrame: visibleFrame
        )

        XCTAssertTrue(host.isVisible)
        XCTAssertNotNil(host.panel)
        XCTAssertEqual(host.activeMonitorCount, 6)
        XCTAssertTrue(visibleFrame.contains(host.panel?.frame ?? .zero))

        host.close()

        XCTAssertFalse(host.isVisible)
        XCTAssertNil(host.panel)
        XCTAssertEqual(host.activeMonitorCount, 0)
    }

    func testCoordinatorResolvesTransparentRequestToPopoverUnderReduceTransparencyAndReverses() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        Self.retainedWindows.append(window)
        let anchorView = NSView(frame: NSRect(x: 20, y: 30, width: 24, height: 24))
        window.contentView = anchorView
        window.orderFront(nil)

        var reduceTransparency = true
        let coordinator = PrototypeHostCoordinator(
            contextProvider: {
                PrototypeHostCoordinator.Context(
                    anchorView: anchorView,
                    anchorRect: NSRect(x: 900, y: 1050, width: 24, height: 24),
                    visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                    resolution: PrototypePolicy.resolve(
                        mode: .transparentPanel,
                        reduceTransparency: reduceTransparency,
                        increaseContrast: false
                    )
                )
            },
            quit: {}
        )
        coordinator.setMode(.transparentPanel)
        coordinator.show()

        XCTAssertEqual(coordinator.mode, .transparentPanel)
        XCTAssertEqual(coordinator.effectiveHost, .popover)
        XCTAssertTrue(coordinator.popoverIsShown)
        XCTAssertNil(coordinator.currentPanel)
        XCTAssertEqual(coordinator.activeMonitorCount, 1)

        reduceTransparency = false
        coordinator.refresh()
        drainRunLoop()

        XCTAssertEqual(coordinator.mode, .transparentPanel)
        XCTAssertEqual(coordinator.effectiveHost, .panel)
        XCTAssertNotNil(coordinator.currentPanel)
        XCTAssertFalse(coordinator.popoverIsShown)
        XCTAssertEqual(coordinator.activeMonitorCount, 6)

        coordinator.close()
        drainRunLoop()
        XCTAssertFalse(coordinator.isVisible)
        XCTAssertEqual(coordinator.activeMonitorCount, 0)
    }

    private static var retainedWindows: [NSWindow] = []
}
