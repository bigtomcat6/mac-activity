import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardPopoverControllerTests: XCTestCase {
    func testContentSizeCoordinatorUsesFixedWidthAndCapsMeasuredHeight() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        coordinator.applyImmediately(measuredSize: NSSize(width: 200, height: 700))

        XCTAssertEqual(popover.contentSize, NSSize(width: 420, height: 560))
        XCTAssertEqual(popover.contentSizeAssignments, [NSSize(width: 420, height: 560)])
    }

    func testContentSizeCoordinatorCoalescesMeasurementsInOneRunLoopTurn() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        coordinator.schedule(measuredSize: NSSize(width: 420, height: 190))
        coordinator.schedule(measuredSize: NSSize(width: 420, height: 310))
        Self.drainMainRunLoop()

        XCTAssertEqual(popover.contentSizeAssignments, [NSSize(width: 420, height: 310)])
    }

    func testContentSizeCoordinatorIgnoresInvalidAndDuplicateMeasurements() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 240))
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 240))
        coordinator.applyImmediately(measuredSize: NSSize(width: 0, height: 240))
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: CGFloat.nan))
        Self.drainMainRunLoop()

        XCTAssertEqual(popover.contentSizeAssignments, [NSSize(width: 420, height: 240)])
    }

    func testInvalidImmediateMeasurementPreservesPendingScheduledSize() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        coordinator.schedule(measuredSize: NSSize(width: 420, height: 310))
        coordinator.applyImmediately(measuredSize: NSSize(width: 0, height: 240))
        Self.drainMainRunLoop()

        XCTAssertEqual(popover.contentSizeAssignments, [NSSize(width: 420, height: 310)])
    }

    func testVisiblePopoverAnimatesHeightAndSynchronizesContentSizeAtCompletion() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        let initialContentSize = NSSize(width: 420, height: 200)
        let initialFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: initialContentSize))
        window.setFrame(NSRect(x: 100, y: 400, width: initialFrame.width, height: initialFrame.height), display: true)
        coordinator.applyImmediately(measuredSize: initialContentSize)
        XCTAssertEqual(popover.contentSize, initialContentSize)
        let initialMaxY = window.frame.maxY

        let targetContentSize = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: targetContentSize)
        XCTAssertEqual(popover.contentSize, initialContentSize)

        let targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize))
        var observedIntermediateHeights: [CGFloat] = []
        var contentSizeAtFirstIntermediateFrame: NSSize?
        var synchronizedContentSize: NSSize?
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if window.frame.height > initialFrame.height + 1, window.frame.height < targetFrame.height - 1 {
                observedIntermediateHeights.append(window.frame.height)
                if contentSizeAtFirstIntermediateFrame == nil {
                    contentSizeAtFirstIntermediateFrame = popover.contentSize
                }
            }
            if popover.contentSize == targetContentSize {
                synchronizedContentSize = popover.contentSize
                break
            }
        }

        XCTAssertFalse(observedIntermediateHeights.isEmpty, "expected at least one intermediate native window frame")
        XCTAssertEqual(contentSizeAtFirstIntermediateFrame, initialContentSize)
        XCTAssertEqual(synchronizedContentSize, targetContentSize)
        XCTAssertEqual(popover.contentSize, targetContentSize)
        XCTAssertEqual(window.frame.maxY, initialMaxY, accuracy: 1)
    }

    func testShowingPopoverActivatesApplicationAndFocusesPresentedWindow() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let focusController = RecordingDashboardPopoverFocusController(recorder: recorder)
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: focusController,
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { isVisible in
                recorder.record(isVisible ? "visible:true" : "visible:false")
            },
            openPreferences: {},
            quitApplication: {}
        )

        controller.toggle(relativeTo: NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)))

        XCTAssertEqual(recorder.events, [
            "activate-app",
            "show-popover",
            "focus-popover",
            "visible:true"
        ])
    }

    func testClosingShownPopoverDoesNotReactivateApplication() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        popover.isShown = true
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
            openPreferences: {},
            quitApplication: {}
        )

        controller.toggle(relativeTo: NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)))

        XCTAssertEqual(recorder.events, [
            "close-popover"
        ])
    }

    func testToggleWithoutAnchorViewDoesNothing() {
        let recorder = DashboardPopoverEventRecorder()
        let controller = DashboardPopoverController(
            popover: RecordingPopoverHost(recorder: recorder),
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
            openPreferences: {},
            quitApplication: {}
        )

        controller.toggle(relativeTo: nil)

        XCTAssertEqual(recorder.events, [])
    }

    func testPopoverDidCloseReportsVisibilityChange() {
        let recorder = DashboardPopoverEventRecorder()
        let controller = DashboardPopoverController(
            popover: RecordingPopoverHost(recorder: recorder),
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { isVisible in
                recorder.record(isVisible ? "visible:true" : "visible:false")
            },
            openPreferences: {},
            quitApplication: {}
        )

        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))

        XCTAssertEqual(recorder.events, [
            "visible:false"
        ])
    }

    func testDashboardPopoverConfiguresNativeAnimationAndAppliesInitialMeasuredSize() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)

        _ = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
            openPreferences: {},
            quitApplication: {}
        )

        XCTAssertTrue(popover.animates)
        XCTAssertEqual(popover.contentSize.width, DashboardPopoverLayout.contentWidth)
        XCTAssertGreaterThan(popover.contentSize.height, 0)
        XCTAssertLessThanOrEqual(popover.contentSize.height, DashboardPopoverLayout.maximumHeight)
        XCTAssertFalse(popover.contentSizeAssignments.isEmpty)
    }

    func testDashboardPopoverMeasuresBeforeShowing() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
            openPreferences: {},
            quitApplication: {}
        )
        defer { withExtendedLifetime(controller) {} }

        let staleSize = NSSize(width: 100, height: 100)
        popover.contentSize = staleSize

        controller.toggle(relativeTo: NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)))

        XCTAssertNotEqual(popover.contentSizeAtShow, staleSize)
        XCTAssertEqual(popover.contentSizeAtShow, popover.contentSize)
        XCTAssertEqual(popover.contentSizeAtShow?.width, DashboardPopoverLayout.contentWidth)
        XCTAssertGreaterThan(popover.contentSizeAtShow?.height ?? 0, 0)
    }

    func testDashboardPopoverMeasuresNativePreferredContentSizeAtFixedWidth() throws {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
            openPreferences: {},
            quitApplication: {}
        )
        defer { withExtendedLifetime(controller) {} }

        let hostingController = try XCTUnwrap(popover.contentViewController as? DashboardPopoverHostingController)
        let window = NSWindow(contentViewController: hostingController)
        defer { window.close() }
        window.setContentSize(popover.contentSize)
        window.layoutIfNeeded()
        Self.drainMainRunLoop()

        XCTAssertEqual(
            hostingController.preferredContentSize.width,
            DashboardPopoverLayout.contentWidth,
            accuracy: 1
        )
    }

    func testHostedDashboardUpdatesPopoverHeightWhenMetricsAndTabChange() throws {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let store = MetricsStore()
        store.apply([.cpu(CPUReading(usagePercent: 13))], timestamp: Date(timeIntervalSince1970: 31))
        let model = DashboardModel(store: store)

        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: model,
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
            openPreferences: {},
            quitApplication: {}
        )
        defer { withExtendedLifetime(controller) {} }

        let hostingController = try XCTUnwrap(popover.contentViewController as? DashboardPopoverHostingController)
        let window = NSWindow(contentViewController: hostingController)
        defer { window.close() }
        window.setContentSize(popover.contentSize)
        window.layoutIfNeeded()
        Self.drainMainRunLoop()

        let initialHeight = popover.contentSize.height

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 13)),
                .gpu(GPUReading(usagePercent: 35)),
                .disk(DiskReading(usedBytes: 917, totalBytes: 1_000)),
                .swap(SwapReading(usedBytes: 61, totalBytes: 1_000)),
                .memory(MemoryReading(usedBytes: 30, totalBytes: 36)),
                .network(NetworkReading(downloadBytesPerSecond: 221_300, uploadBytesPerSecond: 3_000)),
                .temperature(TemperatureReading(celsius: 55.1, source: .smc)),
                .fan(FanReading(rpm: 2_497)),
                .battery(BatteryReading(percentage: 92, isCharging: true))
            ],
            timestamp: Date(timeIntervalSince1970: 32)
        )

        XCTAssertTrue(Self.waitUntil { popover.contentSize.height > initialHeight })
        let overviewHeight = popover.contentSize.height

        let segmentedControl = try XCTUnwrap(Self.segmentedControl(in: window.contentView))
        segmentedControl.setSelected(true, forSegment: 1)
        _ = segmentedControl.target?.perform(segmentedControl.action, with: segmentedControl)

        XCTAssertTrue(Self.waitUntil { popover.contentSize.height != overviewHeight })
        XCTAssertLessThanOrEqual(popover.contentSize.height, DashboardPopoverLayout.maximumHeight)
    }

    func testHostedDashboardActionsClosePopoverBeforeForwarding() throws {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        var forwardedActions: [String] = []

        _ = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
            openPreferences: { forwardedActions.append("preferences") },
            quitApplication: { forwardedActions.append("quit") }
        )

        let dashboardView = try XCTUnwrap(
            (popover.contentViewController as? DashboardPopoverHostingController)?.dashboardView
        )
        dashboardView.openPreferences()
        dashboardView.quitApplication()

        XCTAssertEqual(recorder.events, ["close-popover", "close-popover"])
        XCTAssertEqual(forwardedActions, ["preferences", "quit"])
    }

    func testPopoverHostCanDeallocateAfterControllerIsReleased() {
        weak var releasedPopover: RecordingPopoverHost?

        autoreleasepool {
            let recorder = DashboardPopoverEventRecorder()
            let popover = RecordingPopoverHost(recorder: recorder)
            let controller = DashboardPopoverController(
                popover: popover,
                focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
                dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
                preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
                onVisibilityChange: { _ in },
                openPreferences: {},
                quitApplication: {}
            )
            releasedPopover = popover

            withExtendedLifetime(controller) {}
        }

        XCTAssertNil(releasedPopover)
    }

    private static func preferencesController() -> PreferencesController {
        PreferencesController(
            store: DashboardPopoverPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
    }

    private static func segmentedControl(in view: NSView?) -> NSSegmentedControl? {
        allSubviews(of: view).first { $0 is NSSegmentedControl } as? NSSegmentedControl
    }

    private static func allSubviews(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap(allSubviews)
    }

    private static func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            drainMainRunLoop()
            drainMainRunLoop()
            if condition() { break }
        }
        return condition()
    }

    private static func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

