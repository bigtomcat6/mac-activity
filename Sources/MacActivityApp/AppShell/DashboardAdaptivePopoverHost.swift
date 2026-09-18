import AppKit

@MainActor
final class DashboardAdaptivePopoverHost: NSObject, DashboardPopoverHosting {
    private let resolutionProvider: () -> DashboardPresentationResolution
    private let panelHost: DashboardPanelHost
    private let popover = NSPopover()
    private weak var storedDelegate: NSPopoverDelegate?
    private var storedContentViewController: NSViewController?
    private var storedContentSize: NSSize = .zero

    init(
        resolutionProvider: @escaping () -> DashboardPresentationResolution,
        panelHost: DashboardPanelHost = DashboardPanelHost()
    ) {
        self.resolutionProvider = resolutionProvider
        self.panelHost = panelHost
        super.init()
        popover.behavior = .transient
        popover.animates = true
        panelHost.onClose = { [weak self] in
            self?.notifyPopoverDidClose()
        }
    }

    var behavior: NSPopover.Behavior {
        get { popover.behavior }
        set { popover.behavior = newValue }
    }

    var animates: Bool {
        get { popover.animates }
        set { popover.animates = newValue }
    }

    var contentSize: NSSize {
        get {
            if panelHost.isVisible, let size = panelHost.contentSize {
                return size
            }
            return storedContentSize == .zero ? popover.contentSize : storedContentSize
        }
        set {
            storedContentSize = newValue
            if panelHost.isVisible {
                panelHost.resizeContent(to: newValue)
            } else {
                popover.contentSize = newValue
            }
        }
    }

    var contentViewController: NSViewController? {
        get { storedContentViewController }
        set { storedContentViewController = newValue }
    }

    var delegate: NSPopoverDelegate? {
        get { storedDelegate }
        set {
            storedDelegate = newValue
            popover.delegate = newValue
        }
    }

    var isShown: Bool { popover.isShown || panelHost.isVisible }

    var activeHostKind: DashboardPresentationHostKind? {
        if panelHost.isVisible { return .panel }
        if popover.isShown { return .popover }
        return nil
    }

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        switch resolutionProvider().hostKind {
        case .popover:
            detachPanel()
            popover.contentViewController = storedContentViewController
            popover.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
        case .panel:
            showPanel(positioningView: positioningView)
        }
    }

    func performClose(_ sender: Any?) {
        if panelHost.isVisible {
            panelHost.close()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func showPanel(positioningView: NSView) {
        guard let contentViewController = storedContentViewController,
              let anchorRect = DashboardPanelAnchor.screenRect(for: positioningView),
              DashboardPanelAnchor.isPlausibleMenuBarRect(
                  anchorRect,
                  screenFrames: NSScreen.screens.map(\.frame)
              ) else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        }
        popover.contentViewController = nil
        let visibleFrame = DashboardPanelPlacement.visibleFrame(for: anchorRect, screens: NSScreen.screens)
        let contentSize = storedContentSize == .zero
            ? NSSize(width: DashboardPopoverLayout.contentWidth, height: DashboardPopoverLayout.maximumHeight)
            : storedContentSize
        panelHost.show(
            contentViewController: contentViewController,
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: contentSize
        )
    }

    private func detachPanel() {
        if panelHost.panel != nil {
            panelHost.destroy()
        }
    }

    private func notifyPopoverDidClose() {
        storedDelegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
    }

    #if DEBUG
    var panelForTesting: DashboardPresentationPanel? {
        panelHost.panel
    }
    #endif
}
