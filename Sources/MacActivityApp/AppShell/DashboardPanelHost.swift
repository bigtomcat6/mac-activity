import AppKit

typealias DashboardPanelAlphaAnimator = @MainActor (
    NSWindow, CGFloat, TimeInterval, @escaping @MainActor () -> Void
) -> Void

@MainActor
final class DashboardPanelHost: NSObject, NSWindowDelegate {
    private(set) var panel: DashboardPresentationPanel?
    private var monitors: DashboardEventMonitorBag?
    private var anchorRect: NSRect = .zero
    private var visibleFrame: NSRect = .zero
    private var session = 0
    private var isCleaningUp = false
    private var menuTrackingDepth = 0
    private let makeMonitorBag: () -> DashboardEventMonitorBag
    private let shouldReduceMotion: () -> Bool
    private let animateAlpha: DashboardPanelAlphaAnimator
    private(set) var isShown = false
    private var isClosing = false
    var animates = true
    var onClose: (() -> Void)?
    var onDidClose: (() -> Void)?
    // Window alpha previously caused persistent glass bloom. Short native fades are
    // compositor-gated against cold full-opacity glass; always normalize after hide.
    var presentPanel: (DashboardPresentationPanel) -> Void = { $0.makeKeyAndOrderFront(nil) }

    init(
        makeMonitorBag: @escaping () -> DashboardEventMonitorBag = { .live() },
        shouldReduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        animateAlpha: @escaping DashboardPanelAlphaAnimator = { window, alpha, duration, completion in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                window.animator().alphaValue = alpha
            } completionHandler: {
                DispatchQueue.main.async { completion() }
            }
        }
    ) {
        self.makeMonitorBag = makeMonitorBag
        self.shouldReduceMotion = shouldReduceMotion
        self.animateAlpha = animateAlpha
        super.init()
    }

    deinit {
        let monitors = monitors
        let panel = panel
        DispatchQueue.main.async {
            monitors?.removeAll()
            panel?.delegate = nil
            panel?.orderOut(nil)
            panel?.contentViewController = nil
            panel?.close()
        }
    }

    var isVisible: Bool { panel?.isVisible == true }
    var activeMonitorCount: Int { monitors?.activeCount ?? 0 }
    var isMenuTracking: Bool { menuTrackingDepth > 0 }
    var contentSize: NSSize? {
        guard let panel else { return nil }
        return panel.contentRect(forFrameRect: panel.frame).size
    }

    func show(
        contentViewController: NSViewController,
        anchorRect: NSRect,
        visibleFrame: NSRect,
        contentSize: NSSize
    ) {
        self.anchorRect = anchorRect
        self.visibleFrame = visibleFrame

        if let panel, panel.contentViewController !== contentViewController {
            destroy()
        }

        session += 1
        let currentSession = session

        let panel: DashboardPresentationPanel
        if let existingPanel = self.panel {
            panel = existingPanel
            panel.contentViewController = contentViewController
        } else {
            panel = DashboardPanelFactory.makePanel(contentRect: .zero)
            panel.contentViewController = contentViewController
            self.panel = panel
        }

        let frame = DashboardPanelPlacement.panelFrame(
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: contentSize
        )
        panel.setFrame(frame, display: false)
        panel.delegate = self
        panel.ignoresMouseEvents = false
        panel.acceptsKeyboardInput = true
        let shouldFade = animates && !shouldReduceMotion()
        stopAlphaAnimation(in: panel, at: shouldFade && !isShown ? 0 : 1)
        presentPanel(panel)
        guard panel.isVisible else { return }
        let wasShown = isShown
        isShown = true
        isClosing = false
        installMonitors(session: currentSession, panel: panel)
        if shouldFade && !wasShown {
            animateAlpha(panel, 1, 0.14) { [weak self, weak panel] in
                guard let self, let panel, self.session == currentSession,
                      self.panel === panel, self.isShown else { return }
                self.stopAlphaAnimation(in: panel, at: 1)
            }
        }
    }

    func resizeContent(to contentSize: NSSize) {
        guard let panel, isShown else { return }
        let frame = DashboardPanelPlacement.panelFrame(
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: contentSize
        )
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
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
        guard isCleaningUp == false, isShown else { return }
        isCleaningUp = true

        session += 1
        menuTrackingDepth = 0
        monitors?.removeAll()
        monitors = nil
        isShown = false
        isClosing = true
        let currentSession = session
        let closingPanel = panel
        closingPanel?.ignoresMouseEvents = true
        closingPanel?.acceptsKeyboardInput = false
        closingPanel?.resignKey()
        isCleaningUp = false
        onClose?()
        // Close callbacks may synchronously reopen or replace this host.
        guard session == currentSession, let panel = closingPanel, self.panel === panel, !isShown else { return }
        let finish: @MainActor () -> Void = { [weak self, weak panel] in
            guard let self, let panel, self.session == currentSession,
                  self.panel === panel, !self.isShown else { return }
            panel.orderOut(nil)
            self.stopAlphaAnimation(in: panel, at: 1)
            self.isClosing = false
            self.onDidClose?()
        }
        if animates && !shouldReduceMotion() && panel.isVisible {
            stopAlphaAnimation(in: panel, at: panel.alphaValue)
            animateAlpha(panel, 0, 0.11, finish)
        } else {
            finish()
        }
    }

    private func stopAlphaAnimation(in panel: NSWindow, at alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = alpha
        }
    }

    func destroy() {
        guard isCleaningUp == false else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }

        session += 1
        menuTrackingDepth = 0
        monitors?.removeAll()
        monitors = nil
        let wasShown = isShown
        let wasClosing = isClosing
        isShown = false
        isClosing = false

        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
        stopAlphaAnimation(in: panel, at: 1)
        panel.contentViewController = nil
        panel.close()
        isCleaningUp = false
        if wasShown {
            onClose?()
        }
        if wasShown || wasClosing {
            onDidClose?()
        }
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func handlePanelWillClose(session: Int) {
        guard session == self.session else { return }
        destroy()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        handlePanelWillClose(session: session)
    }

    private func installMonitors(session: Int, panel: DashboardPresentationPanel) {
        monitors?.removeAll()
        let bag = makeMonitorBag()
        bag.observe(name: NSWindow.willCloseNotification, object: panel) { [weak self] _ in
            self?.handlePanelWillClose(session: session)
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
}
