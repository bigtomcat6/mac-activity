import AppKit
import SwiftUI
import MacActivityCore

@MainActor
final class PreferencesWindowController: NSWindowController {
    init(
        preferencesController: PreferencesController,
        metricsStore: MetricsStore
    ) {
        let rootView = PreferencesView(
            preferencesController: preferencesController,
            metricsStore: metricsStore
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Preferences"
        window.setContentSize(NSSize(width: 460, height: 520))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
