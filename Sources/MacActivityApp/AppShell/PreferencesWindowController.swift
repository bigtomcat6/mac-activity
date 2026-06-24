import AppKit
import Combine
import SwiftUI
import MacActivityCore

@MainActor
final class PreferencesWindowController: NSWindowController {
    private var cancellables: Set<AnyCancellable> = []

    init(
        preferencesController: PreferencesController,
        checkForUpdates: @escaping () -> Void
    ) {
        let rootView = PreferencesView(
            preferencesController: preferencesController,
            checkForUpdates: checkForUpdates
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = AppLocalization.string(.preferences)
        window.setContentSize(NSSize(width: 460, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)

        AppLocalizationController.shared.$preferredLanguageIdentifier
            .sink { [weak self] _ in
                self?.window?.title = AppLocalization.string(.preferences)
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
