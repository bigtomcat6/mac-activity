import AppKit
import XCTest
@testable import DebugGlassPrototype

@available(macOS 26.0, *)
@MainActor
final class PrototypeSmokeValidationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func drainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    private func panelReport(
        requestedMode: String = PrototypeMode.transparentPanel.rawValue,
        panelShownWhileOpen: Bool? = true,
        windowFrame: String? = "{{100, 100}, {420, 480}}",
        frameWithinVisibleFrame: Bool? = true,
        monitorCountWhileOpen: Int = 6,
        popoverShownWhileOpen: Bool? = false,
        popoverShownAfterClose: Bool? = false,
        isOpaque: Bool? = false,
        backgroundColorClear: Bool? = true,
        alphaValue: Double? = 1,
        styleMask: UInt? = NSWindow.StyleMask([.borderless, .nonactivatingPanel]).rawValue,
        level: Int? = NSWindow.Level.popUpMenu.rawValue,
        canBecomeKey: Bool? = true,
        hasShadow: Bool? = false
    ) -> PrototypeSmokeModeReport {
        PrototypeSmokeModeReport(
            requestedMode: requestedMode,
            effectiveHost: PrototypeHostKind.panel.rawValue,
            cycles: 1,
            anchorScreenRect: "{{0, 0}, {24, 24}}",
            visibleFrame: "{{0, 0}, {1920, 1080}}",
            windowFrame: windowFrame,
            frameWithinVisibleFrame: frameWithinVisibleFrame,
            monitorCountWhileOpen: monitorCountWhileOpen,
            monitorCountAfterClose: 0,
            popoverShownWhileOpen: popoverShownWhileOpen,
            popoverShownAfterClose: popoverShownAfterClose,
            panelShownWhileOpen: panelShownWhileOpen,
            isOpaque: isOpaque,
            backgroundColorClear: backgroundColorClear,
            alphaValue: alphaValue,
            styleMask: styleMask,
            level: level,
            canBecomeKey: canBecomeKey,
            hasShadow: hasShadow
        )
    }

    private func popoverReport(
        requestedMode: String = PrototypeMode.standardPopover.rawValue,
        popoverShownWhileOpen: Bool? = true,
        popoverShownAfterClose: Bool? = false,
        windowFrame: String? = "{{100, 100}, {446, 482}}",
        frameWithinVisibleFrame: Bool? = true,
        monitorCountWhileOpen: Int = 1,
        panelShownWhileOpen: Bool? = nil
    ) -> PrototypeSmokeModeReport {
        PrototypeSmokeModeReport(
            requestedMode: requestedMode,
            effectiveHost: PrototypeHostKind.popover.rawValue,
            cycles: 1,
            anchorScreenRect: "{{0, 0}, {24, 24}}",
            visibleFrame: "{{0, 0}, {1920, 1080}}",
            windowFrame: windowFrame,
            frameWithinVisibleFrame: frameWithinVisibleFrame,
            monitorCountWhileOpen: monitorCountWhileOpen,
            monitorCountAfterClose: 0,
            popoverShownWhileOpen: popoverShownWhileOpen,
            popoverShownAfterClose: popoverShownAfterClose,
            panelShownWhileOpen: panelShownWhileOpen,
            isOpaque: nil,
            backgroundColorClear: nil,
            alphaValue: nil,
            styleMask: nil,
            level: nil,
            canBecomeKey: nil,
            hasShadow: nil
        )
    }

    func testValidPanelReportProducesNoFailure() {
        XCTAssertNil(
            PrototypeSmokeValidation.modeFailure(mode: .transparentPanel, report: panelReport())
        )
    }

    func testPanelReportFailsWhenNotShown() {
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(panelShownWhileOpen: false)
            ),
            "panel-not-shown"
        )
    }

    func testPanelAttributeFailureRequiresStyleMask() {
        XCTAssertEqual(
            PrototypeSmokeValidation.transparentPanelAttributeFailure(panelReport(styleMask: nil)),
            "panel-not-transparent:styleMask"
        )
    }

    func testPanelReportFailsWhenFrameMissing() {
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(windowFrame: nil)
            ),
            "panel-missing-frame"
        )
    }

    func testPanelReportFailsWhenOutsideVisibleFrame() {
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(frameWithinVisibleFrame: false)
            ),
            "panel-outside-visible-frame"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(frameWithinVisibleFrame: nil)
            ),
            "panel-outside-visible-frame"
        )
    }

    func testPanelReportFailsWhenMonitorCountMissing() {
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(monitorCountWhileOpen: 3)
            ),
            "monitor-count-while-open:transparent-panel"
        )
    }

    func testPanelReportFailsWhenTransparentAttributesDiffer() {
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(isOpaque: true)
            ),
            "panel-not-transparent:isOpaque"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(backgroundColorClear: false)
            ),
            "panel-not-transparent:backgroundColor"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(alphaValue: 0.5)
            ),
            "panel-not-transparent:alphaValue"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(styleMask: NSWindow.StyleMask.borderless.rawValue)
            ),
            "panel-not-transparent:styleMask"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(canBecomeKey: false)
            ),
            "panel-not-transparent:canBecomeKey"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(hasShadow: true)
            ),
            "panel-not-transparent:hasShadow"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(level: NSWindow.Level.normal.rawValue)
            ),
            "panel-not-transparent:level"
        )
    }

    func testValidPopoverReportProducesNoFailure() {
        XCTAssertNil(
            PrototypeSmokeValidation.modeFailure(mode: .standardPopover, report: popoverReport())
        )
        XCTAssertNil(
            PrototypeSmokeValidation.modeFailure(mode: .clearPopover, report: popoverReport())
        )
    }

    func testReduceTransparencyFallbackValidatesPopoverHostForTransparentRequest() {
        XCTAssertNil(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: popoverReport(requestedMode: PrototypeMode.transparentPanel.rawValue)
            )
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: popoverReport(
                    requestedMode: PrototypeMode.transparentPanel.rawValue,
                    popoverShownWhileOpen: false
                )
            ),
            "popover-not-shown:transparent-panel"
        )
    }

    func testUnknownEffectiveHostFailsGate() {
        var report = panelReport()
        report.effectiveHost = ""
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(mode: .transparentPanel, report: report),
            "unknown-effective-host:transparent-panel"
        )

        report = popoverReport()
        report.effectiveHost = "window"
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(mode: .standardPopover, report: report),
            "unknown-effective-host:standard-popover"
        )
    }

    func testCrossHostVisibilityFailsGate() {
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(popoverShownWhileOpen: true)
            ),
            "unexpected-popover-host:transparent-panel"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .standardPopover,
                report: popoverReport(panelShownWhileOpen: true)
            ),
            "unexpected-panel-host:standard-popover"
        )
    }

    func testPopoverReportFailsWhenNotShownOrFrameInvalid() {
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .standardPopover,
                report: popoverReport(popoverShownWhileOpen: false)
            ),
            "popover-not-shown:standard-popover"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .standardPopover,
                report: popoverReport(windowFrame: nil)
            ),
            "popover-missing-frame:standard-popover"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .standardPopover,
                report: popoverReport(frameWithinVisibleFrame: false)
            ),
            "popover-outside-visible-frame:standard-popover"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .standardPopover,
                report: popoverReport(monitorCountWhileOpen: 0)
            ),
            "monitor-count-while-open:standard-popover"
        )
    }

    func testPopoverReportFailsWhenStillShownAfterClose() {
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .standardPopover,
                report: popoverReport(popoverShownAfterClose: true)
            ),
            "popover-still-shown-after-close:standard-popover"
        )
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .clearPopover,
                report: popoverReport(popoverShownAfterClose: nil)
            ),
            "popover-still-shown-after-close:clear-popover"
        )
    }

    func testCoordinatorPopoverIsNotShownAfterClose() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        Self.retainedWindows.append(window)
        let anchorView = NSView(frame: NSRect(x: 20, y: 30, width: 24, height: 24))
        window.contentView = anchorView
        window.orderFront(nil)

        let coordinator = PrototypeHostCoordinator(
            contextProvider: {
                PrototypeHostCoordinator.Context(
                    anchorView: anchorView,
                    anchorRect: nil,
                    visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                    resolution: PrototypePolicy.resolve(
                        mode: .standardPopover,
                        reduceTransparency: false,
                        increaseContrast: false
                    )
                )
            },
            quit: {}
        )
        coordinator.setMode(.standardPopover)
        coordinator.show()
        XCTAssertTrue(coordinator.popoverIsShown)

        coordinator.close()
        drainRunLoop()

        XCTAssertFalse(coordinator.popoverIsShown)
        XCTAssertEqual(coordinator.activeMonitorCount, 0)
    }

    private static var retainedWindows: [NSWindow] = []

    func testLeakedWindowDetectionMatchesOnlyOwnVisibleWindows() {
        let leaked = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        leaked.identifier = NSUserInterfaceItemIdentifier("DebugGlassPrototype.test-leak")
        leaked.isReleasedWhenClosed = false
        leaked.orderFront(nil)
        defer { leaked.close() }

        let hidden = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hidden.identifier = NSUserInterfaceItemIdentifier("DebugGlassPrototype.test-hidden")
        hidden.isReleasedWhenClosed = false
        defer { hidden.close() }

        let foreign = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        foreign.identifier = NSUserInterfaceItemIdentifier("SomeOtherApp.window")
        foreign.isReleasedWhenClosed = false
        foreign.orderFront(nil)
        defer { foreign.close() }

        let leakedWindows = PrototypeSmokeValidation.leakedPrototypeWindows(
            in: [leaked, hidden, foreign]
        )
        XCTAssertEqual(leakedWindows.count, 1)
        XCTAssertTrue(leakedWindows.first === leaked)
    }

    func testPrototypeWindowIdentifiersShareDetectionPrefix() {
        XCTAssertTrue(
            PrototypePanelFactory.identifier.hasPrefix(
                PrototypeSmokeValidation.prototypeWindowIdentifierPrefix
            )
        )
        XCTAssertTrue(
            PrototypeAnchorWindow.anchorIdentifier.hasPrefix(
                PrototypeSmokeValidation.prototypeWindowIdentifierPrefix
            )
        )
        XCTAssertTrue(
            PrototypeBackdropWindow.backdropIdentifier.hasPrefix(
                PrototypeSmokeValidation.prototypeWindowIdentifierPrefix
            )
        )
    }

    func testCoordinatorVisibilityFollowsActualPanelVisibility() throws {
        let coordinator = makePanelCoordinator()
        coordinator.setMode(.transparentPanel)
        coordinator.show()

        XCTAssertEqual(coordinator.effectiveHost, .panel)
        XCTAssertTrue(coordinator.isVisible)
        XCTAssertTrue(try XCTUnwrap(coordinator.currentPanel).isVisible)

        coordinator.close()
        drainRunLoop()
        XCTAssertFalse(coordinator.isVisible)
        XCTAssertEqual(coordinator.activeMonitorCount, 0)
    }

    func testCoordinatorStaysNotVisibleWhenPanelPresenterFails() throws {
        let coordinator = makePanelCoordinator()
        coordinator.panelPresenter = { _ in }
        coordinator.setMode(.transparentPanel)
        coordinator.show()

        XCTAssertEqual(coordinator.effectiveHost, .panel)
        XCTAssertFalse(coordinator.isVisible)
        let panel = try XCTUnwrap(coordinator.currentPanel)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(
            PrototypeSmokeValidation.modeFailure(
                mode: .transparentPanel,
                report: panelReport(panelShownWhileOpen: panel.isVisible)
            ),
            "panel-not-shown"
        )

        coordinator.close()
        drainRunLoop()
        XCTAssertFalse(coordinator.isVisible)
        XCTAssertEqual(coordinator.activeMonitorCount, 0)
    }

    private func makePanelCoordinator() -> PrototypeHostCoordinator {
        PrototypeHostCoordinator(
            contextProvider: {
                PrototypeHostCoordinator.Context(
                    anchorView: nil,
                    anchorRect: NSRect(x: 900, y: 1050, width: 24, height: 24),
                    visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                    resolution: PrototypePolicy.resolve(
                        mode: .transparentPanel,
                        reduceTransparency: false,
                        increaseContrast: false
                    )
                )
            },
            quit: {}
        )
    }
}
