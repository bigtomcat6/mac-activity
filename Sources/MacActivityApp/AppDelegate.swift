import AppKit
import Combine
import MacActivityCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let metricsStore = MetricsStore()
    private let launchService: LaunchAtLoginServicing = AppDelegate.makeLaunchService()

    private var preferencesController: PreferencesController?
    private var summaryModel: StatusSummaryModel?
    private var dashboardModel: DashboardModel?
    private var statusItemController: StatusItemController?
    private var dashboardPopoverController: DashboardPopoverController?
    private var preferencesWindowController: PreferencesWindowController?
    private var presentationCoordinator: AppPresentationCoordinator?
    private var scheduler: MetricsScheduler?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferencesController = PreferencesController(
            store: UserDefaultsPreferencesStore(),
            launchService: launchService
        )
        let summaryModel = StatusSummaryModel(store: metricsStore, preferences: preferencesController)
        let dashboardModel = DashboardModel(store: metricsStore)
        let preferencesWindowController = PreferencesWindowController(
            preferencesController: preferencesController,
            metricsStore: metricsStore
        )
        let dashboardPopoverController = DashboardPopoverController(
            dashboardModel: dashboardModel,
            openPreferences: { [weak self] in
                self?.showPreferences()
            },
            quitApplication: { [weak self] in
                self?.terminateApplication()
            }
        )
        let statusItemController = StatusItemController(
            summaryModel: summaryModel,
            popoverController: dashboardPopoverController
        )
        let presentationCoordinator = AppPresentationCoordinator(
            statusItemController: statusItemController,
            activationController: SharedApplicationActivationController(),
            showPreferences: { [weak self] in
                self?.showPreferences()
            }
        )
        let scheduler = MetricsScheduler(
            providers: [
                CPUProvider(),
                MemoryProvider(),
                NetworkProvider(),
                BatteryProvider(),
                TemperatureProvider(),
                FanProvider(),
            ],
            store: metricsStore
        )

        self.preferencesController = preferencesController
        self.summaryModel = summaryModel
        self.dashboardModel = dashboardModel
        self.preferencesWindowController = preferencesWindowController
        self.dashboardPopoverController = dashboardPopoverController
        self.statusItemController = statusItemController
        self.presentationCoordinator = presentationCoordinator
        self.scheduler = scheduler

        if preferencesController.state.launchAtLoginEnabled != launchService.currentStatus() {
            preferencesController.setLaunchAtLoginEnabled(preferencesController.state.launchAtLoginEnabled)
        }

        presentationCoordinator.configureInitialState(
            isMenuBarEnabled: preferencesController.state.isMenuBarEnabled
        )
        preferencesController.$state
            .map(\.isMenuBarEnabled)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] isEnabled in
                self?.presentationCoordinator?.updateMenuBarVisibility(isEnabled)
            }
            .store(in: &cancellables)

        Task {
            await scheduler.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let scheduler = self.scheduler
        Task {
            await scheduler?.stop()
        }
    }

    private func showPreferences() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func terminateApplication() {
        let scheduler = self.scheduler
        Task {
            await scheduler?.stop()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private static func makeLaunchService() -> LaunchAtLoginServicing {
        #if canImport(ServiceManagement)
        return SMAppServiceLaunchAtLoginService()
        #else
        return NoopLaunchAtLoginService()
        #endif
    }
}
