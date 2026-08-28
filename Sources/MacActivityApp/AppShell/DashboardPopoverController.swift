import AppKit
import SwiftUI
import MacActivityCore

@MainActor
protocol DashboardPopoverHosting: AnyObject {
    var behavior: NSPopover.Behavior { get set }
    var animates: Bool { get set }
    var contentSize: NSSize { get set }
    var contentViewController: NSViewController? { get set }
    var delegate: NSPopoverDelegate? { get set }
    var isShown: Bool { get }
    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge)
    func performClose(_ sender: Any?)
}

extension NSPopover: DashboardPopoverHosting {}

enum DashboardPopoverLayout {
    static let contentWidth: CGFloat = 420
    static let maximumHeight: CGFloat = 560

    static func contentSize(for measuredSize: NSSize) -> NSSize? {
        guard measuredSize.width.isFinite,
              measuredSize.width > 0,
              measuredSize.height.isFinite,
              measuredSize.height > 0 else {
            return nil
        }

        return NSSize(
            width: contentWidth,
            height: min(measuredSize.height, maximumHeight)
        )
    }
}

@MainActor
final class DashboardPopoverContentSizeCoordinator {
    private weak var popover: DashboardPopoverHosting?
    private var pendingContentSize: NSSize?
    private var isUpdateScheduled = false
    private var animationGeneration = 0
    private var animatingContentSize: NSSize?

    init(popover: DashboardPopoverHosting) {
        self.popover = popover
    }

    func applyImmediately(measuredSize: NSSize) {
        guard let contentSize = DashboardPopoverLayout.contentSize(for: measuredSize) else {
            return
        }
        pendingContentSize = nil
        apply(contentSize)
    }

    func schedule(measuredSize: NSSize) {
        guard let contentSize = DashboardPopoverLayout.contentSize(for: measuredSize) else {
            return
        }

        pendingContentSize = contentSize
        guard !isUpdateScheduled else {
            return
        }

        isUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.isUpdateScheduled = false
            guard let contentSize = self.pendingContentSize else {
                return
            }
            self.pendingContentSize = nil
            self.apply(contentSize)
        }
    }

    private func apply(_ contentSize: NSSize) {
        guard let popover else {
            return
        }

        if popover.contentSize == contentSize, animatingContentSize == nil {
            return
        }

        guard popover.isShown, let window = popover.contentViewController?.view.window else {
            animationGeneration += 1
            animatingContentSize = nil
            popover.contentSize = contentSize
            return
        }

        animateSizeChange(to: contentSize, in: window, popover: popover)
    }

    private func animateSizeChange(
        to contentSize: NSSize,
        in window: NSWindow,
        popover: DashboardPopoverHosting
    ) {
        guard animatingContentSize != contentSize else {
            return
        }

        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let currentFrame = window.frame
        let animatedFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetFrame.height,
            width: targetFrame.width,
            height: targetFrame.height
        )
        guard animatedFrame != currentFrame else {
            animatingContentSize = nil
            popover.contentSize = contentSize
            return
        }

        animationGeneration += 1
        animatingContentSize = contentSize
        let generation = animationGeneration
        let duration = window.animationResizeTime(animatedFrame)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            window.animator().setFrame(animatedFrame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation else {
                    return
                }
                self.animatingContentSize = nil
                guard let popover = self.popover else {
                    return
                }
                popover.contentSize = contentSize
            }
        }
    }
}

@MainActor
protocol DashboardPopoverFocusControlling: AnyObject {
    func activateApplication()
    func focusPresentedPopover(_ popover: DashboardPopoverHosting)
}

@MainActor
final class SharedDashboardPopoverFocusController: DashboardPopoverFocusControlling {
    func activateApplication() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func focusPresentedPopover(_ popover: DashboardPopoverHosting) {
        focusWindowIfAvailable(for: popover)
        DispatchQueue.main.async {
            self.focusWindowIfAvailable(for: popover)
        }
    }

