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
    static let headerTitleRowHeight: CGFloat = 22
    static let dividerHeight: CGFloat = 1
    static let footerHeight: CGFloat = 56
    static let overviewContentVerticalPadding: CGFloat = 36
    static let emptyStateVerticalPadding: CGFloat = 36

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
        guard let popover, popover.contentSize != contentSize else {
            return
        }
        popover.contentSize = contentSize
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
