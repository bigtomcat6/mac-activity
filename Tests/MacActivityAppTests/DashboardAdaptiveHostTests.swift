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

    func testPanelFadeCloseIntentAllowsReopenBeforeOldPhysicalCompletion() throws {
        var completions: [@MainActor () -> Void] = []
        let panelHost = DashboardPanelHost(shouldReduceMotion: { false }, animateAlpha: { panel, alpha, _, completion in
            panel.alphaValue = alpha
            completions.append(completion)
        })
        defer { panelHost.destroy() }
        let host = makeHost(state: makeState(.panel), panelHost: panelHost)
        let counter = AdaptiveHostCloseCounter()
        host.delegate = counter
        host.contentViewController = NSHostingController(rootView: Text("intent"))
        host.contentSize = NSSize(width: 420, height: 320)
        let anchor = try makeAnchorView()
        host.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        let panel = try XCTUnwrap(panelHost.panel)
        host.performClose(nil)
        XCTAssertFalse(host.isShown)
        XCTAssertNil(host.activeHostKind)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(counter.willCloseCount, 1)
        XCTAssertEqual(counter.closeCount, 0)
        host.performClose(nil)
        XCTAssertEqual(counter.willCloseCount, 1)
        host.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        completions[1]()
        XCTAssertTrue(host.isShown)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(counter.closeCount, 0, "stale physical close must not notify the new session")
        host.performClose(nil)
        completions.last?()
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(counter.willCloseCount, 2)
        XCTAssertEqual(counter.closeCount, 1)
    }

    func testPanelAnimatesFalseAndHostReplacementCancelOldFade() throws {
        var completions: [@MainActor () -> Void] = []
        let panelHost = DashboardPanelHost(shouldReduceMotion: { false }, animateAlpha: { _, _, _, completion in
            completions.append(completion)
        })
        let state = makeState(.panel)
        let host = makeHost(state: state, panelHost: panelHost)
        let content = NSHostingController(rootView: Text("swap while closing"))
        host.contentViewController = content
        host.contentSize = NSSize(width: 420, height: 320)
        let anchor = try makeAnchorView()
        host.animates = false
        host.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        XCTAssertTrue(completions.isEmpty)
        host.performClose(nil)
        XCTAssertFalse(panelHost.panel?.isVisible == true)
        host.animates = true
        host.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        host.performClose(nil)
        state.kind = .popover // Same resolved boundary as Reduce Transparency.
        host.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        completions.forEach { $0() }
        XCTAssertTrue(host.isShown)
        XCTAssertEqual(host.activeHostKind, .popover)
        XCTAssertNil(panelHost.panel)
        XCTAssertTrue(host.contentViewController === content)
        host.performClose(nil)
        drainRunLoop()
    }

    func testNativePopoverForwardsWillCloseIntentOnceAndKeepsNativeAnimationChoice() throws {
        for reduceMotion in [false, true] {
            let host = DashboardAdaptivePopoverHost(hostKindProvider: { .popover }, shouldReduceMotion: { reduceMotion })
            let counter = AdaptiveHostCloseCounter()
            host.delegate = counter
            host.contentViewController = NSHostingController(rootView: Text("native arrow"))
            host.contentSize = NSSize(width: 420, height: 320)
            let anchor = try makeAnchorView()
            host.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            XCTAssertTrue(host.isShown)
            XCTAssertEqual(host.activeHostKind, .popover)
            XCTAssertTrue(host.animates, "requested native animation remains enabled; Reduce Motion only snaps presentation")
            host.performClose(nil)
            XCTAssertFalse(host.isShown, "native willClose must clear intent before didClose")
            XCTAssertEqual(counter.willCloseCount, 1)
            host.performClose(nil)
            drainRunLoop()
            XCTAssertEqual(counter.closeCount, 1)
            XCTAssertEqual(counter.willCloseCount, 1)
        }
    }

    func testInvalidateForcesNativePopoverClosedWithNestedInfoPopover() throws {
        let host = DashboardAdaptivePopoverHost(hostKindProvider: { .popover })
        host.animates = false
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        let infoAnchor = NSView(frame: NSRect(x: 20, y: 20, width: 24, height: 24))
        content.view.addSubview(infoAnchor)
        host.contentViewController = content
        host.contentSize = NSSize(width: 420, height: 320)
        let counter = AdaptiveHostCloseCounter()
        host.delegate = counter
        let info = NSPopover()
        info.behavior = .applicationDefined
        info.animates = false
        info.contentViewController = NSHostingController(rootView: Text("nested energy info"))
        info.contentSize = NSSize(width: 180, height: 80)
        defer { info.close(); host.invalidate() }
        let anchor = try makeAnchorView()
        host.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        let parentWindow = try XCTUnwrap(content.view.window)
        info.show(relativeTo: infoAnchor.bounds, of: infoAnchor, preferredEdge: .maxX)
        let childWindow = try XCTUnwrap(info.contentViewController?.view.window)
        XCTAssertTrue(info.isShown)
        XCTAssertTrue(childWindow.isVisible)
        XCTAssertTrue(childWindow.parent === parentWindow)
        host.performClose(nil)
        XCTAssertTrue(host.isShown, "ordinary user close must retain AppKit's nested-popover veto")
        XCTAssertTrue(parentWindow.isVisible)
        XCTAssertEqual(counter.willCloseCount, 0)
        host.invalidate()
        XCTAssertFalse(host.isShown)
        XCTAssertFalse(parentWindow.isVisible, "teardown must physically close the native parent")
        XCTAssertFalse(info.isShown)
        XCTAssertFalse(childWindow.isVisible)
        XCTAssertEqual(counter.willCloseCount, 1)
        XCTAssertEqual(counter.closeCount, 1)
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
    private(set) var willCloseCount = 0

    func popoverWillClose(_ notification: Notification) {
        willCloseCount += 1
    }

    func popoverDidClose(_ notification: Notification) {
        closeCount += 1
    }
}
