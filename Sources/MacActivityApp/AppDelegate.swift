import AppKit
import Combine
import MacActivityCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let metricsStore = MetricsStore()
    private let launchService: LaunchAtLoginServicing = AppDelegate.makeLaunchService()

    private var preferencesController: PreferencesController?
    private var samplingController: AppSamplingController?
    private var summaryModel: StatusSummaryModel?
    private var dashboardModel: DashboardModel?
    private var statusItemController: StatusItemController?
    private var dashboardPopoverController: LazyDashboardPopoverController?
    private var preferencesWindowController: LazyPreferencesWindowController?
    private var presentationCoordinator: AppPresentationCoordinator?
    private var scheduler: MetricsScheduler?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferencesController = PreferencesController(
            store: UserDefaultsPreferencesStore(),
            launchService: launchService
        )
        let summaryModel = StatusSummaryModel(store: metricsStore, preferences: preferencesController)
        let samplingController = AppSamplingController(
            initialLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        let temperatureSourceStore = TemperatureSourceSelectionStore(
            initialSource: preferencesController.state.temperatureSource
        )
        let preferencesWindowController = LazyPreferencesWindowController { [preferencesController] in
            return PreferencesWindowController(
                preferencesController: preferencesController
            )
        }
        let dashboardPopoverController = LazyDashboardPopoverController { [weak self] in
            guard let self else {
                fatalError("Dashboard popover requested after AppDelegate deallocation")
            }

            return self.makeDashboardPopoverController()
        }
        let statusItemController = StatusItemController(
            summaryModel: summaryModel,
            popoverController: dashboardPopoverController
        )
        let presentationCoordinator = AppPresentationCoordinator(
            statusItemController: statusItemController,
            activationController: SharedApplicationActivationController()
        )
        let scheduler = MetricsScheduler(
            providers: [
                CPUProvider(),
                GPUProvider(),
                MemoryProvider(),
                VRAMProvider(),
                NetworkProvider(),
                BatteryProvider(),
                TemperatureProvider(temperatureSourceStore: temperatureSourceStore),
                FanProvider(),
            ],
            store: metricsStore,
            samplingProfile: samplingController.currentProfile
        )

        self.preferencesController = preferencesController
        self.samplingController = samplingController
        self.summaryModel = summaryModel
        self.preferencesWindowController = preferencesWindowController
        self.dashboardPopoverController = dashboardPopoverController
        self.statusItemController = statusItemController
        self.presentationCoordinator = presentationCoordinator
        self.scheduler = scheduler

        samplingController.onProfileChange = { [weak scheduler] (profile: MetricsSamplingProfile) in
            Task {
                await scheduler?.setSamplingProfile(profile)
            }
        }

        if preferencesController.state.launchAtLoginEnabled != launchService.currentStatus() {
            preferencesController.setLaunchAtLoginEnabled(preferencesController.state.launchAtLoginEnabled)
        }

        preferencesController.$state
            .map(\.temperatureSource)
            .removeDuplicates()
            .sink { source in
                Task {
                    await temperatureSourceStore.set(source)
                }
            }
            .store(in: &cancellables)

        metricsStore.$snapshot
            .map { snapshot in
                guard let battery = snapshot.battery else {
                    return false
                }

                return !battery.isCharging
            }
            .removeDuplicates()
            .sink { [weak samplingController] (isRunningOnBattery: Bool) in
                samplingController?.setRunningOnBattery(isRunningOnBattery)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .map { _ in ProcessInfo.processInfo.isLowPowerModeEnabled }
            .removeDuplicates()
            .sink { [weak samplingController] (isLowPowerModeEnabled: Bool) in
                samplingController?.setLowPowerModeEnabled(isLowPowerModeEnabled)
            }
            .store(in: &cancellables)

        presentationCoordinator.configureInitialState()

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

    private func handleDashboardVisibilityChange(_ isVisible: Bool) {
        dashboardModel?.setActive(isVisible)
        samplingController?.setDashboardVisible(isVisible)

        if !isVisible {
            dashboardPopoverController?.reset()
            dashboardModel = nil
        }
    }

    private func makeDashboardPopoverController() -> DashboardPopoverController {
        let dashboardModel = DashboardModel(store: metricsStore, isActive: false)
        self.dashboardModel = dashboardModel

        return DashboardPopoverController(
            dashboardModel: dashboardModel,
            onVisibilityChange: { [weak self] isVisible in
                self?.handleDashboardVisibilityChange(isVisible)
            },
            openPreferences: { [weak self] in
                self?.showPreferences()
            },
            quitApplication: { [weak self] in
                self?.terminateApplication()
            }
        )
    }

    private static func makeLaunchService() -> LaunchAtLoginServicing {
        #if canImport(ServiceManagement)
        return SMAppServiceLaunchAtLoginService()
        #else
        return NoopLaunchAtLoginService()
        #endif
    }
}

@MainActor
final class AppSamplingController {
    private(set) var currentProfile: MetricsSamplingProfile
    var onProfileChange: ((MetricsSamplingProfile) -> Void)?

    private var isDashboardVisible = false
    private var isRunningOnBattery = false
    private var isLowPowerModeEnabled: Bool

    init(initialLowPowerModeEnabled: Bool = false) {
        self.isLowPowerModeEnabled = initialLowPowerModeEnabled
        self.currentProfile = initialLowPowerModeEnabled ? .energySaver : .balanced
    }

    func setDashboardVisible(_ isVisible: Bool) {
        isDashboardVisible = isVisible
        recomputeProfile()
    }

    func setRunningOnBattery(_ isRunningOnBattery: Bool) {
        self.isRunningOnBattery = isRunningOnBattery
        recomputeProfile()
    }

    func setLowPowerModeEnabled(_ isLowPowerModeEnabled: Bool) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        recomputeProfile()
    }

    private func recomputeProfile() {
        let nextProfile: MetricsSamplingProfile
        if isDashboardVisible {
            nextProfile = .realtime
        } else if isRunningOnBattery || isLowPowerModeEnabled {
            nextProfile = .energySaver
        } else {
            nextProfile = .balanced
        }

        guard currentProfile != nextProfile else {
            return
        }

        currentProfile = nextProfile
        onProfileChange?(nextProfile)
    }
}
