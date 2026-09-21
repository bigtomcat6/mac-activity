import AppKit
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class PrototypePopoverHost {
    let popover = NSPopover()
    private var monitors: PrototypeMonitorBag?
    private var session = 0
    var onClose: (() -> Void)?

    init() {
        popover.behavior = .transient
        popover.animates = true
    }

    var isVisible: Bool { popover.isShown }
    var activeMonitorCount: Int { monitors?.activeCount ?? 0 }

    func show<Content: View>(content: Content, anchorView: NSView) {
        close()
        session += 1
        let currentSession = session

        let bag = PrototypeMonitorBag.live()
        bag.observe(name: NSPopover.didCloseNotification, object: popover) { [weak self] _ in
            self?.handleDidClose(session: currentSession)
        }
        monitors = bag

        let controller = NSHostingController(rootView: content)
        controller.view.frame = NSRect(x: 0, y: 0, width: PrototypeLayout.contentWidth, height: 10)
        popover.contentViewController = controller
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    func close() {
        session += 1
        monitors?.removeAll()
        monitors = nil
        if popover.isShown {
            popover.performClose(nil)
        }
        popover.contentViewController = nil
    }

    private func handleDidClose(session: Int) {
        guard session == self.session else { return }
        monitors?.removeAll()
        monitors = nil
        onClose?()
    }
}

@available(macOS 26.0, *)
@MainActor
final class PrototypePanelHost {
    private(set) var panel: PrototypePanel?
    private var monitors: PrototypeMonitorBag?
    private var anchorRect: NSRect = .zero
    private var session = 0
    private var isCleaningUp = false
    private var menuTrackingDepth = 0
    private let makeMonitorBag: () -> PrototypeMonitorBag
    var onClose: (() -> Void)?
    var presentPanel: (PrototypePanel) -> Void = { $0.makeKeyAndOrderFront(nil) }

    init(makeMonitorBag: @escaping () -> PrototypeMonitorBag = { PrototypeMonitorBag.live() }) {
        self.makeMonitorBag = makeMonitorBag
    }

    var isVisible: Bool { panel?.isVisible == true }
    var activeMonitorCount: Int { monitors?.activeCount ?? 0 }
    var isMenuTracking: Bool { menuTrackingDepth > 0 }

    func show<Content: View>(content: Content, anchorRect: NSRect, visibleFrame: NSRect) {
        close()
        session += 1
        let currentSession = session
        self.anchorRect = anchorRect

        let hosting = NSHostingController(rootView: content)
        let fittingSize = hosting.view.fittingSize
        let contentSize = NSSize(
            width: PrototypeLayout.contentWidth,
            height: fittingSize.height > 40 ? fittingSize.height : PrototypeLayout.fallbackHeight
        )
        let frame = PrototypePlacement.panelFrame(
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: contentSize
        )

        let panel = PrototypePanelFactory.makePanel(contentRect: frame)
        panel.contentViewController = hosting
        panel.setFrame(frame, display: false)
        self.panel = panel
        presentPanel(panel)

        let bag = makeMonitorBag()
        bag.observe(name: NSWindow.willCloseNotification, object: panel) { [weak self] _ in
            self?.handlePanelWillClose(session: currentSession)
        }
        bag.observe(name: NSMenu.didBeginTrackingNotification) { [weak self] _ in
            self?.menuTrackingDepth += 1
        }
        bag.observe(name: NSMenu.didEndTrackingNotification) { [weak self] _ in
            guard let self else { return }
            self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
        }
        bag.addGlobal(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        bag.addLocal(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.shouldDismiss(forEventWindow: event.window, mouseLocation: self.screenLocation(for: event)) {
                self.close()
            }
            return event
        }
        bag.addLocal(mask: [.keyDown]) { [weak self] event in
            guard let self, event.keyCode == 53, self.isMenuTracking == false else { return event }
            self.close()
            return nil
        }
        monitors = bag
    }

    func shouldDismiss(forEventWindow eventWindow: NSWindow?, mouseLocation: NSPoint) -> Bool {
        if isMenuTracking { return false }

        var candidate = eventWindow
        while let window = candidate {
            if window === panel { return false }
            candidate = window.parent
        }

        if let panel, panel.frame.contains(mouseLocation) { return false }
        if anchorRect.contains(mouseLocation) { return false }
        return true
    }

    func close() {
        cleanup(closeWindow: true, notify: true)
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func handlePanelWillClose(session: Int) {
        guard session == self.session else { return }
        cleanup(closeWindow: false, notify: true)
    }

    private func cleanup(closeWindow: Bool, notify: Bool) {
        guard isCleaningUp == false else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }

        session += 1
        menuTrackingDepth = 0
        monitors?.removeAll()
        monitors = nil

        guard let panel else { return }
        self.panel = nil
        if closeWindow, panel.isVisible {
            panel.orderOut(nil)
        }
        panel.contentViewController = nil
        if closeWindow {
            panel.close()
        }
        if notify {
            onClose?()
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class PrototypeHostCoordinator {
    struct Context {
        var anchorView: NSView?
        var anchorRect: NSRect?
        var visibleFrame: NSRect
        var resolution: PrototypeResolution
    }

    private(set) var mode: PrototypeMode = .standardPopover
    private(set) var isVisible = false
    private(set) var effectiveHost: PrototypeHostKind?

    private let popoverHost = PrototypePopoverHost()
    private let panelHost = PrototypePanelHost()
    private let contextProvider: () -> Context?
    private let quit: () -> Void
    var panelPresenter: (PrototypePanel) -> Void = { $0.makeKeyAndOrderFront(nil) }

    var currentPopover: NSPopover { popoverHost.popover }
    var currentPanel: PrototypePanel? { panelHost.panel }
    var popoverIsShown: Bool { popoverHost.isVisible }
    var activeMonitorCount: Int { popoverHost.activeMonitorCount + panelHost.activeMonitorCount }

    init(contextProvider: @escaping () -> Context?, quit: @escaping () -> Void) {
        self.contextProvider = contextProvider
        self.quit = quit
        popoverHost.onClose = { [weak self] in
            self?.isVisible = false
        }
        panelHost.onClose = { [weak self] in
            self?.isVisible = false
        }
        panelHost.presentPanel = { [weak self] panel in
            self?.panelPresenter(panel)
        }
    }

    func toggle() {
        if isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        guard let context = contextProvider() else { return }
        let resolution = context.resolution
        effectiveHost = resolution.effectiveHost
        let view = PrototypeDashboardView(
            resolution: resolution,
            onQuit: { [weak self] in
                self?.quit()
            }
        )

        switch resolution.effectiveHost {
        case .popover:
            guard let anchorView = context.anchorView else { return }
            popoverHost.show(content: view, anchorView: anchorView)
            isVisible = popoverHost.isVisible
        case .panel:
            guard let anchorRect = context.anchorRect else { return }
            panelHost.show(content: view, anchorRect: anchorRect, visibleFrame: context.visibleFrame)
            isVisible = panelHost.isVisible
        }
    }

    func close() {
        popoverHost.close()
        panelHost.close()
        isVisible = false
    }

    func setMode(_ mode: PrototypeMode) {
        let wasVisible = isVisible
        close()
        self.mode = mode
        if wasVisible {
            show()
        }
    }

    func refresh() {
        guard isVisible else { return }
        close()
        show()
    }
}

@available(macOS 26.0, *)
@MainActor
final class PrototypeAnchorWindow: NSWindow {
    static let anchorIdentifier = "DebugGlassPrototype.anchor"

    let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier(Self.anchorIdentifier)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        contentView = anchorView
        setFrame(frame, display: true)
        orderFront(nil)
    }
}

@available(macOS 26.0, *)
@MainActor
final class PrototypeBackdropWindow: NSWindow {
    static let backdropIdentifier = "DebugGlassPrototype.backdrop"

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.visibleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        identifier = NSUserInterfaceItemIdentifier(Self.backdropIdentifier)
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        level = .normal
        collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        contentView = PrototypeBackdropView(frame: NSRect(origin: .zero, size: screen.visibleFrame.size))
        setFrame(screen.visibleFrame, display: true)
        orderFront(nil)
    }
}

@available(macOS 26.0, *)
final class PrototypeBackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        let colors: [NSColor] = [.systemPink, .systemCyan, .systemYellow, .systemGreen]
        let stripeWidth: CGFloat = 140
        var index = 0
        var x = -bounds.height
        while x < bounds.width {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: bounds.minY))
            path.line(to: NSPoint(x: x + stripeWidth, y: bounds.minY))
            path.line(to: NSPoint(x: x + stripeWidth + bounds.height, y: bounds.maxY))
            path.line(to: NSPoint(x: x + bounds.height, y: bounds.maxY))
            path.close()
            colors[index % colors.count].withAlphaComponent(0.9).setFill()
            path.fill()
            x += stripeWidth
            index += 1
        }

        let label = "CONTROLLED PROTOTYPE BACKDROP — not product UI"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 42, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }
}
