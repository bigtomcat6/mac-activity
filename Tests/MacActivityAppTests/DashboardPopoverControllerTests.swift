import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardPopoverControllerTests: XCTestCase {
    private func makeFadeAnchor() throws -> (NSWindow, NSView) {
        let screen = try XCTUnwrap(NSScreen.main)
        let frame = NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY - 32, width: 80, height: 32)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 8, y: 4, width: 24, height: 24))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        return (window, anchor)
    }

    func testAudioActivationDuringPanelFadeOutDoesNotRefreshOrShutdownEngine() async throws {
        var completions: [@MainActor () -> Void] = []
        let panelHost = DashboardPanelHost(shouldReduceMotion: { false }, animateAlpha: { _, _, _, completion in
            completions.append(completion)
        })
        defer { panelHost.destroy() }
        let host = DashboardAdaptivePopoverHost(hostKindProvider: { .panel }, panelHost: panelHost)
        let audioCoordinator = TestAudioControlCoordinator()
        let audio = AudioDashboardModel(coordinator: audioCoordinator)
        let state = DashboardPresentationState()
        var visibility: [Bool] = []
        let controller = DashboardPopoverController(popover: host,
            focusController: RecordingDashboardPopoverFocusController(recorder: DashboardPopoverEventRecorder()),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(), audioDashboardModel: audio,
            onVisibilityChange: { visibility.append($0) }, presentationState: state)
        let (window, anchor) = try makeFadeAnchor()
        defer { window.close() }
        controller.toggle(relativeTo: anchor)
        await audio.audioPageActivated()
        let calls = audioCoordinator.refreshSystemAudioAuthorizationCallCount
        controller.toggle(relativeTo: anchor)
        XCTAssertTrue(panelHost.isVisible)
        XCTAssertFalse(host.isShown)
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(visibility, [true, false])
        await audio.applicationDidBecomeActive()
        XCTAssertEqual(audioCoordinator.refreshSystemAudioAuthorizationCallCount, calls)
        XCTAssertEqual(audioCoordinator.shutdownCallCount, 0)
        completions.last?()
        XCTAssertFalse(panelHost.isVisible)
    }

    func testVisibilityCloseCallbackReopenDoesNotClearNewPresentation() throws {
        var completions: [@MainActor () -> Void] = []
        let panelHost = DashboardPanelHost(shouldReduceMotion: { false }, animateAlpha: { _, _, _, completion in
            completions.append(completion)
        })
        defer { panelHost.destroy() }
        let host = DashboardAdaptivePopoverHost(hostKindProvider: { .panel }, panelHost: panelHost)
        let state = DashboardPresentationState()
        let (window, anchor) = try makeFadeAnchor()
        defer { window.close() }
        var visibility: [Bool] = []
        weak var callbackController: DashboardPopoverController?
        let controller = DashboardPopoverController(popover: host,
            focusController: RecordingDashboardPopoverFocusController(recorder: DashboardPopoverEventRecorder()),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { visible in
                visibility.append(visible)
                if !visible && visibility.count == 2 { callbackController?.toggle(relativeTo: anchor) }
            }, presentationState: state)
        callbackController = controller
        controller.toggle(relativeTo: anchor)
        controller.toggle(relativeTo: anchor)
        XCTAssertTrue(host.isShown)
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(visibility, [true, false, true])
        completions.first?()
        XCTAssertTrue(host.isShown)
        XCTAssertTrue(state.isPresented)
        callbackController = nil
        host.performClose(nil)
    }

    func testControllerDeallocationInvalidatesShownAdaptiveHostAndPresentation() throws {
        var completions: [@MainActor () -> Void] = []
        let panelHost = DashboardPanelHost(shouldReduceMotion: { false }, animateAlpha: { _, _, _, completion in
            completions.append(completion)
        })
        defer { panelHost.destroy() }
        let host = DashboardAdaptivePopoverHost(hostKindProvider: { .panel }, panelHost: panelHost)
        let state = DashboardPresentationState()
        let (window, anchor) = try makeFadeAnchor()
        defer { window.close() }
        weak var released: DashboardPopoverController?
        autoreleasepool {
            let controller = DashboardPopoverController(popover: host,
                focusController: RecordingDashboardPopoverFocusController(recorder: DashboardPopoverEventRecorder()),
                dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
                preferencesController: Self.preferencesController(),
                audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
                onVisibilityChange: { _ in }, presentationState: state)
            controller.toggle(relativeTo: anchor)
            XCTAssertTrue(host.isShown)
            released = controller
        }
        XCTAssertNil(released)
        released = nil
        XCTAssertTrue(Self.waitUntil { !host.isShown }, "main-actor deallocation cleanup must run")
        completions.forEach { $0() }
        XCTAssertFalse(host.isShown)
        XCTAssertNil(panelHost.panel)
        XCTAssertFalse(state.isPresented)
    }

    func testDefaultOwnedHostReleaseStillClosesRetainedLogicalModels() async throws {
        let state = DashboardPresentationState()
        let coordinator = TestAudioControlCoordinator()
        let audio = AudioDashboardModel(coordinator: coordinator)
        let model = DashboardModel(store: MetricsStore(), isActive: false)
        var visibility: [Bool] = []
        var samplingVisible = false
        weak var releasedHost: DashboardAdaptivePopoverHost?
        let (window, anchor) = try makeFadeAnchor()
        defer { window.close() }
        var controller: DashboardPopoverController? = autoreleasepool {
            let host = DashboardAdaptivePopoverHost()
            releasedHost = host
            return DashboardPopoverController(popover: host,
                focusController: RecordingDashboardPopoverFocusController(recorder: DashboardPopoverEventRecorder()),
                dashboardModel: model, preferencesController: Self.preferencesController(),
                audioDashboardModel: audio, onVisibilityChange: {
                    visibility.append($0)
                    model.setActive($0)
                    samplingVisible = $0
                }, presentationState: state)
        }
        controller?.toggle(relativeTo: anchor)
        XCTAssertTrue(state.isPresented)
        await audio.audioPageActivated()
        let refreshes = coordinator.refreshSystemAudioAuthorizationCallCount
        weak var releasedController = controller
        autoreleasepool { controller = nil }
        XCTAssertNil(releasedController)
        releasedController = nil
        XCTAssertNil(releasedHost, "queued logical cleanup must not retain the controller-owned host")
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && (state.isPresented || visibility != [true, false]) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(visibility, [true, false])
        XCTAssertFalse(samplingVisible)
        XCTAssertTrue(model.metrics.isEmpty)
        await audio.applicationDidBecomeActive()
        XCTAssertEqual(coordinator.refreshSystemAudioAuthorizationCallCount, refreshes)
        XCTAssertEqual(coordinator.shutdownCallCount, 0)
    }

    func testSameHostSuccessorRejectsOldCleanupAndQueuedHeightWork() async throws {
        let host = DashboardAdaptivePopoverHost(hostKindProvider: { .panel })
        defer { host.invalidate() }
        let state = DashboardPresentationState()
        let audioCoordinator = TestAudioControlCoordinator()
        let audio = AudioDashboardModel(coordinator: audioCoordinator)
        let model = DashboardModel(store: MetricsStore(), isActive: false)
        var visibility: [Bool] = []
        let (window, anchor) = try makeFadeAnchor()
        defer { window.close() }
        func makeController() -> DashboardPopoverController {
            DashboardPopoverController(popover: host,
                focusController: RecordingDashboardPopoverFocusController(recorder: DashboardPopoverEventRecorder()),
                dashboardModel: model, preferencesController: Self.preferencesController(), audioDashboardModel: audio,
                onVisibilityChange: { visibility.append($0) }, presentationState: state)
        }
        var old: DashboardPopoverController? = makeController()
        old?.toggle(relativeTo: anchor)
        let oldCoordinator = try XCTUnwrap(old?.testingContentSizeCoordinator)
        let successor = makeController()
        // The new root replaced the old one on the SAME physical host.
        host.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        successor.toggle(relativeTo: anchor)
        successor.toggle(relativeTo: anchor)
        let panel = try XCTUnwrap(host.panelForTesting)
        let size = host.contentSize
        successor.testingScrollIndicatorState.setHeightTransitioning(true)
        await audio.audioPageActivated()
        let refreshes = audioCoordinator.refreshSystemAudioAuthorizationCallCount
        oldCoordinator.schedule(measuredSize: NSSize(width: 420, height: 111))
        autoreleasepool { old = nil }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { continuation.resume() }
        }
        XCTAssertTrue(host.isShown)
        XCTAssertTrue(host.panelForTesting === panel)
        XCTAssertTrue(state.isPresented)
        XCTAssertEqual(visibility, [true, true], "old false must not close the successor's model/sampling gate")
        XCTAssertEqual(host.contentSize, size, "queued old-root height work must not resize the new root")
        XCTAssertTrue(successor.testingScrollIndicatorState.isHeightTransitioning)
        await audio.applicationDidBecomeActive()
        XCTAssertEqual(audioCoordinator.refreshSystemAudioAuthorizationCallCount, refreshes + 1)
        XCTAssertEqual(audioCoordinator.shutdownCallCount, 0)
        withExtendedLifetime(successor) {}
    }

    func testHeightCompletionFromReplacedRootDoesNotApplyOldSize() throws {
        let host = RecordingPopoverHost(recorder: DashboardPopoverEventRecorder())
        let root = NSViewController()
        let window = NSWindow(contentViewController: root)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        host.contentViewController = root
        host.isShown = true
        host.contentSize = NSSize(width: 420, height: 200)
        var completion: (@MainActor () -> Void)?
        let coordinator = DashboardPopoverContentSizeCoordinator(popover: host, shouldReduceMotion: { false },
            visibleFrameForWindow: { _ in nil }, animateFrame: { _, _, finish in completion = finish })
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 400))
        let finish = try XCTUnwrap(completion)
        host.contentViewController = NSViewController()
        host.contentSize = NSSize(width: 420, height: 300)
        finish()
        XCTAssertEqual(host.contentSize, NSSize(width: 420, height: 300))
    }

    func testControllerReleaseForcesDirectNativePopoverAndNestedInfoClosed() throws {
        let popover = NSPopover()
        let state = DashboardPresentationState()
        var visibility: [Bool] = []
        let (window, anchor) = try makeFadeAnchor()
        defer { window.close(); popover.close() }
        var controller: DashboardPopoverController? = DashboardPopoverController(popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: DashboardPopoverEventRecorder()),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { visibility.append($0) }, presentationState: state)
        popover.animates = false
        controller?.toggle(relativeTo: anchor)
        let root = try XCTUnwrap(popover.contentViewController)
        let parentWindow = try XCTUnwrap(root.view.window)
        let infoAnchor = NSView(frame: NSRect(x: 20, y: 20, width: 24, height: 24))
        root.view.addSubview(infoAnchor)
        let info = NSPopover()
        info.behavior = .applicationDefined
        info.animates = false
        info.contentViewController = NSHostingController(rootView: Text("nested info"))
        info.contentSize = NSSize(width: 180, height: 80)
        defer { info.close() }
        info.show(relativeTo: infoAnchor.bounds, of: infoAnchor, preferredEdge: .maxX)
        let childWindow = try XCTUnwrap(info.contentViewController?.view.window)
        XCTAssertTrue(info.isShown)
        XCTAssertTrue(childWindow.parent === parentWindow)
        autoreleasepool { controller = nil }
        XCTAssertTrue(Self.waitUntil { visibility == [true, false] })
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(popover.isShown)
        XCTAssertFalse(parentWindow.isVisible)
        XCTAssertFalse(info.isShown)
        XCTAssertFalse(childWindow.isVisible)
    }

    func testCloseIntentStopsPresentationAndVisibilityBeforeDelayedDidClose() {
        let recorder = DashboardPopoverEventRecorder()
        let host = RecordingPopoverHost(recorder: recorder)
        host.delaysDidClose = true
        let state = DashboardPresentationState()
        var visibility: [Bool] = []
        let controller = DashboardPopoverController(popover: host,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { visibility.append($0) }, presentationState: state)
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        controller.toggle(relativeTo: anchor)
        controller.testingScrollIndicatorState.setHeightTransitioning(true)
        controller.toggle(relativeTo: anchor)
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(controller.testingScrollIndicatorState.isHeightTransitioning)
        XCTAssertEqual(visibility, [true, false])
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertEqual(visibility, [true, false])
    }

    func testExternalWillCloseStopsPresentationWithoutWaitingForDidClose() {
        let recorder = DashboardPopoverEventRecorder()
        let host = RecordingPopoverHost(recorder: recorder)
        let state = DashboardPresentationState()
        var visibility: [Bool] = []
        let controller = DashboardPopoverController(popover: host,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { visibility.append($0) }, presentationState: state)
        controller.toggle(relativeTo: NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24)))
        host.delegate?.popoverWillClose?(Notification(name: NSPopover.willCloseNotification, object: host))
        XCTAssertFalse(state.isPresented)
        XCTAssertEqual(visibility, [true, false])
    }

    func testQueuedFocusDoesNotReopenClosedWindowOrFocusReplacement() {
        let host = RecordingPopoverHost(recorder: DashboardPopoverEventRecorder())
        let content = NSViewController()
        host.contentViewController = content
        let window = NSWindow(contentViewController: content)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        host.isShown = true
        let focus = SharedDashboardPopoverFocusController()
        focus.focusPresentedPopover(host)
        host.isShown = false
        window.orderOut(nil)
        Self.drainMainRunLoop()
        XCTAssertFalse(window.isVisible, "queued focus must not order a closed host back in")
        host.isShown = true
        window.orderFront(nil)
        focus.focusPresentedPopover(host)
        let replacement = NSWindow(contentViewController: NSViewController())
        replacement.isReleasedWhenClosed = false
        defer { replacement.close() }
        host.contentViewController = replacement.contentViewController
        Self.drainMainRunLoop()
        XCTAssertFalse(replacement.isVisible, "the old focus request must not order a replacement window in")
    }
    // Existing coordinator signals must reach the real Dashboard native consumers.
    func testIntegratedLongDashboardRestoresIndicatorsAcrossRetargetCancelCloseAndSnap() throws {
        let state = DashboardPopoverScrollIndicatorState()
        let devices = (0..<20).map { index in
            AudioDeviceControlSnapshot(device: AudioOutputDeviceSnapshot(id: "Output \(index)",
                objectID: UInt32(index + 10), name: "Output \(index)",
                volume: .value(0.5, isWritable: true), mute: .value(false, isWritable: true)), error: nil)
        }
        let host = DashboardListTestHost(DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: PreferencesController(store: PreferencesStoreFake(), launchService: NoopLaunchAtLoginService()),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator(
                snapshot: AudioControlSnapshot(devices: devices, processes: []))),
            scrollIndicatorState: state, initialSelectedTab: .audio
        ).environment(\.dashboardPresentationIsPresented, false))
        defer { host.close() }
        host.settle()
        let scrolls = host.allScrollViews
        let identities = Set(scrolls.map(ObjectIdentifier.init))
        let rowScroll = try XCTUnwrap(scrolls.first { ($0.documentView?.frame.height ?? 0) > 600 })
        rowScroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        rowScroll.reflectScrolledClipView(rowScroll.contentView)
        let popover = RecordingPopoverHost(recorder: DashboardPopoverEventRecorder())
        popover.contentViewController = host.controller
        var reduceMotion = false
        var completions: [@MainActor () -> Void] = []
        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover,
            shouldReduceMotion: { reduceMotion }, onHeightTransitionChange: state.setHeightTransitioning,
            visibleFrameForWindow: { _ in nil }, animateFrame: { window, frame, completion in
                window.setFrame(frame, display: true)
                completions.append(completion)
            })
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 480))
        popover.isShown = true
        func check(hidden: Bool) {
            host.settle()
            for scroll in scrolls { scroll.scrollerStyle = .legacy; scroll.flashScrollers() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(state.isHeightTransitioning, hidden)
            XCTAssertEqual(Set(host.allScrollViews.map(ObjectIdentifier.init)), identities)
            XCTAssertEqual(rowScroll.contentView.bounds.origin.y, 100, accuracy: 1)
            if hidden {
                for scroll in scrolls {
                    XCTAssertFalse(DashboardListTestHost.indicatorIsVisible(scroll.verticalScroller))
                    XCTAssertFalse(DashboardListTestHost.indicatorIsVisible(scroll.horizontalScroller))
                }
            } else {
                XCTAssertTrue(DashboardListTestHost.indicatorIsVisible(rowScroll.verticalScroller))
            }
        }
        check(hidden: false)
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 440))
        check(hidden: true)
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 460))
        XCTAssertEqual(completions.count, 2)
        completions[0]()
        check(hidden: true)
        completions[1]()
        check(hidden: false)
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 420))
        check(hidden: true)
        coordinator.invalidateInFlightAnimation()
        completions[2]()
        check(hidden: false)
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 400))
        check(hidden: true)
        coordinator.resetAfterPopoverCloses()
        completions[3]()
        check(hidden: false)
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 450))
        check(hidden: true)
        reduceMotion = true
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 480))
        completions[4]()
        check(hidden: false)
        try host.assertBottomReachable(rowScroll)
    }

    func testContentMeasurementEmitsFixedWidthAfterEveryLiveSegmentReports() {
        let measurement = DashboardPopoverContentMeasurement()
        let expectedSize = NSSize(width: 420, height: 323)
        var sizes: [NSSize] = []
        measurement.onContentSizeChange = { sizes.append($0) }

        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(280, for: .scrollContent)

        XCTAssertTrue(Self.waitUntil { sizes == [expectedSize] })
        XCTAssertEqual(measurement.latestContentSize, expectedSize)
    }

    func testContentMeasurementIgnoresInvalidSegmentsAndKeepsLastValidSize() {
        let measurement = DashboardPopoverContentMeasurement()
        measurement.seedIfNeeded(NSSize(width: 420, height: 240))

        measurement.report(.nan, for: .header)
        measurement.report(0, for: .scrollContent)
        Self.drainMainRunLoop()

        XCTAssertEqual(measurement.latestContentSize, NSSize(width: 420, height: 240))
    }

    func testContentMeasurementInvalidationDropsQueuedEmission() {
        let measurement = DashboardPopoverContentMeasurement()
        var sizes: [NSSize] = []
        measurement.onContentSizeChange = { sizes.append($0) }

        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(280, for: .scrollContent)
        measurement.invalidatePendingEmissions()
        Self.drainMainRunLoop()

        XCTAssertTrue(sizes.isEmpty)
        XCTAssertEqual(measurement.latestContentSize, NSSize(width: 420, height: 323))
    }

    func testContentMeasurementDropsSupersededQueuedEmission() {
        let measurement = DashboardPopoverContentMeasurement()
        let expectedSize = NSSize(width: 420, height: 343)
        var sizes: [NSSize] = []
        measurement.onContentSizeChange = { sizes.append($0) }

        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(280, for: .scrollContent)
        measurement.report(300, for: .scrollContent)

        XCTAssertTrue(Self.waitUntil { sizes == [expectedSize] })
        XCTAssertEqual(measurement.latestContentSize, expectedSize)
    }

    func testContentMeasurementEmitsNewMeasurementAfterInvalidation() {
        let measurement = DashboardPopoverContentMeasurement()
        let expectedSize = NSSize(width: 420, height: 343)
        var sizes: [NSSize] = []
        measurement.onContentSizeChange = { sizes.append($0) }

        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(280, for: .scrollContent)
        measurement.invalidatePendingEmissions()
        measurement.report(300, for: .scrollContent)

        XCTAssertTrue(Self.waitUntil { sizes == [expectedSize] })
        XCTAssertEqual(measurement.latestContentSize, expectedSize)
    }

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

    func testVisiblePopoverAppliesSizeImmediatelyWhenReduceMotionIsEnabled() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            shouldReduceMotion: { true }
        )
        let initialSize = NSSize(width: 420, height: 200)
        coordinator.applyImmediately(measuredSize: initialSize)

        let targetSize = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: targetSize)

        XCTAssertEqual(popover.contentSize, targetSize)
        XCTAssertEqual(popover.contentSizeAssignments, [initialSize, targetSize])
    }

    func testVisiblePopoverUsesWorkspaceReduceMotionByDefault() throws {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Workspace Reduce Motion is disabled.")
        }

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }

        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)
        let initialSize = NSSize(width: 420, height: 200)
        let initialFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: initialSize))
        window.setFrame(NSRect(x: 100, y: 400, width: initialFrame.width, height: initialFrame.height), display: true)
        coordinator.applyImmediately(measuredSize: initialSize)
        popover.isShown = true
        let initialMaxY = window.frame.maxY

        let targetSize = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: targetSize)

        XCTAssertEqual(popover.contentSize, targetSize)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, targetSize)
        XCTAssertEqual(window.frame.maxY, initialMaxY)
    }

    func testAnimatedPathSynchronizesContentSizeAtInjectedCompletion() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }

        var transitions: [Bool] = []
        var animationRequestCount = 0
        var animationCompletion: (@MainActor () -> Void)?
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            shouldReduceMotion: { false },
            onHeightTransitionChange: { transitions.append($0) },
            animateFrame: { window, frame, completion in
                animationRequestCount += 1
                window.setFrame(frame, display: true)
                animationCompletion = completion
            }
        )
        let initialSize = NSSize(width: 420, height: 200)
        let initialFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: initialSize))
        window.setFrame(NSRect(x: 100, y: 400, width: initialFrame.width, height: initialFrame.height), display: true)
        coordinator.applyImmediately(measuredSize: initialSize)
        popover.isShown = true
        let initialMaxY = window.frame.maxY

        let targetSize = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: targetSize)
        coordinator.applyImmediately(measuredSize: targetSize)

        XCTAssertEqual(popover.contentSize, initialSize)
        XCTAssertEqual(transitions, [true])
        XCTAssertEqual(animationRequestCount, 1)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, targetSize)
        XCTAssertEqual(window.frame.maxY, initialMaxY)

        let firstCompletion = animationCompletion
        let finalSize = NSSize(width: 420, height: 300)
        coordinator.applyImmediately(measuredSize: finalSize)
        let finalCompletion = animationCompletion
        firstCompletion?()

        XCTAssertEqual(popover.contentSize, initialSize)
        XCTAssertEqual(transitions, [true])
        XCTAssertEqual(animationRequestCount, 2)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, finalSize)
        XCTAssertEqual(window.frame.maxY, initialMaxY)

        finalCompletion?()

        XCTAssertEqual(popover.contentSize, finalSize)
        XCTAssertEqual(transitions, [true, false])

        popover.contentSize = initialSize
        coordinator.applyImmediately(measuredSize: finalSize)

        XCTAssertEqual(popover.contentSize, finalSize)
        XCTAssertEqual(animationRequestCount, 2)
    }

    func testVisiblePopoverUsesPlacementAwareResizeWhenTargetWouldCrossVisibleScreen() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        popover.animates = true
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }

        var transitions: [Bool] = []
        var animationRequestCount = 0
        let visibleFrame = NSRect(x: 0, y: 50, width: 1_000, height: 900)
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            shouldReduceMotion: { false },
            onHeightTransitionChange: { transitions.append($0) },
            visibleFrameForWindow: { _ in visibleFrame },
            animateFrame: { _, _, _ in animationRequestCount += 1 }
        )
        let initialSize = NSSize(width: 420, height: 200)
        let initialFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: initialSize)).size
        window.setFrame(
            NSRect(x: 100, y: 400, width: initialFrameSize.width, height: initialFrameSize.height),
            display: true
        )
        coordinator.applyImmediately(measuredSize: initialSize)
        popover.isShown = true
        let originalWindowFrame = window.frame

        let targetSize = NSSize(width: 420, height: 560)
        let targetFrameHeight = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetSize)
        ).height
        XCTAssertLessThan(originalWindowFrame.maxY - targetFrameHeight, visibleFrame.minY)

        coordinator.applyImmediately(measuredSize: targetSize)

        XCTAssertEqual(popover.contentSize, targetSize)
        XCTAssertEqual(popover.contentSizeAssignments, [initialSize, targetSize])
        XCTAssertEqual(window.frame, originalWindowFrame)
        XCTAssertTrue(popover.animates)
        XCTAssertEqual(popover.animatesAtContentSizeAssignment, [true, false])

        let laterSafeSize = NSSize(width: 420, height: 300)
        coordinator.applyImmediately(measuredSize: laterSafeSize)

        XCTAssertEqual(popover.contentSize, laterSafeSize)
        XCTAssertEqual(popover.contentSizeAssignments, [initialSize, targetSize, laterSafeSize])
        XCTAssertEqual(popover.animatesAtContentSizeAssignment, [true, false, false])
        XCTAssertTrue(popover.animates)
        XCTAssertEqual(animationRequestCount, 0)
        XCTAssertEqual(transitions, [])

        popover.isShown = false
        coordinator.resetAfterPopoverCloses()
        popover.isShown = true
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 400))

        XCTAssertEqual(animationRequestCount, 1)
        XCTAssertEqual(transitions, [true])
    }

    func testVisiblePopoverInvalidatesInFlightAnimationBeforeUnsafeResize() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        popover.animates = true
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }

        var transitions: [Bool] = []
        var animationRequestCount = 0
        var animationCompletion: (@MainActor () -> Void)?
        var visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 900)
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            shouldReduceMotion: { false },
            onHeightTransitionChange: { transitions.append($0) },
            visibleFrameForWindow: { _ in visibleFrame },
            animateFrame: { _, _, completion in
                animationRequestCount += 1
                animationCompletion = completion
            }
        )
        let initialSize = NSSize(width: 420, height: 200)
        let initialFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: initialSize)).size
        window.setFrame(
            NSRect(x: 100, y: 400, width: initialFrameSize.width, height: initialFrameSize.height),
            display: true
        )
        coordinator.applyImmediately(measuredSize: initialSize)
        XCTAssertEqual(popover.contentSize, initialSize)

        popover.isShown = true
        let safeTargetSize = NSSize(width: 420, height: 400)
        let safeTargetFrameHeight = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: safeTargetSize)
        ).height
        XCTAssertGreaterThanOrEqual(window.frame.maxY - safeTargetFrameHeight, visibleFrame.minY)

        coordinator.applyImmediately(measuredSize: safeTargetSize)

        guard let staleCompletion = animationCompletion else {
            return XCTFail("expected a completion from the safe-target animator")
        }
        XCTAssertEqual(animationRequestCount, 1)
        XCTAssertEqual(transitions, [true])

        visibleFrame = NSRect(x: 0, y: 50, width: 1_000, height: 900)
        let unsafeTargetSize = NSSize(width: 420, height: 560)
        let unsafeTargetFrameHeight = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: unsafeTargetSize)
        ).height
        XCTAssertLessThan(window.frame.maxY - unsafeTargetFrameHeight, visibleFrame.minY)

        coordinator.applyImmediately(measuredSize: unsafeTargetSize)

        XCTAssertEqual(popover.contentSize, unsafeTargetSize)
        XCTAssertEqual(popover.contentSizeAssignments, [initialSize, unsafeTargetSize])
        XCTAssertEqual(popover.animatesAtContentSizeAssignment, [true, false])
        XCTAssertTrue(popover.animates)
        XCTAssertEqual(animationRequestCount, 1)
        XCTAssertEqual(transitions, [true, false])

        staleCompletion()

        XCTAssertEqual(popover.contentSize, unsafeTargetSize)
        XCTAssertEqual(popover.contentSizeAssignments, [initialSize, unsafeTargetSize])
        XCTAssertEqual(transitions, [true, false])
    }

    func testReduceMotionLandingDuringInFlightAnimationSnapsFrameAndSynchronizesContentSize() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        var reducesMotion = false
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            shouldReduceMotion: { reducesMotion }
        )

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        let initialMaxY = window.frame.maxY

        let sizeB = NSSize(width: 420, height: 400)
        let frameB = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeB))
        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(popover.contentSize, sizeA)

        let movementDeadline = Date().addingTimeInterval(1.0)
        while Date() < movementDeadline,
              !(window.frame.height > frameA.height + 1 && window.frame.height < frameB.height - 1) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertGreaterThan(window.frame.height, frameA.height + 1)
        XCTAssertLessThan(window.frame.height, frameB.height - 1)
        XCTAssertEqual(popover.contentSize, sizeA)

        reducesMotion = true
        let sizeC = NSSize(width: 420, height: 300)
        let frameC = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeC))
        coordinator.applyImmediately(measuredSize: sizeC)

        XCTAssertEqual(popover.contentSize, sizeC)

        let convergeDeadline = Date().addingTimeInterval(0.5)
        while Date() < convergeDeadline, !(abs(window.frame.height - frameC.height) < 1) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertEqual(window.frame.height, frameC.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, initialMaxY, accuracy: 1)

        let driftDeadline = Date().addingTimeInterval(1.0)
        while Date() < driftDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(popover.contentSize, sizeC)
        XCTAssertNotEqual(popover.contentSize, sizeB)
        XCTAssertFalse(popover.contentSizeAssignments.contains(sizeB))
        XCTAssertEqual(window.frame.height, frameC.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, initialMaxY, accuracy: 1)
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

    func testVisiblePopoverAnimatesHeightAndSynchronizesContentSizeAtCompletion() throws {
        try Self.requireLiveWindowAnimation()

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

    func testReversalToCurrentSizeDuringAnimationConvergesToRequestedSize() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        let initialMaxY = window.frame.maxY

        let sizeB = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(popover.contentSize, sizeA)

        let movementDeadline = Date().addingTimeInterval(1.0)
        while Date() < movementDeadline, window.frame.height <= frameA.height + 1 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertGreaterThan(window.frame.height, frameA.height + 1)
        XCTAssertEqual(popover.contentSize, sizeA)

        coordinator.applyImmediately(measuredSize: sizeA)

        let settleDeadline = Date().addingTimeInterval(1.0)
        while Date() < settleDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if popover.contentSize == sizeA, abs(window.frame.height - frameA.height) < 1 { break }
        }

        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertNotEqual(popover.contentSize, sizeB)
        XCTAssertEqual(window.frame.height, frameA.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, initialMaxY, accuracy: 1)
    }

    func testLiveReTargetToNewSizeDuringAnimationConvergesToFinalTarget() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        let initialMaxY = window.frame.maxY

        let sizeB = NSSize(width: 420, height: 400)
        let frameB = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeB))
        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(popover.contentSize, sizeA)

        let movementDeadline = Date().addingTimeInterval(1.0)
        while Date() < movementDeadline,
              !(window.frame.height > frameA.height + 1 && window.frame.height < frameB.height - 1) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertGreaterThan(window.frame.height, frameA.height + 1)
        XCTAssertLessThan(window.frame.height, frameB.height - 1)
        XCTAssertEqual(popover.contentSize, sizeA)

        let sizeC = NSSize(width: 420, height: 300)
        let frameC = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeC))
        coordinator.applyImmediately(measuredSize: sizeC)

        let settleDeadline = Date().addingTimeInterval(1.0)
        while Date() < settleDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if popover.contentSize == sizeC, abs(window.frame.height - frameC.height) < 1 { break }
        }

        XCTAssertEqual(popover.contentSize, sizeC)
        XCTAssertNotEqual(popover.contentSize, sizeB)
        XCTAssertFalse(popover.contentSizeAssignments.contains(sizeB))
        XCTAssertEqual(window.frame.height, frameC.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, initialMaxY, accuracy: 1)
    }

    func testVisibleSameTurnSchedulesCoalesceToFinalSize() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        let initialMaxY = window.frame.maxY

        let sizeB = NSSize(width: 420, height: 400)
        let sizeC = NSSize(width: 420, height: 300)
        let frameC = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeC))
        coordinator.schedule(measuredSize: sizeB)
        coordinator.schedule(measuredSize: sizeC)

        let settleDeadline = Date().addingTimeInterval(1.0)
        while Date() < settleDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if popover.contentSize == sizeC, abs(window.frame.height - frameC.height) < 1 { break }
        }

        XCTAssertEqual(popover.contentSize, sizeC)
        XCTAssertNotEqual(popover.contentSize, sizeB)
        XCTAssertFalse(popover.contentSizeAssignments.contains(sizeB))
        XCTAssertEqual(window.frame.height, frameC.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, initialMaxY, accuracy: 1)
    }

    func testCloseAndReopenDuringAnimationDoesNotApplyStaleSize() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)

        let sizeB = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(popover.contentSize, sizeA)

        let movementDeadline = Date().addingTimeInterval(1.0)
        while Date() < movementDeadline, window.frame.height <= frameA.height + 1 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertGreaterThan(window.frame.height, frameA.height + 1)

        popover.performClose(nil)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)

        popover.show(
            relativeTo: NSRect(x: 0, y: 0, width: 20, height: 20),
            of: NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)),
            preferredEdge: .minY
        )

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertNotEqual(popover.contentSize, sizeB)
    }

    func testImmediateReversalBeforeFrameMovementKeepsWindowAtRequestedSize() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        let coordinator = DashboardPopoverContentSizeCoordinator(popover: popover)

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        let initialMaxY = window.frame.maxY

        let sizeB = NSSize(width: 420, height: 400)
        let frameB = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeB))

        coordinator.applyImmediately(measuredSize: sizeB)
        coordinator.applyImmediately(measuredSize: sizeA)

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertNotEqual(popover.contentSize, sizeB)
        XCTAssertEqual(window.frame.height, frameA.height, accuracy: 1)
        XCTAssertNotEqual(window.frame.height, frameB.height, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, initialMaxY, accuracy: 1)
    }

    func testVisibleHeightAnimationReportsTransitionUntilCompletion() throws {
        try Self.requireLiveWindowAnimation()
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true
        var transitions: [Bool] = []
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            onHeightTransitionChange: { transitions.append($0) }
        )

        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 200))
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 400))
        XCTAssertEqual(transitions, [true])

        XCTAssertTrue(Self.waitUntil { popover.contentSize == NSSize(width: 420, height: 400) })
        XCTAssertEqual(transitions, [true, false])
    }

    func testHeightTransitionRetargetKeepsSignalUntilFinalTargetSettles() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        var transitions: [Bool] = []
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            onHeightTransitionChange: { transitions.append($0) }
        )

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertEqual(transitions, [])

        let sizeB = NSSize(width: 420, height: 400)
        let frameB = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeB))
        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(transitions, [true])

        let movementDeadline = Date().addingTimeInterval(1.0)
        while Date() < movementDeadline,
              !(window.frame.height > frameA.height + 1 && window.frame.height < frameB.height - 1) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertGreaterThan(window.frame.height, frameA.height + 1)
        XCTAssertLessThan(window.frame.height, frameB.height - 1)
        XCTAssertEqual(transitions, [true])

        let sizeC = NSSize(width: 420, height: 300)
        let frameC = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeC))
        coordinator.applyImmediately(measuredSize: sizeC)

        let settleDeadline = Date().addingTimeInterval(1.0)
        while Date() < settleDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if popover.contentSize == sizeC, abs(window.frame.height - frameC.height) < 1 { break }
        }

        XCTAssertEqual(popover.contentSize, sizeC)
        XCTAssertEqual(transitions, [true, false])
    }

    func testNonAnimatedSizesDoNotPublishHeightTransition() throws {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }

        var transitions: [Bool] = []
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            shouldReduceMotion: { true },
            onHeightTransitionChange: { transitions.append($0) }
        )

        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 200))
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 400))
        Self.drainMainRunLoop()
        XCTAssertEqual(transitions, [])

        popover.isShown = true
        XCTAssertNotNil(contentViewController.view.window)
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 200))
        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 400))
        Self.drainMainRunLoop()

        XCTAssertEqual(transitions, [])
    }

    func testSameInFlightTargetNoOpDoesNotPulseTrue() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        var transitions: [Bool] = []
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            onHeightTransitionChange: { transitions.append($0) }
        )

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertEqual(transitions, [])

        let sizeB = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(transitions, [true])

        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(transitions, [true])

        let settleDeadline = Date().addingTimeInterval(1.0)
        while Date() < settleDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if popover.contentSize == sizeB { break }
        }

        XCTAssertEqual(popover.contentSize, sizeB)
        XCTAssertEqual(transitions, [true, false])
    }

    func testEqualFrameReversalResetsSignalWithoutTruePulse() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        var transitions: [Bool] = []
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            onHeightTransitionChange: { transitions.append($0) }
        )

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertEqual(transitions, [])

        let sizeB = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(transitions, [true])

        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(transitions, [true, false])

        coordinator.applyImmediately(measuredSize: sizeA)
        Self.drainMainRunLoop()
        XCTAssertEqual(transitions, [true, false])
    }

    func testInvalidatingInFlightAnimationEmitsTerminalFalse() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        var transitions: [Bool] = []
        let coordinator = DashboardPopoverContentSizeCoordinator(
            popover: popover,
            onHeightTransitionChange: { transitions.append($0) }
        )

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertEqual(transitions, [])

        let sizeB = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(transitions, [true])

        let movementDeadline = Date().addingTimeInterval(1.0)
        while Date() < movementDeadline, window.frame.height <= frameA.height + 1 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertGreaterThan(window.frame.height, frameA.height + 1)
        XCTAssertEqual(transitions, [true])

        coordinator.invalidateInFlightAnimation()
        XCTAssertEqual(transitions, [true, false])

        let driftDeadline = Date().addingTimeInterval(1.0)
        while Date() < driftDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertNotEqual(popover.contentSize, sizeB)
        XCTAssertEqual(transitions, [true, false])
    }

    func testClosingThroughControllerLifecycleInvalidatesInFlightAnimation() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }

        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
        )
        defer { withExtendedLifetime(controller) {} }
        popover.contentViewController = contentViewController
        popover.isShown = true

        let coordinator = controller.testingContentSizeCoordinator

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)

        let sizeB = NSSize(width: 420, height: 400)
        coordinator.applyImmediately(measuredSize: sizeB)
        XCTAssertEqual(popover.contentSize, sizeA)

        popover.performClose(nil)
        XCTAssertEqual(recorder.events, ["close-popover"])

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertNotEqual(popover.contentSize, sizeB)
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
        )

        controller.toggle(relativeTo: nil)

        XCTAssertEqual(recorder.events, [])
    }

    func testUnshownPopoverDidCloseDoesNotInventVisibilityChange() {
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
        )

        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))

        XCTAssertEqual(recorder.events, [])
    }

    func testFailedShowDoesNotReportVisibilityOrFocus() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = FailingShowPopoverHost()
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { isVisible in
                recorder.record(isVisible ? "visible:true" : "visible:false")
            },
        )

        controller.toggle(relativeTo: NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)))

        XCTAssertEqual(recorder.events, ["activate-app"])
        XCTAssertFalse(popover.isShown)
    }

    func testPresentationGateTracksSuccessfulShowAndCloseOnly() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let presentationState = DashboardPresentationState()
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
            presentationState: presentationState
        )

        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertFalse(presentationState.isPresented)

        controller.toggle(relativeTo: anchor)
        XCTAssertTrue(presentationState.isPresented)

        controller.toggle(relativeTo: anchor)
        XCTAssertFalse(presentationState.isPresented)
    }

    func testFailedShowKeepsPresentationGateClosed() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = FailingShowPopoverHost()
        let presentationState = DashboardPresentationState()
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
            presentationState: presentationState
        )

        controller.toggle(relativeTo: NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)))

        XCTAssertFalse(presentationState.isPresented)
    }

    func testOpeningThenClosingReportsPairedVisibilityOnce() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { isVisible in
                recorder.record(isVisible ? "visible:true" : "visible:false")
            },
        )

        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        controller.toggle(relativeTo: anchor)
        controller.toggle(relativeTo: anchor)

        XCTAssertEqual(recorder.events, [
            "activate-app",
            "show-popover",
            "focus-popover",
            "visible:true",
            "close-popover",
            "visible:false"
        ])
    }

    func testLateDidCloseFromReplacedHostDoesNotClearActiveSession() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let presentationState = DashboardPresentationState()
        var visibility: [Bool] = []
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { visibility.append($0) },
            presentationState: presentationState
        )
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))

        controller.toggle(relativeTo: anchor)
        controller.toggle(relativeTo: anchor)
        controller.toggle(relativeTo: anchor)
        XCTAssertTrue(presentationState.isPresented)
        XCTAssertEqual(visibility, [true, false, true])

        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification))

        XCTAssertTrue(presentationState.isPresented)
        XCTAssertEqual(visibility, [true, false, true])
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
        )
        defer { withExtendedLifetime(controller) {} }

        let staleSize = NSSize(width: 100, height: 100)
        popover.contentSize = staleSize

        controller.toggle(relativeTo: NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)))

        XCTAssertNotEqual(popover.contentSizeAtShow, staleSize)
        XCTAssertNotEqual(popover.contentSizeAtShow, NSSize(width: 320, height: 320))
        XCTAssertEqual(popover.contentSizeAtShow, popover.contentSize)
        XCTAssertEqual(popover.contentSizeAtShow?.width, DashboardPopoverLayout.contentWidth)
        XCTAssertGreaterThan(popover.contentSizeAtShow?.height ?? 0, 0)
    }

    func testDashboardPopoverScrollIndicatorStateTracksVisibleAnimation() throws {
        try Self.requireLiveWindowAnimation()

        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let contentViewController = NSViewController()

        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
        )
        defer { withExtendedLifetime(controller) {} }
        popover.contentViewController = contentViewController
        let window = NSWindow(contentViewController: contentViewController)
        defer { window.close() }
        popover.isShown = true

        let coordinator = controller.testingContentSizeCoordinator
        XCTAssertFalse(controller.testingScrollIndicatorState.isHeightTransitioning)

        let sizeA = NSSize(width: 420, height: 200)
        let frameA = window.frameRect(forContentRect: NSRect(origin: .zero, size: sizeA))
        window.setFrame(NSRect(x: 100, y: 400, width: frameA.width, height: frameA.height), display: true)
        coordinator.applyImmediately(measuredSize: sizeA)
        XCTAssertEqual(popover.contentSize, sizeA)
        XCTAssertFalse(controller.testingScrollIndicatorState.isHeightTransitioning)

        coordinator.applyImmediately(measuredSize: NSSize(width: 420, height: 400))
        XCTAssertTrue(controller.testingScrollIndicatorState.isHeightTransitioning)
        XCTAssertTrue(Self.waitUntil { popover.contentSize == NSSize(width: 420, height: 400) })
        XCTAssertFalse(controller.testingScrollIndicatorState.isHeightTransitioning)
    }

    func testHostedDashboardScrollIndicatorToggleRetainsSingleScrollViewAndNaturalGeometry() throws {
        let state = DashboardPopoverScrollIndicatorState()
        let reports = DashboardSegmentRecorder()
        let content = DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onMeasuredSegmentHeight: { segment, height in
                reports.record(segment: segment, height: height)
            },
            scrollIndicatorState: state
        )
        let host = NSHostingController(
            rootView: content.frame(
                width: DashboardPopoverLayout.contentWidth,
                height: DashboardPopoverLayout.maximumHeight,
                alignment: .topLeading
            )
        )
        let window = NSWindow(contentViewController: host)
        defer { window.close() }
        window.setContentSize(NSSize(
            width: DashboardPopoverLayout.contentWidth,
            height: DashboardPopoverLayout.maximumHeight
        ))
        window.layoutIfNeeded()
        Self.drainMainRunLoop()

        XCTAssertEqual(Self.allScrollViews(in: host.view).count, 1)

        let reportedBefore = reports.heights.last
        state.setHeightTransitioning(true)
        Self.drainMainRunLoop()
        state.setHeightTransitioning(false)
        Self.drainMainRunLoop()

        XCTAssertEqual(Self.allScrollViews(in: host.view).count, 1)
        let reportedAfter = reports.heights.last
        XCTAssertTrue(reportedAfter?.isFinite ?? false)
        XCTAssertEqual(reportedAfter, reportedBefore)
    }

    func testHiddenDashboardUpdateIsAppliedBeforeShowing() {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let store = MetricsStore()
        let controller = Self.makeDashboardPopoverController(popover: popover, store: store)
        defer { withExtendedLifetime(controller) {} }
        let initialSize = popover.contentSize

        store.apply(Self.fullDashboardMetrics, timestamp: Date(timeIntervalSince1970: 32))

        XCTAssertTrue(Self.waitUntil { popover.contentSize.height != initialSize.height })
        let updatedSize = popover.contentSize
        XCTAssertEqual(updatedSize.width, DashboardPopoverLayout.contentWidth)
        XCTAssertLessThanOrEqual(updatedSize.height, DashboardPopoverLayout.maximumHeight)

        controller.toggle(relativeTo: NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20)))

        XCTAssertEqual(popover.contentSizeAtShow, updatedSize)
        XCTAssertEqual(popover.contentSize, updatedSize)
    }

    func testDashboardPopoverDisablesAutomaticPreferredContentSizingAfterBootstrap() throws {
        let popover = RecordingPopoverHost(recorder: DashboardPopoverEventRecorder())
        let controller = Self.makeDashboardPopoverController(popover: popover)
        defer { withExtendedLifetime(controller) {} }

        let host = try XCTUnwrap(popover.contentViewController as? DashboardPopoverHostingController)

        XCTAssertEqual(host.sizingOptions, [])
        XCTAssertEqual(popover.contentSize.width, DashboardPopoverLayout.contentWidth)
        XCTAssertGreaterThan(popover.contentSize.height, 0)
    }

    func testHiddenBootstrapMatchesDashboardSegmentMeasurement() throws {
        let reports = DashboardSegmentRecorder()
        let content = DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onMeasuredSegmentHeight: { segment, height in
                reports.record(segment: segment, height: height)
            }
        )
        let host = DashboardPopoverHostingController(
            rootView: DashboardPopoverRootView(
                content: content,
                presentationState: DashboardPresentationState()
            )
        )
        host.sizingOptions = [.preferredContentSize]

        let bootstrapSize = host.bootstrapContentSize()

        XCTAssertTrue(Self.waitUntil {
            Set(reports.segments) == Set(DashboardContentMeasurementSegment.allCases)
        })
        let latestHeights = zip(reports.segments, reports.heights).reduce(
            into: [DashboardContentMeasurementSegment: CGFloat]()
        ) { heights, report in
            heights[report.0] = report.1
        }
        let measuredHeight = DashboardContentMeasurementSegment.allCases.reduce(0) { height, segment in
            height + (latestHeights[segment] ?? 0)
        }

        XCTAssertEqual(bootstrapSize.width, DashboardPopoverLayout.contentWidth)
        XCTAssertEqual(bootstrapSize.height, measuredHeight, accuracy: 1)
    }

    func testHostedDashboardReportsAllLiveGeometrySegments() throws {
        let reports = DashboardSegmentRecorder()
        let content = DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onMeasuredSegmentHeight: { segment, height in
                reports.record(segment: segment, height: height)
            }
        )
        let host = NSHostingController(rootView: content.frame(width: 420, alignment: .topLeading))
        let window = NSWindow(contentViewController: host)
        defer { window.close() }
        window.setContentSize(NSSize(width: 420, height: 560))
        window.layoutIfNeeded()
        Self.drainMainRunLoop()

        XCTAssertEqual(Set(reports.segments), Set(DashboardContentMeasurementSegment.allCases))
        XCTAssertTrue(reports.heights.allSatisfy { $0.isFinite && $0 > 0 })
    }

    func testHostedListDashboardFeedsNaturalMeasurementWithoutResizeOrTabReopenFeedback() throws {
        let devices = (0..<20).map { index in
            AudioDeviceControlSnapshot(device: AudioOutputDeviceSnapshot(id: "output-\(index)",
                objectID: UInt32(index + 1), name: "Output \(index)",
                volume: .value(0.5, isWritable: true), mute: .value(false, isWritable: true)), error: nil)
        }
        let audio = AudioDashboardModel(coordinator: TestAudioControlCoordinator(
            snapshot: AudioControlSnapshot(devices: devices, processes: [])))
        let selection = DashboardTabSelectionState(initialTab: .audio)
        let measurement = DashboardPopoverContentMeasurement()
        let host = DashboardListTestHost(DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(), audioDashboardModel: audio,
            onMeasuredSegmentHeight: { measurement.report($1, for: $0) },
            tabSelectionState: selection
        ).environment(\.dashboardPresentationIsPresented, false))
        defer { host.close() }
        var appliedSizes: [NSSize] = []
        defer { measurement.onContentSizeChange = nil }
        measurement.onContentSizeChange = { size in
            guard let capped = DashboardPopoverLayout.contentSize(for: size) else { return }
            appliedSizes.append(capped)
            host.panel.setContentSize(capped)
        }
        host.settle()
        host.settle()
        let natural = try XCTUnwrap(measurement.latestContentSize)
        XCTAssertGreaterThan(natural.height, 560)
        XCTAssertEqual(host.panel.contentRect(forFrameRect: host.panel.frame).height, 560, accuracy: 1)
        XCTAssertEqual(host.scrollViews.count, 1)
        try host.assertBottomReachable(try XCTUnwrap(host.scrollViews.first))
        let stableCount = appliedSizes.count
        host.settle()
        XCTAssertEqual(appliedSizes.count, stableCount)
        selection.selectedTab = .overview
        host.settle()
        XCTAssertLessThan(try XCTUnwrap(measurement.latestContentSize).height, natural.height)
        selection.selectedTab = .audio
        host.settle()
        host.settle()
        XCTAssertEqual(try XCTUnwrap(measurement.latestContentSize).height, natural.height, accuracy: 1)
        let reopenCount = appliedSizes.count
        host.panel.orderOut(nil)
        host.panel.orderFront(nil)
        host.settle()
        XCTAssertEqual(appliedSizes.count, reopenCount)
    }

    func testMeasuredSegmentReportsNaturalScrollContentHeightAboveConstrainedViewport() throws {
        let viewportHeight: CGFloat = 200
        var reportedScrollContentHeights: [CGFloat] = []
        let tallFixture = LazyVStack(spacing: 12) {
            ForEach(0..<40, id: \.self) { index in
                Text("Natural-height row \(index)")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        let content = ScrollView {
            DashboardMeasuredSegment(
                segment: .scrollContent,
                onHeightChange: { _, height in
                    reportedScrollContentHeights.append(height)
                },
                content: {
                    tallFixture
                        .frame(width: DashboardPopoverLayout.contentWidth, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            )
        }
        let host = NSHostingController(
            rootView: content.frame(
                width: DashboardPopoverLayout.contentWidth,
                height: viewportHeight,
                alignment: .topLeading
            )
        )
        let window = NSWindow(contentViewController: host)
        defer { window.close() }
        window.setContentSize(NSSize(width: DashboardPopoverLayout.contentWidth, height: viewportHeight))
        window.layoutIfNeeded()
        Self.drainMainRunLoop()

        let scrollView = try XCTUnwrap(Self.firstScrollView(in: host.view))
        let documentHeight = try XCTUnwrap(scrollView.documentView?.frame.height)
        let reportedHeight = try XCTUnwrap(reportedScrollContentHeights.last)

        XCTAssertGreaterThan(reportedHeight, viewportHeight)
        XCTAssertGreaterThan(documentHeight, scrollView.contentView.bounds.height)
        XCTAssertEqual(reportedHeight, documentHeight, accuracy: 2)
    }

    func testHostedDashboardRetainsScrollViewAtCappedPresentation() throws {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let controller = DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: recorder),
            dashboardModel: DashboardModel(store: MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
        )
        defer { withExtendedLifetime(controller) {} }

        let hostingController = try XCTUnwrap(popover.contentViewController as? DashboardPopoverHostingController)
        let window = NSWindow(contentViewController: hostingController)
        defer { window.close() }
        window.setContentSize(NSSize(
            width: DashboardPopoverLayout.contentWidth,
            height: DashboardPopoverLayout.maximumHeight
        ))
        window.layoutIfNeeded()
        Self.drainMainRunLoop()

        let scrollView = try XCTUnwrap(
            Self.firstScrollView(in: hostingController.view),
            "Dashboard host must retain an NSScrollView at the 420x560 capped presentation"
        )
        XCTAssertGreaterThan(scrollView.frame.width, 0)
        XCTAssertLessThanOrEqual(scrollView.frame.maxX, DashboardPopoverLayout.contentWidth + 1)
        XCTAssertGreaterThan(scrollView.frame.height, 0)
        XCTAssertLessThanOrEqual(scrollView.frame.height, DashboardPopoverLayout.maximumHeight + 1)
    }

    func testHostedDashboardUpdatesPopoverHeightWhenTabChanges() throws {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let store = MetricsStore()
        store.apply(Self.fullDashboardMetrics, timestamp: Date(timeIntervalSince1970: 31))

        let controller = Self.makeDashboardPopoverController(popover: popover, store: store)
        defer { withExtendedLifetime(controller) {} }

        let hostingController = try XCTUnwrap(popover.contentViewController as? DashboardPopoverHostingController)
        let window = NSWindow(contentViewController: hostingController)
        defer { window.close() }
        window.setContentSize(popover.contentSize)
        window.layoutIfNeeded()
        Self.drainMainRunLoop()

        let overviewHeight = popover.contentSize.height

        hostingController.dashboardTabSelection.selectedTab = .actives

        XCTAssertTrue(Self.waitUntil { popover.contentSize.height != overviewHeight })
        XCTAssertLessThanOrEqual(popover.contentSize.height, DashboardPopoverLayout.maximumHeight)
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
            )
            releasedPopover = popover

            withExtendedLifetime(controller) {}
        }

        XCTAssertNil(releasedPopover)
    }

    func testHiddenPresentationCancelsPowerFlowPollingLoop() throws {
        let provider = PowerFlowProviderSpy()
        let model = PowerFlowModel(
            provider: provider,
            observationIntervalNanoseconds: 5_000_000,
            sleep: { try await Task.sleep(nanoseconds: $0) }
        )
        let presentationState = DashboardPresentationState()
        let hosting = NSHostingController(
            rootView: DashboardPresentationHarness(presentationState: presentationState) {
                PowerFlowView(model: model, refreshTrigger: 0)
            }
        )
        let window = NSWindow(contentViewController: hosting)
        defer { window.close() }
        window.setContentSize(NSSize(width: 420, height: 200))
        window.orderFront(nil)

        presentationState.setPresented(true)
        XCTAssertTrue(Self.waitUntil { provider.snapshotCallCount >= 2 })

        presentationState.setPresented(false)
        window.orderOut(nil)
        Self.drainMainRunLoop()
        let countAtHide = provider.snapshotCallCount
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(presentationState.isPresented)
        XCTAssertEqual(
            provider.snapshotCallCount,
            countAtHide,
            "a hidden dashboard must not keep polling; visibility gating must cancel the loop"
        )
    }

    func testHiddenPresentationDeactivatesAudioPage() throws {
        let coordinator = TestAudioControlCoordinator()
        let audioModel = AudioDashboardModel(coordinator: coordinator)
        let presentationState = DashboardPresentationState()
        let content = DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: audioModel,
            initialSelectedTab: .audio
        )
        let hosting = NSHostingController(
            rootView: DashboardPresentationHarness(presentationState: presentationState) {
                content
            }
        )
        let window = NSWindow(contentViewController: hosting)
        defer { window.close() }
        window.setContentSize(NSSize(width: 420, height: 560))
        window.orderFront(nil)

        presentationState.setPresented(true)
        XCTAssertTrue(Self.waitUntil { coordinator.refreshSystemAudioAuthorizationCallCount == 1 })

        presentationState.setPresented(false)
        Self.drainMainRunLoop()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        Self.drainMainRunLoop()

        XCTAssertEqual(
            coordinator.refreshSystemAudioAuthorizationCallCount,
            1,
            "a hidden dashboard's audio page must be deactivated and ignore activation notifications"
        )
    }

    private static func makeDashboardPopoverController(
        popover: DashboardPopoverHosting,
        store: MetricsStore? = nil
    ) -> DashboardPopoverController {
        DashboardPopoverController(
            popover: popover,
            focusController: RecordingDashboardPopoverFocusController(recorder: DashboardPopoverEventRecorder()),
            dashboardModel: DashboardModel(store: store ?? MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            onVisibilityChange: { _ in },
        )
    }

    private static var fullDashboardMetrics: [MetricUpdate] {
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
        ]
    }

    private static func preferencesController() -> PreferencesController {
        PreferencesController(
            store: DashboardPopoverPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private static func allScrollViews(in view: NSView) -> [NSScrollView] {
        var result: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        for subview in view.subviews {
            result.append(contentsOf: allScrollViews(in: subview))
        }
        return result
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

    @MainActor
    private static func requireLiveWindowAnimation() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Live NSWindow animation is disabled by Reduce Motion.")
        }

        let window = NSWindow(contentViewController: NSViewController())
        defer { window.close() }

        let flag = LiveAnimationCompletionFlag()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            window.animator().setFrame(NSRect(x: 0, y: 0, width: 60, height: 60), display: true)
        } completionHandler: {
            flag.markCompleted()
        }

        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline, !flag.isCompleted {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard flag.isCompleted else {
            throw XCTSkip("Live NSWindow animation is unavailable (display asleep or window server not ticking).")
        }
    }

    private static func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

private final class LiveAnimationCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func markCompleted() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

@MainActor
private final class DashboardPopoverEventRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func clear() {
        events.removeAll()
    }
}

