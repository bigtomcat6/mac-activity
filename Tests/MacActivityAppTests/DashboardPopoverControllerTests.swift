import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardPopoverControllerTests: XCTestCase {
    func testShowingPopoverActivatesApplicationAndFocusesPresentedWindow() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let focusController = RecordingDashboardPopoverFocusController(recorder: recorder)
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: focusController,
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
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

    func testOverviewPopoverHeightFitsOverviewContentInsteadOfFixedTallFrame() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let store = MetricsStore()
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
            timestamp: Date(timeIntervalSince1970: 30)
        )

        _ = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: store),
            preferencesController: Self.preferencesController(),
            onVisibilityChange: { _ in },
            openPreferences: {},
            quitApplication: {}
        )

        XCTAssertEqual(popover.contentSize.width, 420)
        XCTAssertEqual(popover.contentSize.height, 524)
        XCTAssertLessThan(popover.contentSize.height, 560)
    }

    func testPopoverLayoutUsesMaximumHeightForActivesAndFallbackOverviewRows() {
        XCTAssertEqual(
            DashboardPopoverLayout.contentSize(for: .actives, metrics: []).height,
            DashboardPopoverLayout.maximumHeight
        )
        XCTAssertEqual(
            DashboardPopoverLayout.contentSize(for: .audio, metrics: []).height,
            DashboardPopoverLayout.maximumHeight
        )
        XCTAssertEqual(
            DashboardPopoverLayout.overviewContentHeight(for: []),
            120
                + DashboardPopoverLayout.emptyStateVerticalPadding
                + DashboardPopoverLayout.overviewContentVerticalPadding
        )
        XCTAssertEqual(
            DashboardPopoverLayout.overviewContentHeight(for: [
                DashboardMetric(kind: .vram, title: "VRAM", value: "Collecting")
            ]),
            120 + DashboardPopoverLayout.overviewContentVerticalPadding
        )
    }

    func testHostedDashboardUpdatesPopoverHeightWhenMetricsAndTabChange() throws {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let store = MetricsStore()
        store.apply([.cpu(CPUReading(usagePercent: 13))], timestamp: Date(timeIntervalSince1970: 31))
        let model = DashboardModel(store: store)

        _ = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: model,
            preferencesController: Self.preferencesController(),
            onVisibilityChange: { _ in },
            openPreferences: {},
            quitApplication: {}
        )

        let hostingController = try XCTUnwrap(popover.contentViewController as? NSHostingController<DashboardView>)
        let window = NSWindow(contentViewController: hostingController)
        defer { window.close() }
        window.setContentSize(popover.contentSize)
        window.layoutIfNeeded()
        Self.drainMainRunLoop()

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
        XCTAssertTrue(Self.waitUntil { popover.contentSize.height == 524 })

        let segmentedControl = try XCTUnwrap(Self.segmentedControl(in: window.contentView))
        segmentedControl.setSelected(true, forSegment: 1)
        _ = segmentedControl.target?.perform(segmentedControl.action, with: segmentedControl)

        XCTAssertTrue(Self.waitUntil { popover.contentSize.height == DashboardPopoverLayout.maximumHeight })
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
            onVisibilityChange: { _ in },
            openPreferences: { forwardedActions.append("preferences") },
            quitApplication: { forwardedActions.append("quit") }
        )

        let dashboardView = try XCTUnwrap(
            (popover.contentViewController as? NSHostingController<DashboardView>)?.rootView
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
    var contentSize: NSSize = .zero
    var contentViewController: NSViewController?
    weak var delegate: NSPopoverDelegate?
    var isShown = false

    private let recorder: DashboardPopoverEventRecorder

    init(recorder: DashboardPopoverEventRecorder) {
        self.recorder = recorder
        self.contentViewController = NSHostingController(rootView: EmptyView())
    }

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
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
