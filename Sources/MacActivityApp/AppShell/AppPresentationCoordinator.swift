import AppKit

@MainActor
protocol StatusItemControlling: AnyObject {
    func install()
    func remove()
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
final class AppPresentationCoordinator {
    private let statusItemController: StatusItemControlling
    private let activationController: ApplicationActivationControlling
    private let showPreferences: () -> Void

    init(
        statusItemController: StatusItemControlling,
        activationController: ApplicationActivationControlling,
        showPreferences: @escaping () -> Void
    ) {
        self.statusItemController = statusItemController
        self.activationController = activationController
        self.showPreferences = showPreferences
    }

    func configureInitialState(isMenuBarEnabled: Bool) {
        updateMenuBarVisibility(isMenuBarEnabled)
    }

    func updateMenuBarVisibility(_ isEnabled: Bool) {
        if isEnabled {
            statusItemController.install()
            activationController.applyActivationPolicy(.accessory)
        } else {
            activationController.applyActivationPolicy(.regular)
            statusItemController.remove()
            showPreferences()
        }
    }
}
