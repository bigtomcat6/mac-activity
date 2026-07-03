import AppKit
import SwiftUI
import MacActivityCore

@MainActor
protocol DashboardPopoverHosting: AnyObject {
    var behavior: NSPopover.Behavior { get set }
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

    static func contentSize(for tab: DashboardTab, metrics: [DashboardMetric]) -> NSSize {
        NSSize(
            width: contentWidth,
            height: min(maximumHeight, contentHeight(for: tab, metrics: metrics))
        )
    }

    static func contentHeight(for tab: DashboardTab, metrics: [DashboardMetric]) -> CGFloat {
        switch tab {
        case .overview:
            return overviewContentHeight(for: metrics) + fixedChromeHeight
        case .actives:
            return maximumHeight
        }
    }

    static func overviewContentHeight(for metrics: [DashboardMetric]) -> CGFloat {
        if metrics.isEmpty {
            return 120 + overviewContentVerticalPadding
        }

        let rowHeights = overviewRowHeights(for: metrics)
        guard !rowHeights.isEmpty else {
            return 120 + overviewContentVerticalPadding
        }

        let rowsHeight = rowHeights.reduce(0, +)
        let spacingHeight = DashboardOverviewLayout.sectionSpacing * CGFloat(max(0, rowHeights.count - 1))
        return rowsHeight + spacingHeight + overviewContentVerticalPadding
    }

    private static var fixedChromeHeight: CGFloat {
        DashboardHeaderChrome.topPadding
            + headerTitleRowHeight
            + DashboardHeaderChrome.bottomPadding
            + footerHeight
            + dividerHeight * 2
    }

    private static func overviewRowHeights(for metrics: [DashboardMetric]) -> [CGFloat] {
        var heights: [CGFloat] = []
        if !DashboardOverviewLayout.topRowSlots(for: metrics).isEmpty {
            heights.append(DashboardOverviewLayout.topRowHeight)
        }
        if DashboardOverviewLayout.secondRowLeadingSlot(for: metrics) != nil ||
            !DashboardOverviewLayout.secondRowTrailingSlots(for: metrics).isEmpty {
            heights.append(DashboardOverviewLayout.secondRowHeight)
        }
        if !DashboardOverviewLayout.thirdRowSlots(for: metrics).isEmpty {
            heights.append(DashboardOverviewLayout.batteryRowHeight)
        }
        return heights
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
final class DashboardPopoverController: NSObject, NSPopoverDelegate {
    private let popover: DashboardPopoverHosting
    private let focusController: DashboardPopoverFocusControlling
    private let onVisibilityChange: (Bool) -> Void

    convenience init(
        dashboardModel: DashboardModel,
        preferencesController: PreferencesController,
        onVisibilityChange: @escaping (Bool) -> Void,
        openPreferences: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.init(
            popover: NSPopover(),
            focusController: SharedDashboardPopoverFocusController(),
            dashboardModel: dashboardModel,
            preferencesController: preferencesController,
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
        onVisibilityChange: @escaping (Bool) -> Void,
        openPreferences: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.popover = popover
        self.focusController = focusController
        self.onVisibilityChange = onVisibilityChange

        popover.behavior = .transient
        let updateContentSize: (DashboardTab, [DashboardMetric]) -> Void = { [weak popover] tab, metrics in
            popover?.contentSize = DashboardPopoverLayout.contentSize(for: tab, metrics: metrics)
        }
        popover.contentSize = DashboardPopoverLayout.contentSize(for: .overview, metrics: dashboardModel.metrics)
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(
                dashboardModel: dashboardModel,
                preferencesController: preferencesController,
                openPreferences: { [weak popover] in
                    popover?.performClose(nil)
                    openPreferences()
                },
                quitApplication: { [weak popover] in
                    popover?.performClose(nil)
                    quitApplication()
                },
                onPreferredContentSizeChange: updateContentSize
            )
        )
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
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            focusController.focusPresentedPopover(popover)
            onVisibilityChange(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        onVisibilityChange(false)
    }
}
