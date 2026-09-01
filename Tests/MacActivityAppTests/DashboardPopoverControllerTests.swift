import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class DashboardPopoverControllerTests: XCTestCase {
    func testContentMeasurementEmitsFixedWidthAfterEveryLiveSegmentReports() {
        let measurement = DashboardPopoverContentMeasurement()
        var sizes: [NSSize] = []
        measurement.onContentSizeChange = { sizes.append($0) }

        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(280, for: .scrollContent)
        measurement.report(1, for: .footerDivider)
        measurement.report(48, for: .footer)
        Self.drainMainRunLoop()

        XCTAssertEqual(sizes, [NSSize(width: 420, height: 372)])
        XCTAssertEqual(measurement.latestContentSize, NSSize(width: 420, height: 372))
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
        measurement.report(1, for: .footerDivider)
        measurement.report(48, for: .footer)
        measurement.invalidatePendingEmissions()
        Self.drainMainRunLoop()

        XCTAssertTrue(sizes.isEmpty)
        XCTAssertEqual(measurement.latestContentSize, NSSize(width: 420, height: 372))
    }

    func testContentMeasurementDropsSupersededQueuedEmission() {
        let measurement = DashboardPopoverContentMeasurement()
        var sizes: [NSSize] = []
        measurement.onContentSizeChange = { sizes.append($0) }

        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(280, for: .scrollContent)
        measurement.report(1, for: .footerDivider)
        measurement.report(48, for: .footer)
        measurement.report(300, for: .scrollContent)
        Self.drainMainRunLoop()

        XCTAssertEqual(sizes, [NSSize(width: 420, height: 392)])
        XCTAssertEqual(measurement.latestContentSize, NSSize(width: 420, height: 392))
    }

    func testContentMeasurementEmitsNewMeasurementAfterInvalidation() {
        let measurement = DashboardPopoverContentMeasurement()
        var sizes: [NSSize] = []
        measurement.onContentSizeChange = { sizes.append($0) }

        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(280, for: .scrollContent)
        measurement.report(1, for: .footerDivider)
        measurement.report(48, for: .footer)
        measurement.invalidatePendingEmissions()
        measurement.report(300, for: .scrollContent)
        Self.drainMainRunLoop()

        XCTAssertEqual(sizes, [NSSize(width: 420, height: 392)])
        XCTAssertEqual(measurement.latestContentSize, NSSize(width: 420, height: 392))
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
            openPreferences: {},
            quitApplication: {}
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
        XCTAssertNotEqual(popover.contentSizeAtShow, NSSize(width: 320, height: 320))
        XCTAssertEqual(popover.contentSizeAtShow, popover.contentSize)
        XCTAssertEqual(popover.contentSizeAtShow?.width, DashboardPopoverLayout.contentWidth)
        XCTAssertGreaterThan(popover.contentSizeAtShow?.height ?? 0, 0)
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
            openPreferences: {},
            quitApplication: {},
            onMeasuredSegmentHeight: { segment, height in
                reports.record(segment: segment, height: height)
            }
        )
        let host = DashboardPopoverHostingController(
            rootView: DashboardPopoverRootView(content: content)
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

    func testGeometryMeasurementSchedulesLatestDashboardSize() throws {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let store = MetricsStore()
        let controller = Self.makeDashboardPopoverController(popover: popover, store: store)
        defer { withExtendedLifetime(controller) {} }
        let host = try XCTUnwrap(popover.contentViewController as? DashboardPopoverHostingController)
        let window = NSWindow(contentViewController: host)
        defer { window.close() }
        window.setContentSize(popover.contentSize)
        window.layoutIfNeeded()
        Self.drainMainRunLoop()
        let initialSize = popover.contentSize

        store.apply(Self.fullDashboardMetrics, timestamp: Date(timeIntervalSince1970: 32))

        XCTAssertTrue(Self.waitUntil { popover.contentSize.height != initialSize.height })
        XCTAssertEqual(popover.contentSize.width, DashboardPopoverLayout.contentWidth)
        XCTAssertLessThanOrEqual(popover.contentSize.height, DashboardPopoverLayout.maximumHeight)
    }

    func testHostedDashboardReportsAllLiveGeometrySegments() throws {
        let reports = DashboardSegmentRecorder()
        let content = DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore()),
            preferencesController: Self.preferencesController(),
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            openPreferences: {},
            quitApplication: {},
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
            openPreferences: {},
            quitApplication: {}
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

    func testHostedDashboardUpdatesPopoverHeightWhenMetricsAndTabChange() throws {
        let recorder = DashboardPopoverEventRecorder()
        let popover = RecordingPopoverHost(recorder: recorder)
        let store = MetricsStore()
        store.apply([.cpu(CPUReading(usagePercent: 13))], timestamp: Date(timeIntervalSince1970: 31))

        let controller = Self.makeDashboardPopoverController(popover: popover, store: store)
        defer { withExtendedLifetime(controller) {} }

        let hostingController = try XCTUnwrap(popover.contentViewController as? DashboardPopoverHostingController)
        let window = NSWindow(contentViewController: hostingController)
        defer { window.close() }
        window.setContentSize(popover.contentSize)
        window.layoutIfNeeded()
        Self.drainMainRunLoop()

        let initialHeight = popover.contentSize.height

        store.apply(Self.fullDashboardMetrics, timestamp: Date(timeIntervalSince1970: 32))

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
            openPreferences: {},
            quitApplication: {}
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

    private static func segmentedControl(in view: NSView?) -> NSSegmentedControl? {
        allSubviews(of: view).first { $0 is NSSegmentedControl } as? NSSegmentedControl
    }

    private static func allSubviews(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap(allSubviews)
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
        delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
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
