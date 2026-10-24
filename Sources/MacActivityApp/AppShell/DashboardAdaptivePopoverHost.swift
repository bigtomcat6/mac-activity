import AppKit

enum DashboardPresentationHostKind: Equatable, Sendable {
    case popover
    case panel

    // Floating glass modules need Liquid Glass to stay legible over the desktop;
    // earlier systems and Reduce Transparency keep the popover's own backing.
    static func resolve(majorVersion: Int, reduceTransparency: Bool) -> Self {
        majorVersion >= 26 && !reduceTransparency ? .panel : .popover
    }

    static func live(
        workspace: NSWorkspace = .shared,
        processInfo: ProcessInfo = .processInfo
    ) -> Self {
        resolve(
            majorVersion: processInfo.operatingSystemVersion.majorVersion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency
        )
    }
}

@MainActor
final class DashboardAdaptivePopoverHost: NSObject, DashboardPopoverHosting, NSPopoverDelegate {
    private let hostKindProvider: () -> DashboardPresentationHostKind
    private let panelHost: DashboardPanelHost
    private let popover = NSPopover()
    private weak var storedDelegate: NSPopoverDelegate?
    private var storedContentViewController: NSViewController?
    private var storedContentSize: NSSize = .zero
    private var popoverIsShown = false
    private var storedAnimates = true
    private let shouldReduceMotion: () -> Bool
    private let visibleFrameForAnchor: (NSRect) -> NSRect
    private weak var positioningView: NSView?
    private var positioningRect: NSRect = .zero
    private var placementKind: DashboardPresentationHostKind?
    // Conservative first-show reserve; replace with the native window's measured chrome immediately after show.
    private var popoverChromeHeight: CGFloat = 32
    private(set) var availableContentHeight: CGFloat = .greatestFiniteMagnitude
    var onAvailableContentHeightChange: (() -> Void)?

    init(
        hostKindProvider: @escaping () -> DashboardPresentationHostKind = { .live() },
        visibleFrameForAnchor: @escaping (NSRect) -> NSRect = {
            DashboardPanelPlacement.visibleFrame(for: $0, screens: NSScreen.screens)
        },
        panelHost: DashboardPanelHost = DashboardPanelHost(),
        shouldReduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.hostKindProvider = hostKindProvider
        self.panelHost = panelHost
        self.shouldReduceMotion = shouldReduceMotion
        self.visibleFrameForAnchor = visibleFrameForAnchor
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        panelHost.onClose = { [weak self] in
            self?.notifyPopoverWillClose()
        }
        panelHost.onDidClose = { [weak self] in
            self?.notifyPopoverDidClose()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(anchorWindowChanged(_:)),
            name: NSWindow.didMoveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(anchorWindowChanged(_:)),
            name: NSWindow.didChangeScreenNotification, object: nil)
    }

    var behavior: NSPopover.Behavior {
        get { popover.behavior }
        set { popover.behavior = newValue }
    }

    var animates: Bool {
        get { storedAnimates }
        set {
            storedAnimates = newValue
            popover.animates = newValue && !shouldReduceMotion()
            panelHost.animates = newValue
        }
    }

