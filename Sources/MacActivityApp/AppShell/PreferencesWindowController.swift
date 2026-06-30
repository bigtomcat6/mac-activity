import AppKit
import Combine
import SwiftUI
import MacActivityCore

@MainActor
final class PreferencesWindowController: NSWindowController {
    private var cancellables: Set<AnyCancellable> = []
    private let viewState = PreferencesViewState()

    init(
        preferencesController: PreferencesController,
        checkForUpdates: @escaping () -> Void
    ) {
        let rootView = PreferencesView(
            preferencesController: preferencesController,
            viewState: viewState,
            checkForUpdates: checkForUpdates
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: rootView))
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

    override func showWindow(_ sender: Any?) {
        viewState.collapseUpdateChannel()
        super.showWindow(sender)
    }
}
