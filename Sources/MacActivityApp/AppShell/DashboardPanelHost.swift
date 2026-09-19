import AppKit

@MainActor
final class DashboardPanelHost {
    private(set) var panel: DashboardPresentationPanel?
    private var monitors: DashboardEventMonitorBag?
    private var anchorRect: NSRect = .zero
    private var visibleFrame: NSRect = .zero
    private var session = 0
    private var isCleaningUp = false
    private var menuTrackingDepth = 0
    private let makeMonitorBag: () -> DashboardEventMonitorBag
    var onClose: (() -> Void)?
    var presentPanel: (DashboardPresentationPanel) -> Void = { $0.makeKeyAndOrderFront(nil) }

    init(makeMonitorBag: @escaping () -> DashboardEventMonitorBag = { .live() }) {
        self.makeMonitorBag = makeMonitorBag
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
        presentPanel(panel)
        installMonitors(session: currentSession, panel: panel)
    }

    func resizeContent(to contentSize: NSSize) {
        guard let panel, panel.isVisible else { return }
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
        guard isCleaningUp == false else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }

        session += 1
        menuTrackingDepth = 0
        monitors?.removeAll()
        monitors = nil

        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        onClose?()
    }

    func destroy() {
        guard isCleaningUp == false else { return }
        isCleaningUp = true
        defer { isCleaningUp = false }

        session += 1
        menuTrackingDepth = 0
        monitors?.removeAll()
        monitors = nil

        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        panel.contentViewController = nil
        panel.close()
    }

    private func screenLocation(for event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func handlePanelWillClose(session: Int) {
        guard session == self.session else { return }
        let wasVisible = panel?.isVisible == true
        destroy()
        if wasVisible {
            onClose?()
        }
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