    private func focusWindowIfAvailable(for popover: DashboardPopoverHosting) {
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class DashboardPopoverHostingController: NSHostingController<DashboardPopoverRootView> {
    var onContentLayoutChange: (() -> Void)?

    override var preferredContentSize: NSSize {
        didSet {
            onContentLayoutChange?()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        onContentLayoutChange?()
    }

    func layoutAndMeasureContentSize() -> NSSize {
        _ = view
        view.layoutSubtreeIfNeeded()
        return measuredContentSize()
    }

    func measuredContentSize() -> NSSize {
        NSSize(
            width: DashboardPopoverLayout.contentWidth,
            height: preferredContentSize.height
        )
    }

    var dashboardView: DashboardView {
        rootView.content
    }
}

struct DashboardPopoverRootView: View {
    let content: DashboardView

    var body: some View {
        content.frame(width: DashboardPopoverLayout.contentWidth, alignment: .topLeading)
    }
}

@MainActor
final class DashboardPopoverController: NSObject, NSPopoverDelegate {
    private let popover: DashboardPopoverHosting
    private let focusController: DashboardPopoverFocusControlling
    private let onVisibilityChange: (Bool) -> Void
    private let contentSizeCoordinator: DashboardPopoverContentSizeCoordinator
    private let dashboardHostingController: DashboardPopoverHostingController

    convenience init(
        dashboardModel: DashboardModel,
        preferencesController: PreferencesController,
        audioDashboardModel: AudioDashboardModel,
        onVisibilityChange: @escaping (Bool) -> Void,
        openPreferences: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.init(
            popover: NSPopover(),
            focusController: SharedDashboardPopoverFocusController(),
            dashboardModel: dashboardModel,
            preferencesController: preferencesController,
            audioDashboardModel: audioDashboardModel,
            onVisibilityChange: onVisibilityChange,
            openPreferences: openPreferences,
            quitApplication: quitApplication
        )
    }

    init(
        popover: DashboardPopoverHosting,
        focusController: DashboardPopoverFocusControlling,
        dashboardModel: DashboardModel,
        preferencesController: PreferencesController,
        audioDashboardModel: AudioDashboardModel,
        onVisibilityChange: @escaping (Bool) -> Void,
        openPreferences: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.popover = popover
        self.focusController = focusController
        self.onVisibilityChange = onVisibilityChange

        let contentSizeCoordinator = DashboardPopoverContentSizeCoordinator(popover: popover)
        let dashboardHostingController = DashboardPopoverHostingController(
            rootView: DashboardPopoverRootView(
                content: DashboardView(
                    dashboardModel: dashboardModel,
                    preferencesController: preferencesController,
                    audioDashboardModel: audioDashboardModel,
                    openPreferences: { [weak popover] in
                        popover?.performClose(nil)
                        openPreferences()
                    },
                    quitApplication: { [weak popover] in
                        popover?.performClose(nil)
                        quitApplication()
                    }
                )
            )
        )

        dashboardHostingController.sizingOptions = [.preferredContentSize]
        dashboardHostingController.onContentLayoutChange = { [weak dashboardHostingController, weak contentSizeCoordinator] in
            guard let dashboardHostingController else {
                return
            }
            contentSizeCoordinator?.schedule(measuredSize: dashboardHostingController.measuredContentSize())
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = dashboardHostingController
        contentSizeCoordinator.applyImmediately(
            measuredSize: dashboardHostingController.layoutAndMeasureContentSize()
        )

        self.contentSizeCoordinator = contentSizeCoordinator
        self.dashboardHostingController = dashboardHostingController
        super.init()
        popover.delegate = self
    }

    func toggle(relativeTo view: NSView?) {
        guard let view else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            focusController.activateApplication()
            contentSizeCoordinator.applyImmediately(
                measuredSize: dashboardHostingController.layoutAndMeasureContentSize()
            )
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            focusController.focusPresentedPopover(popover)
            onVisibilityChange(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        onVisibilityChange(false)
    }

    #if DEBUG
    var testingAudioDashboardModel: AudioDashboardModel? {
        (popover.contentViewController as? DashboardPopoverHostingController)?.dashboardView.audioDashboardModel
    }
    #endif
}
