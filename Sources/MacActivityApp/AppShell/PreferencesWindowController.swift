import AppKit
import SwiftUI
import MacActivityCore

@MainActor
final class PreferencesWindowController: NSWindowController {
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
        let hostingController = NSHostingController(rootView: rootView)
        // Explicit host constraints, not scrolling content, define the window's limits.
        hostingController.sizingOptions = []
        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.setAccessibilityLabel(AppLocalization.string(.appName))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        // Native unified chrome extends the sidebar behind the inset window controls.
        let toolbar = NSToolbar(identifier: "PreferencesWindow")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        NSLayoutConstraint.activate([
            hostingController.view.widthAnchor.constraint(equalToConstant: 723),
            hostingController.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 470)
        ])
        window.collectionBehavior.insert(.fullScreenNone)
        window.setContentSize(NSSize(width: 723, height: 600))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
