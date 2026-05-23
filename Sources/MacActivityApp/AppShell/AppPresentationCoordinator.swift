import AppKit

@MainActor
protocol StatusItemControlling: AnyObject {
    func install()
}

extension StatusItemController: StatusItemControlling {}

@MainActor
protocol ApplicationActivationControlling: AnyObject {
    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy)
}

@MainActor
final class SharedApplicationActivationController: ApplicationActivationControlling {
    func applyActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApplication.shared.setActivationPolicy(policy)
    }
}

@MainActor
protocol DashboardPopoverControlling: AnyObject {
    func toggle(relativeTo view: NSView?)
}

extension DashboardPopoverController: DashboardPopoverControlling {}

@MainActor
final class LazyDashboardPopoverController: DashboardPopoverControlling {
    private let factory: () -> DashboardPopoverControlling
    private var controller: DashboardPopoverControlling?

    init(factory: @escaping () -> DashboardPopoverControlling) {
        self.factory = factory
    }

    func toggle(relativeTo view: NSView?) {
        resolvedController().toggle(relativeTo: view)
    }

    func reset() {
        controller = nil
    }

    private func resolvedController() -> DashboardPopoverControlling {
        if let controller {
            return controller
        }

        let controller = factory()
        self.controller = controller
        return controller
    }
}

@MainActor
protocol PreferencesWindowControlling: AnyObject {
    var window: NSWindow? { get }
    func showWindow(_ sender: Any?)
}

extension PreferencesWindowController: PreferencesWindowControlling {}

@MainActor
final class LazyPreferencesWindowController: PreferencesWindowControlling {
    private let factory: () -> PreferencesWindowControlling
    private var controller: PreferencesWindowControlling?

    init(factory: @escaping () -> PreferencesWindowControlling) {
        self.factory = factory
    }

    var window: NSWindow? {
        controller?.window
    }

    func showWindow(_ sender: Any?) {
        resolvedController().showWindow(sender)
    }

    private func resolvedController() -> PreferencesWindowControlling {
        if let controller {
            return controller
        }

        let controller = factory()
        self.controller = controller
        return controller
    }
}

@MainActor
final class AppPresentationCoordinator {
    private let statusItemController: StatusItemControlling
    private let activationController: ApplicationActivationControlling

    init(
        statusItemController: StatusItemControlling,
        activationController: ApplicationActivationControlling
    ) {
        self.statusItemController = statusItemController
        self.activationController = activationController
    }

    func configureInitialState() {
        statusItemController.install()
        activationController.applyActivationPolicy(.accessory)
    }
}
