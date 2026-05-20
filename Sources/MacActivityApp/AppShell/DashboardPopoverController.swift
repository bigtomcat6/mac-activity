import AppKit
import SwiftUI
import MacActivityCore

@MainActor
final class DashboardPopoverController {
    private let popover: NSPopover

    init(
        dashboardModel: DashboardModel,
        openPreferences: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
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
    }

    func toggle(relativeTo view: NSView?) {
        guard let view else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}
