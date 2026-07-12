import AppKit
import Combine
import MacActivityCore

@MainActor
protocol UpdateChecking: AnyObject {
    func checkForUpdates() -> Bool
}

extension SparkleUpdateController: UpdateChecking {}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let releasesURL = URL(string: "https://github.com/bigtomcat6/mac-activity/releases")!

    private let metricsStore = MetricsStore()
    private let launchService: LaunchAtLoginServicing = AppDelegate.makeLaunchService()
    private let releasePageOpener: (URL) -> Void
    #if DEBUG
    private let injectedAudioShutdown: (@MainActor () async -> Void)?
    private let injectedSchedulerStop: (@MainActor () async -> Void)?
    private let terminationReply: (@MainActor (Bool) -> Void)?
    #endif

    private var preferencesController: PreferencesController?
    private var samplingController: AppSamplingController?
    private var summaryModel: StatusSummaryModel?
    private var dashboardModel: DashboardModel?
    private var statusItemController: StatusItemController?
    private var dashboardPopoverController: LazyDashboardPopoverController?
    private var preferencesWindowController: LazyPreferencesWindowController?
    private var presentationCoordinator: AppPresentationCoordinator?
    private var sparkleUpdateController: UpdateChecking?
    private var scheduler: MetricsScheduler?
    private var audioControlCoordinator: AudioControlCoordinator?
    private var schedulerStartupTask: Task<Void, Never>?
    private var audioStartupTask: Task<Void, Never>?
    #if DEBUG
    private var testingAudioControlCoordinator: (any AudioControlCoordinating)?
    private var testingResolvedDashboardPopoverController: DashboardPopoverController?
    #endif
    private var isPreparingForTermination = false
    private var didPrepareForTermination = false
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        self.releasePageOpener = { url in
            NSWorkspace.shared.open(url)
        }
        #if DEBUG
        self.injectedAudioShutdown = nil
        self.injectedSchedulerStop = nil
        self.terminationReply = nil
        #endif
        super.init()
    }

    init(
        sparkleUpdateController: UpdateChecking? = nil,
        releasePageOpener: @escaping (URL) -> Void
    ) {
        self.sparkleUpdateController = sparkleUpdateController
        self.releasePageOpener = releasePageOpener
        #if DEBUG
        self.injectedAudioShutdown = nil
        self.injectedSchedulerStop = nil
        self.terminationReply = nil
        #endif
        super.init()
    }

    #if DEBUG
    init(
        sparkleUpdateController: UpdateChecking? = nil,
        releasePageOpener: @escaping (URL) -> Void,
        audioShutdown: (@MainActor () async -> Void)? = nil,
        schedulerStop: (@MainActor () async -> Void)? = nil,
        terminationReply: (@MainActor (Bool) -> Void)? = nil
    ) {
        self.sparkleUpdateController = sparkleUpdateController
        self.releasePageOpener = releasePageOpener
        self.injectedAudioShutdown = audioShutdown
        self.injectedSchedulerStop = schedulerStop
        self.terminationReply = terminationReply
        super.init()
    }
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferencesController = PreferencesController(
            store: UserDefaultsPreferencesStore(),
            launchService: launchService
        )
        AppLocalizationController.shared.applyPreferredLanguageIdentifier(
            preferencesController.state.preferredLanguageIdentifier
        )
        let sparkleUpdateController = SparkleUpdateController(preferencesController: preferencesController)
        let summaryModel = StatusSummaryModel(store: metricsStore, preferences: preferencesController)
        let samplingController = AppSamplingController(
            initialLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
        let audioControlCoordinator = Self.makeAudioCoordinator(preferencesController: preferencesController)
        let checkForUpdates = makeCheckForUpdatesAction()
        let preferencesWindowController = LazyPreferencesWindowController { [preferencesController, checkForUpdates] in
            return PreferencesWindowController(
                preferencesController: preferencesController,
                checkForUpdates: checkForUpdates
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
                DiskProvider(),
                SwapProvider(),
                MemoryProvider(),
                VRAMProvider(),
                NetworkProvider(),
                BatteryProvider(),
                TemperatureProvider(),
                FanProvider()
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
        self.sparkleUpdateController = sparkleUpdateController
        self.scheduler = scheduler
        self.audioControlCoordinator = audioControlCoordinator

        samplingController.onProfileChange = { [weak scheduler] (profile: MetricsSamplingProfile) in
            Task {
                await scheduler?.setSamplingProfile(profile)
            }
        }

        if preferencesController.state.launchAtLoginEnabled != launchService.currentStatus() {
            preferencesController.setLaunchAtLoginEnabled(preferencesController.state.launchAtLoginEnabled)
        }

        preferencesController.$state
            .map(\.preferredLanguageIdentifier)
            .removeDuplicates()
            .sink { preferredLanguageIdentifier in
                AppLocalizationController.shared.applyPreferredLanguageIdentifier(preferredLanguageIdentifier)
            }
            .store(in: &cancellables)

        metricsStore.$snapshot
            .map { snapshot in
                guard let battery = snapshot.battery else {
                    return false
                }

                return !battery.isConnectedToPower
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

        startOwnedLifecycles(
            audioControlCoordinator: audioControlCoordinator,
            scheduler: scheduler
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancellables.removeAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if didPrepareForTermination { return .terminateNow }
        guard isPreparingForTermination == false else { return .terminateLater }
        isPreparingForTermination = true

        let audioControlCoordinator = self.audioControlCoordinator
        let scheduler = self.scheduler
        let audioStartupTask = self.audioStartupTask
        let schedulerStartupTask = self.schedulerStartupTask
        #if DEBUG
        let audioShutdown = injectedAudioShutdown
        let schedulerStop = injectedSchedulerStop
        let terminationReply = self.terminationReply
        #endif
        Task { @MainActor [weak self] in
            audioStartupTask?.cancel()
            schedulerStartupTask?.cancel()
            await audioStartupTask?.value
            await schedulerStartupTask?.value
            self?.audioStartupTask = nil
            self?.schedulerStartupTask = nil
            #if DEBUG
            if let audioShutdown {
                await audioShutdown()
            } else {
                await audioControlCoordinator?.shutdown()
            }
            if let schedulerStop {
                await schedulerStop()
            } else {
                await scheduler?.stop()
            }
            #else
            await audioControlCoordinator?.shutdown()
            await scheduler?.stop()
            #endif
            self?.didPrepareForTermination = true
            self?.isPreparingForTermination = false
            #if DEBUG
            if let terminationReply {
                terminationReply(true)
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
            #else
            sender.reply(toApplicationShouldTerminate: true)
            #endif
        }
        return .terminateLater
    }

    private func showPreferences() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func checkForUpdates() {
        if sparkleUpdateController?.checkForUpdates() == true {
            return
        }

        releasePageOpener(Self.releasesURL)
    }

    func makeCheckForUpdatesAction() -> () -> Void {
        { [weak self] in
            self?.checkForUpdates()
        }
    }

    private func terminateApplication() {
        NSApplication.shared.terminate(nil)
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
        guard let preferencesController else {
            fatalError("Dashboard requested before preferences were configured")
        }

        let dashboardModel = DashboardModel(
            store: metricsStore,
            preferences: preferencesController,
            isActive: false
        )
        self.dashboardModel = dashboardModel

        return DashboardPopoverController(
            dashboardModel: dashboardModel,
            preferencesController: preferencesController,
            audioDashboardModel: makeAudioDashboardModel(),
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

    private func makeAudioDashboardModel() -> AudioDashboardModel {
        #if DEBUG
        if let testingAudioControlCoordinator {
            return AudioDashboardModel(coordinator: testingAudioControlCoordinator)
        }
        #endif
        guard let audioControlCoordinator else {
            fatalError("Dashboard requested before audio control was configured")
        }
        return AudioDashboardModel(coordinator: audioControlCoordinator)
    }

    private func startOwnedLifecycles(
        audioControlCoordinator: AudioControlCoordinator,
        scheduler: MetricsScheduler
    ) {
        schedulerStartupTask = Task {
            await scheduler.start()
        }
        audioStartupTask = Task {
            await audioControlCoordinator.start()
        }
    }

    #if DEBUG
    func testingStartOwnedLifecycles(
        audioControlCoordinator: AudioControlCoordinator,
        scheduler: MetricsScheduler
    ) {
        self.audioControlCoordinator = audioControlCoordinator
        self.scheduler = scheduler
        startOwnedLifecycles(
            audioControlCoordinator: audioControlCoordinator,
            scheduler: scheduler
        )
    }

    func testingConfigureDashboardPopoverFactory(
        preferencesController: PreferencesController,
        audioControlCoordinator: any AudioControlCoordinating
    ) {
        self.preferencesController = preferencesController
        self.testingAudioControlCoordinator = audioControlCoordinator
        self.dashboardPopoverController = LazyDashboardPopoverController { [weak self] in
            guard let self else {
                fatalError("Dashboard popover requested after AppDelegate deallocation")
            }
            let controller = self.makeDashboardPopoverController()
            self.testingResolvedDashboardPopoverController = controller
            return controller
        }
    }

    func testingResolveDashboardPopoverController() -> DashboardPopoverController {
        testingResolvedDashboardPopoverController = nil
        dashboardPopoverController?.toggle(relativeTo: nil)
        guard let testingResolvedDashboardPopoverController else {
            fatalError("Dashboard popover test factory was not configured")
        }
        return testingResolvedDashboardPopoverController
    }
    #endif

    private static func makeAudioCoordinator(
        preferencesController: PreferencesController
    ) -> AudioControlCoordinator {
        let audioDeviceService = AudioDeviceVolumeService()
        return AudioControlCoordinator(
            deviceProvider: audioDeviceService,
            processProvider: AudioProcessService(),
            routeDeviceProvider: audioDeviceService,
            monitor: AudioSystemMonitor(),
            planner: AudioRoutePlanner(),
            engine: ProcessTapVolumeEngine(),
            preferences: preferencesController
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
        self.currentProfile = initialLowPowerModeEnabled ? .energySaver : .background
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
            nextProfile = .background
        }

        guard currentProfile != nextProfile else {
            return
        }

        currentProfile = nextProfile
        onProfileChange?(nextProfile)
    }
}