    var contentSize: NSSize {
        get {
            if panelHost.isShown, let size = panelHost.contentSize {
                return size
            }
            return popoverIsShown ? popover.contentSize : constrainedSize(storedContentSize)
        }
        set {
            storedContentSize = newValue
            if panelHost.isShown {
                panelHost.resizeContent(to: constrainedSize(newValue))
            } else {
                popover.contentSize = constrainedSize(newValue)
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
        }
    }

    var isShown: Bool { popoverIsShown || panelHost.isShown }

    var activeHostKind: DashboardPresentationHostKind? {
        if panelHost.isShown { return .panel }
        if popoverIsShown { return .popover }
        return nil
    }

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        self.positioningView = positioningView
        self.positioningRect = positioningRect
        switch hostKindProvider() {
        case .popover:
            showPopover(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
        case .panel:
            guard showPanel(positioningView: positioningView) else {
                // An anchor outside the menu bar (a menu bar manager's overflow, say)
                // cannot place the panel, but a popover still attaches to any window.
                guard positioningView.window != nil else { return }
                showPopover(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
                return
            }
        }
    }

    private func showPopover(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        detachPanel()
        placementKind = .popover
        updateAvailableHeight()
        guard availableContentHeight > 0 else { return }
        popover.contentViewController = storedContentViewController
        popover.contentSize = constrainedSize(storedContentSize)
        popover.animates = storedAnimates && !shouldReduceMotion()
        popover.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
        popoverIsShown = popover.isShown
        if popoverIsShown, let window = storedContentViewController?.view.window {
            let chrome = window.frame.height - popover.contentSize.height
            if chrome.isFinite, chrome > 0 {
                popoverChromeHeight = chrome
                updateAvailableHeight()
                popover.contentSize = constrainedSize(storedContentSize)
            }
        }
    }

    func performClose(_ sender: Any?) {
        if panelHost.isShown {
            panelHost.close()
            return
        }
        if popoverIsShown {
            popover.animates = storedAnimates && !shouldReduceMotion()
            popover.performClose(nil)
        }
    }

    private func showPanel(positioningView: NSView) -> Bool {
        guard let contentViewController = storedContentViewController,
              let anchorRect = DashboardPanelAnchor.screenRect(for: positioningView),
              DashboardPanelAnchor.isPlausibleMenuBarRect(
                  anchorRect,
                  screenFrames: NSScreen.screens.map(\.frame)
              ) else {
            return false
        }

        if popover.isShown {
            popover.performClose(nil)
        }
        popover.contentViewController = nil
        placementKind = .panel
        updateAvailableHeight()
        guard availableContentHeight > 0 else { return false }
        let visibleFrame = visibleFrameForAnchor(anchorRect)
        let contentSize = storedContentSize == .zero
            ? contentViewController.view.fittingSize
            : constrainedSize(storedContentSize)
        panelHost.show(
            contentViewController: contentViewController,
            anchorRect: anchorRect,
            visibleFrame: visibleFrame,
            contentSize: contentSize
        )
        return panelHost.isShown
    }

    private func constrainedSize(_ size: NSSize) -> NSSize {
        NSSize(width: size.width, height: min(size.height, availableContentHeight))
    }

    private func updateAvailableHeight() {
        guard let view = positioningView, let window = view.window, let placementKind else { return }
        let anchor = window.convertToScreen(view.convert(positioningRect, to: nil))
        let visible = visibleFrameForAnchor(anchor)
        let height: CGFloat
        if placementKind == .panel {
            height = DashboardPanelPlacement.availableContentHeight(anchorRect: anchor, visibleFrame: visible)
        } else {
            // The arrow and native backing belong to NSPopover, not the borderless panel.
            let below = min(anchor.minY, visible.maxY - 8) - (visible.minY + 8)
            let above = visible.maxY - 8 - max(anchor.maxY, visible.minY + 8)
            height = max(0, max(below, above) - popoverChromeHeight)
        }
        guard height.isFinite, height != availableContentHeight else { return }
        availableContentHeight = height
        onAvailableContentHeightChange?()
    }

    @objc private func anchorWindowChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === positioningView?.window else { return }
        screenParametersChanged()
    }

    @objc private func screenParametersChanged() {
        guard isShown else { return }
        updateAvailableHeight()
        guard availableContentHeight > 0 else {
            performClose(nil)
            return
        }
        if panelHost.isShown, let anchor = DashboardPanelAnchor.screenRect(for: positioningView) {
            panelHost.updatePlacement(anchorRect: anchor, visibleFrame: visibleFrameForAnchor(anchor),
                contentSize: constrainedSize(storedContentSize))
        } else if popoverIsShown {
            popover.contentSize = constrainedSize(storedContentSize)
        }
    }

    private func detachPanel() {
        if panelHost.panel != nil {
            panelHost.destroy()
        }
    }

    private func notifyPopoverDidClose() {
        guard !isShown else { return }
        storedDelegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
    }

    private func notifyPopoverWillClose() {
        storedDelegate?.popoverWillClose?(Notification(name: NSPopover.willCloseNotification, object: self))
    }

    func popoverWillClose(_ notification: Notification) {
        guard popoverIsShown else { return }
        popoverIsShown = false
        notifyPopoverWillClose()
    }

    func popoverDidClose(_ notification: Notification) {
        notifyPopoverDidClose()
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        storedDelegate?.popoverShouldClose?(popover) ?? true
    }

    func popoverWillShow(_ notification: Notification) {
        storedDelegate?.popoverWillShow?(notification)
    }

    func popoverDidShow(_ notification: Notification) {
        storedDelegate?.popoverDidShow?(notification)
    }

    func invalidate() {
        panelHost.destroy()
        popover.animates = false
        if popover.isShown { popover.close() }
        popoverIsShown = false
    }

    #if DEBUG
    var panelForTesting: DashboardPresentationPanel? {
        panelHost.panel
    }
    #endif
}
