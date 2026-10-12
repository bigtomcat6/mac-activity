import SwiftUI

/// Whether the dashboard popover is on screen; pages gate polling and refreshes on it.
@MainActor
final class DashboardPresentationState: ObservableObject {
    @Published private(set) var isPresented = false

    func setPresented(_ isPresented: Bool) {
        guard self.isPresented != isPresented else { return }
        self.isPresented = isPresented
    }
}

private struct DashboardIsPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var dashboardPresentationIsPresented: Bool {
        get { self[DashboardIsPresentedKey.self] }
        set { self[DashboardIsPresentedKey.self] = newValue }
    }
}
