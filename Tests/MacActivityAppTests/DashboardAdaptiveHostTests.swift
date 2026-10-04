import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardAdaptiveHostTests: XCTestCase {
    private static var retainedWindows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func makeAnchorView() throws -> NSView {
        let screen = try XCTUnwrap(
            NSScreen.main ?? NSScreen.screens.first,
            "a screen is required to place the menu bar anchor fixture"
        )
        let windowSize = NSSize(width: 300, height: 40)
        let viewFrame = NSRect(x: 20, y: 8, width: 24, height: 24)
        let bandBottom = screen.frame.maxY - DashboardPanelAnchor.menuBarBandHeight
        let desiredWindowRect = NSRect(
            x: screen.frame.minX + 120 - viewFrame.minX,
            y: bandBottom + 16 - viewFrame.minY,
            width: windowSize.width,
            height: windowSize.height
        )
        let windowRect = NSRect(
            x: desiredWindowRect.minX,
            y: min(desiredWindowRect.minY, screen.visibleFrame.maxY - windowSize.height),
            width: desiredWindowRect.width,
            height: desiredWindowRect.height
        )
        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrame(windowRect, display: false)
        Self.retainedWindows.append(window)
        let view = NSView(frame: viewFrame)
        window.contentView?.addSubview(view)
        window.orderFront(nil)
        let anchorRect = try XCTUnwrap(
            DashboardPanelAnchor.screenRect(for: view),
            "the anchor fixture view must be attached to the on-screen test window"
        )
        XCTAssertTrue(
            DashboardPanelAnchor.isPlausibleMenuBarRect(
                anchorRect,
                screenFrames: NSScreen.screens.map(\.frame)
            ),
            "anchor fixture must land in a menu bar band; anchorRect=\(anchorRect) screens=\(NSScreen.screens.map(\.frame))"
        )
        return view
    }

    private func assertPanel(_ host: DashboardAdaptivePopoverHost, avoidsAnchorView anchorView: NSView) throws {
        let anchorRect = try XCTUnwrap(DashboardPanelAnchor.screenRect(for: anchorView))
        let panel = try XCTUnwrap(host.panelForTesting)
        XCTAssertFalse(
            panel.frame.intersects(anchorRect),
            "panel frame \(panel.frame) must not cover the anchor \(anchorRect)"
        )
    }

    private func makeState(_ kind: DashboardPresentationHostKind) -> HostKindBox {
        HostKindBox(kind: kind)
    }

    private func makeHost(
        state: HostKindBox,
        panelHost: DashboardPanelHost = DashboardPanelHost()
    ) -> DashboardAdaptivePopoverHost {
        DashboardAdaptivePopoverHost(
            hostKindProvider: { state.kind },
            panelHost: panelHost
        )
    }

    private func drainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    func testHostKindUsesPanelOnlyWithLiquidGlassAndFullTransparency() {
        XCTAssertEqual(DashboardPresentationHostKind.resolve(majorVersion: 26, reduceTransparency: false), .panel)
        XCTAssertEqual(DashboardPresentationHostKind.resolve(majorVersion: 27, reduceTransparency: false), .panel)
        XCTAssertEqual(DashboardPresentationHostKind.resolve(majorVersion: 26, reduceTransparency: true), .popover)
        XCTAssertEqual(DashboardPresentationHostKind.resolve(majorVersion: 15, reduceTransparency: false), .popover)
    }

    func testPopoverHostKindUsesPopoverHost() throws {
        let state = makeState(.popover)
        let host = makeHost(state: state)
        let contentViewController = NSHostingController(rootView: Text("standard"))
        host.contentViewController = contentViewController
        host.contentSize = NSSize(width: 420, height: 320)

        host.show(
            relativeTo: NSRect(x: 0, y: 0, width: 24, height: 24),
            of: try makeAnchorView(),
            preferredEdge: .minY
        )

        XCTAssertEqual(host.activeHostKind, .popover)
        XCTAssertTrue(host.isShown)
        XCTAssertTrue(host.contentViewController === contentViewController)

        host.performClose(nil)
        drainRunLoop()
        XCTAssertFalse(host.isShown)
    }

    func testPanelHostKindUsesPanelWithSharedContentViewController() throws {
        let state = makeState(.panel)
        let host = makeHost(state: state)
        let contentViewController = NSHostingController(rootView: Text("transparent"))
        host.contentViewController = contentViewController
        host.contentSize = NSSize(width: 420, height: 320)
        let anchorView = try makeAnchorView()

        host.show(
            relativeTo: NSRect(x: 0, y: 0, width: 24, height: 24),
            of: anchorView,
            preferredEdge: .minY
        )

        XCTAssertEqual(host.activeHostKind, .panel)
        XCTAssertTrue(host.isShown)
        XCTAssertTrue(host.contentViewController === contentViewController)
        XCTAssertTrue(host.panelForTesting?.contentViewController === contentViewController)
        try assertPanel(host, avoidsAnchorView: anchorView)

        host.performClose(nil)
        XCTAssertFalse(host.isShown)
        XCTAssertNotNil(host.panelForTesting, "close hides the panel and keeps it attached for reuse")
    }

    func testHostSwitchDestroysHiddenPanelAndRecreatesForPanelAgain() throws {
        let state = makeState(.panel)
        let host = makeHost(state: state)
        let contentViewController = NSHostingController(rootView: Text("switch panels"))
        host.contentViewController = contentViewController
        host.contentSize = NSSize(width: 420, height: 320)
        let anchorView = try makeAnchorView()
        let anchorRect = NSRect(x: 0, y: 0, width: 24, height: 24)

        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        let firstPanel = host.panelForTesting
        XCTAssertNotNil(firstPanel)
        try assertPanel(host, avoidsAnchorView: anchorView)
        host.performClose(nil)

        state.kind = .popover
        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        XCTAssertEqual(host.activeHostKind, .popover)
        XCTAssertNil(host.panelForTesting, "switching hosts destroys the hidden panel")
        host.performClose(nil)

        state.kind = .panel
        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        XCTAssertEqual(host.activeHostKind, .panel)
        XCTAssertNotNil(host.panelForTesting)
        XCTAssertFalse(host.panelForTesting === firstPanel)
        XCTAssertTrue(host.panelForTesting?.contentViewController === contentViewController)
        host.performClose(nil)
    }

    func testAnchorOutsideMenuBarFallsBackToPopover() throws {
        let host = makeHost(state: makeState(.panel))
        let contentViewController = NSHostingController(rootView: Text("overflow"))
        host.contentViewController = contentViewController
        host.contentSize = NSSize(width: 420, height: 320)
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let window = NSWindow(
            contentRect: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 120, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        Self.retainedWindows.append(window)
        let anchorView = NSView(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
        window.contentView?.addSubview(anchorView)
        window.orderFront(nil)

        host.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)

        XCTAssertEqual(host.activeHostKind, .popover)
        XCTAssertNil(host.panelForTesting)
        XCTAssertTrue(host.contentViewController === contentViewController)
        host.performClose(nil)
        drainRunLoop()
    }

    func testInvalidAnchorDoesNotPresentPanel() {
        let state = makeState(.panel)
        let host = makeHost(state: state)
        host.contentViewController = NSHostingController(rootView: Text("transparent"))
        host.contentSize = NSSize(width: 420, height: 320)

        host.show(
            relativeTo: NSRect(x: 0, y: 0, width: 24, height: 24),
            of: NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24)),
            preferredEdge: .minY
        )

        XCTAssertFalse(host.isShown)
        XCTAssertNil(host.activeHostKind)
    }

    func testHostSwapKeepsTheSameContentViewControllerInstance() throws {
        let state = makeState(.popover)
        let host = makeHost(state: state)
        let contentViewController = NSHostingController(rootView: Text("swap"))
        host.contentViewController = contentViewController
        host.contentSize = NSSize(width: 420, height: 320)
        let anchorView = try makeAnchorView()
        let anchorRect = NSRect(x: 0, y: 0, width: 24, height: 24)

        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        XCTAssertEqual(host.activeHostKind, .popover)
        drainRunLoop()
        host.performClose(nil)

        state.kind = .panel
        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        XCTAssertEqual(host.activeHostKind, .panel)
        XCTAssertTrue(host.contentViewController === contentViewController)
        try assertPanel(host, avoidsAnchorView: anchorView)
        host.performClose(nil)

        state.kind = .popover
        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        XCTAssertEqual(host.activeHostKind, .popover)
        XCTAssertTrue(host.contentViewController === contentViewController)
        host.performClose(nil)
    }

    func testHostKindChangeBetweenShowsSwapsHostAndReverses() throws {
        let state = makeState(.panel)
        let host = makeHost(state: state)
        host.contentViewController = NSHostingController(rootView: Text("fallback"))
        host.contentSize = NSSize(width: 420, height: 320)
        let anchorView = try makeAnchorView()
        let anchorRect = NSRect(x: 0, y: 0, width: 24, height: 24)

        state.kind = .popover

        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        XCTAssertEqual(host.activeHostKind, .popover)
        host.performClose(nil)
        drainRunLoop()

        state.kind = .panel

        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        XCTAssertEqual(host.activeHostKind, .panel)
        try assertPanel(host, avoidsAnchorView: anchorView)
        host.performClose(nil)
    }

    func testPerformCloseOnHiddenAttachedPanelDoesNotNotifyAgainOrDestroyIt() throws {
        let state = makeState(.panel)
        let host = makeHost(state: state)
        let closeCounter = AdaptiveHostCloseCounter()
        host.delegate = closeCounter
        let contentViewController = NSHostingController(rootView: Text("hidden panel close"))
        host.contentViewController = contentViewController
        host.contentSize = NSSize(width: 420, height: 320)
        let anchorView = try makeAnchorView()
        let anchorRect = NSRect(x: 0, y: 0, width: 24, height: 24)

        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        XCTAssertEqual(host.activeHostKind, .panel)
        try assertPanel(host, avoidsAnchorView: anchorView)
        host.performClose(nil)
        drainRunLoop()
        XCTAssertEqual(closeCounter.closeCount, 1)
        let hiddenPanel = host.panelForTesting

        host.performClose(nil)
        drainRunLoop()

        XCTAssertEqual(closeCounter.closeCount, 1, "repeated close on a hidden host must not notify again")
        XCTAssertTrue(host.panelForTesting === hiddenPanel, "the hidden attached panel must be kept for reuse")
        XCTAssertFalse(host.isShown)

        host.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
        XCTAssertEqual(host.activeHostKind, .panel)
        XCTAssertTrue(host.panelForTesting === hiddenPanel)
        host.performClose(nil)
    }

    func testHostForwardsPopoverConfigurationAccessors() {
        let host = makeHost(state: makeState(.popover))

        XCTAssertEqual(host.behavior, .transient)
        host.behavior = .semitransient
        XCTAssertEqual(host.behavior, .semitransient)

        XCTAssertTrue(host.animates)
        host.animates = false
        XCTAssertFalse(host.animates)

        let delegate = AdaptiveHostCloseCounter()
        XCTAssertNil(host.delegate)
        host.delegate = delegate
        XCTAssertTrue(host.delegate === delegate)
    }

    func testVisiblePanelContentSizeReadsAndResizesThroughPanelHost() throws {
        let state = makeState(.panel)
        let host = makeHost(state: state)
        host.contentViewController = NSHostingController(rootView: Text("panel content size"))
        host.contentSize = NSSize(width: 420, height: 320)

        host.show(
            relativeTo: NSRect(x: 0, y: 0, width: 24, height: 24),
            of: try makeAnchorView(),
            preferredEdge: .minY
        )
        defer { host.performClose(nil) }

        XCTAssertEqual(host.activeHostKind, .panel)
        XCTAssertEqual(host.contentSize.width, 420, accuracy: 0.5)
        XCTAssertEqual(host.contentSize.height, 320, accuracy: 0.5)

        host.contentSize = NSSize(width: 420, height: 480)

        XCTAssertEqual(host.contentSize.width, 420, accuracy: 0.5)
        XCTAssertEqual(host.contentSize.height, 480, accuracy: 0.5)
    }
}

@MainActor
private final class HostKindBox {
    var kind: DashboardPresentationHostKind

    init(kind: DashboardPresentationHostKind) {
        self.kind = kind
    }
}

@MainActor
private final class AdaptiveHostCloseCounter: NSObject, NSPopoverDelegate {
    private(set) var closeCount = 0

    func popoverDidClose(_ notification: Notification) {
        closeCount += 1
    }
}