@MainActor
private final class DashboardSegmentRecorder {
    private(set) var segments: [DashboardContentMeasurementSegment] = []
    private(set) var heights: [CGFloat] = []

    func record(segment: DashboardContentMeasurementSegment, height: CGFloat) {
        segments.append(segment)
        heights.append(height)
    }
}

@MainActor
private final class RecordingPopoverHost: DashboardPopoverHosting {
    var behavior: NSPopover.Behavior = .transient
    var animates = false
    private(set) var contentSizeAssignments: [NSSize] = []
    private(set) var animatesAtContentSizeAssignment: [Bool] = []
    private(set) var contentSizeAtShow: NSSize?
    var contentSize: NSSize = .zero {
        didSet {
            contentSizeAssignments.append(contentSize)
            animatesAtContentSizeAssignment.append(animates)
        }
    }
    var contentViewController: NSViewController?
    weak var delegate: NSPopoverDelegate?
    var isShown = false
    var delaysDidClose = false

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
        if !delaysDidClose {
            delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
        }
    }
}

@MainActor
private final class FailingShowPopoverHost: DashboardPopoverHosting {
    var behavior: NSPopover.Behavior = .transient
    var animates = false
    var contentSize: NSSize = .zero
    var contentViewController: NSViewController? = NSHostingController(rootView: EmptyView())
    weak var delegate: NSPopoverDelegate?
    var isShown = false

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        isShown = false
    }

    func performClose(_ sender: Any?) {
        isShown = false
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

@MainActor
private struct DashboardPresentationHarness<Content: View>: View {
    @ObservedObject var presentationState: DashboardPresentationState
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.dashboardPresentationIsPresented, presentationState.isPresented)
    }
}

@MainActor
private final class PowerFlowProviderSpy: PowerFlowProviding {
    private(set) var snapshotCallCount = 0

    func snapshot() async -> PowerFlowSnapshot {
        snapshotCallCount += 1
        return .empty
    }
}
