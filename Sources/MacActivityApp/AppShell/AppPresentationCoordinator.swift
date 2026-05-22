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