@MainActor
private final class DashboardPopoverEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

@MainActor
private final class RecordingPopoverHost: DashboardPopoverHosting {
    var behavior: NSPopover.Behavior = .transient
    var animates = false
    private(set) var contentSizeAssignments: [NSSize] = []
    private(set) var contentSizeAtShow: NSSize?
    var contentSize: NSSize = .zero {
        didSet {
            contentSizeAssignments.append(contentSize)
        }
    }
    var contentViewController: NSViewController?
    weak var delegate: NSPopoverDelegate?
    var isShown = false

    private let recorder: DashboardPopoverEventRecorder

    init(recorder: DashboardPopoverEventRecorder) {
        self.recorder = recorder
        self.contentViewController = NSHostingController(rootView: EmptyView())
    }

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        contentSizeAtShow = contentSize
        isShown = true
        recorder.record("show-popover")
    }

    func performClose(_ sender: Any?) {
        isShown = false
        recorder.record("close-popover")
    }
}

@MainActor
private final class RecordingDashboardPopoverFocusController: DashboardPopoverFocusControlling {
    private let recorder: DashboardPopoverEventRecorder

    init(recorder: DashboardPopoverEventRecorder) {
        self.recorder = recorder
    }

    func activateApplication() {
        recorder.record("activate-app")
    }

    func focusPresentedPopover(_ popover: DashboardPopoverHosting) {
        recorder.record("focus-popover")
    }
}

private final class DashboardPopoverPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private var value: AppPreferences

    init(initial: AppPreferences) {
        self.value = initial
    }

    func load() -> AppPreferences {
        value
    }

    func save(_ preferences: AppPreferences) throws {
        value = preferences
    }
}
