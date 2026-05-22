import AppKit
import SwiftUI
import MacActivityCore

@MainActor
final class DashboardPopoverController: NSObject, NSPopoverDelegate {
    private let popover: NSPopover
    private let onVisibilityChange: (Bool) -> Void

    init(
        dashboardModel: DashboardModel,
        onVisibilityChange: @escaping (Bool) -> Void,
        openPreferences: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.onVisibilityChange = onVisibilityChange

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(
                dashboardModel: dashboardModel,
                openPreferences: {
                    popover.performClose(nil)
                    openPreferences()
                },
                quitApplication: {
                    popover.performClose(nil)
                    quitApplication()
                }
            )
        )
        self.popover = popover
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
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            onVisibilityChange(true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        onVisibilityChange(false)
    }
}
