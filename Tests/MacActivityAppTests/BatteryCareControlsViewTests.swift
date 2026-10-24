import AppKit
import Combine
import SwiftUI
import XCTest
import MacActivityBatteryControl
import MacActivityCore
import ObjectiveC
@testable import MacActivityApp

@MainActor
final class BatteryCareControlsViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { AppLocalization.setPreferredLanguageIdentifier("en") }
    }

    override func tearDown() {
        MainActor.assumeIsolated { AppLocalization.setPreferredLanguageIdentifier(nil) }
        super.tearDown()
    }

    func testFourPagesRenderSameModelBeforeOriginalNavigation() async throws {
        let model = makeModel(service: BatteryControlsService(ready()), enabled: true)
        let preferences = PreferencesController(store: BatteryControlsMemoryStore(), launchService: NoopLaunchAtLoginService())
        for tab in DashboardTab.allCases {
            let dashboard = DashboardView(dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
                preferencesController: preferences, audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
                batteryCareModel: model, initialSelectedTab: tab)
            let host = hosting(dashboard)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            await settle()
            host.layoutSubtreeIfNeeded()
            let controls = try XCTUnwrap(views(host).compactMap { $0 as? BatteryCareNativeControls }.first)
            XCTAssertTrue(controls.model === model)
            let navigation = views(host).compactMap { $0 as? NSButton }.filter { $0.accessibilityRole() == .radioButton }
            XCTAssertEqual(navigation.count, 4)
            let slider = try control("batteryCare.limit", in: host, as: NSSlider.self)
            let sliderRect = slider.convert(slider.bounds, to: host)
            for button in navigation {
                let rect = button.convert(button.bounds, to: host)
                XCTAssertLessThan(sliderRect.maxY, rect.minY, "New controls precede, not replace, old navigation")
            }
            window.makeFirstResponder(slider)
            window.selectNextKeyView(slider)
            XCTAssertTrue(navigation.contains { window.firstResponder === $0 }, "Slider focus continues into the existing navigation")
            XCTAssertEqual(try control("batteryCare.mirror", in: host, as: NSTextField.self).stringValue, "Limit 80%")
            let current = try control("batteryCare.current", in: host, as: NSTextField.self)
            for _ in 0..<25 where current.stringValue != "Current 83% (system)" {
                await settle()
                host.layoutSubtreeIfNeeded()
            }
            XCTAssertEqual(current.stringValue, "Current 83% (system)")
        }
    }
    func testUnavailableUIKeepsOfflinePreferenceEditableAndReasonsFocusable() async throws {
        let store = BatteryControlsMemoryStore()
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let model = BatteryCareModel(preferences: preferences, service: UnavailableBatteryCareService())
        let host = hosting(BatteryCareControlsView(model: model))
        await settle()
        host.layoutSubtreeIfNeeded()
        let slider = try control("batteryCare.limit", in: host, as: NSSlider.self)
        XCTAssertTrue(slider.isEnabled, "Unknown capability must not block saving a disabled, valid preference")
        slider.keyDown(with: try key(123, "\u{f702}"))
        host.layoutSubtreeIfNeeded()
        await settle()
        XCTAssertEqual(try control("batteryCare.mirror", in: host, as: NSTextField.self).stringValue, "Preview 79%")
        slider.keyDown(with: try key(36, "\r"))
        await settle()
        XCTAssertEqual(store.values.map(\.batteryCare.limit), [79])
        XCTAssertFalse(model.presentation.savedEnabled)
        for id in ["batteryCare.discharge", "batteryCare.fullCharge"] {
            XCTAssertFalse(try control(id, in: host, as: NSButton.self).isEnabled)
        }
        let more = try control("batteryCare.more", in: host, as: NSButton.self)
        XCTAssertTrue(more.isEnabled)
        XCTAssertTrue(more.acceptsFirstResponder)
        XCTAssertEqual(more.accessibilityLabel(), "More battery settings")
        XCTAssertTrue(more.accessibilityHelp()?.contains("Capability not verified") == true)
        let current = try control("batteryCare.current", in: host, as: NSTextField.self)
        XCTAssertEqual(current.stringValue, "Current unknown (system)")
        XCTAssertNotEqual(current.accessibilityLabel(), slider.accessibilityLabel())
    }

    func testRegular100NativeFullChargeExplainsDisabledStartButKeepsCancelReachable() async throws {
        let model = makeModel(service: BatteryControlsService(ready(limit: 100)), enabled: true, limit: 100)
        await settle()
        let controls = BatteryCareNativeControls(model: model)
        let full = try control("batteryCare.fullCharge", in: controls, as: NSButton.self)
        XCTAssertFalse(full.isEnabled)
        XCTAssertTrue(full.accessibilityHelp()?.contains("Regular limit already allows a full charge") == true)
        XCTAssertEqual(BatteryCareText.backendReason("regularAlreadyAllowsFull"),
                       "Regular limit already allows a full charge")
        XCTAssertNotEqual(BatteryCareText.backendReason("regularAlreadyAllowsFull"),
                          BatteryCareText.string(.batteryCareFullTarget))

        let cancelling = makeModel(service: BatteryControlsService(ready(mode: .chargingToFull, limit: 100)),
                                   enabled: true, limit: 100)
        await settle()
        let cancelControls = BatteryCareNativeControls(model: cancelling)
        let cancel = try control("batteryCare.fullCharge", in: cancelControls, as: NSButton.self)
        XCTAssertEqual(cancel.title, "Cancel full charge")
        XCTAssertTrue(cancel.isEnabled)
    }

    func testNoBatteryPlaceholderDoesNotInventZeroOrAppliedLimit() async throws {
        let service = BatteryControlsService(.init(sample: .init(identity: nil, presence: .absent,
            sequence: 1, observedAtUptime: 100, systemPercentage: nil, externalPower: nil,
            isCharging: nil, lowBatteryProtection: nil)))
        let model = makeModel(service: service)
        let host = hosting(BatteryCareControlsView(model: model))
        await settle()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try control("batteryCare.mirror", in: host, as: NSTextField.self).stringValue, "No internal battery")
        XCTAssertEqual(try control("batteryCare.current", in: host, as: NSTextField.self).stringValue, "No internal battery")
        XCTAssertFalse(try control("batteryCare.limit", in: host, as: NSSlider.self).isEnabled)
    }

    func testPendingFullChargeCanCancelAndStopIsNotCoalescedWithSlider() async throws {
        let service = BatteryControlsService(ready())
        let model = makeModel(service: service, enabled: true)
        let host = hosting(BatteryCareControlsView(model: model))
        await settle()
        let full = try control("batteryCare.fullCharge", in: host, as: NSButton.self)
        XCTAssertTrue(full.accessibilityPerformPress())
        await settle()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(full.title, "Cancel full charge")
        XCTAssertTrue(full.isEnabled)
        XCTAssertFalse(try control("batteryCare.discharge", in: host, as: NSButton.self).isEnabled)
        let slider = try control("batteryCare.limit", in: host, as: NSSlider.self)
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertTrue(full.accessibilityPerformPress())
        await settle()
        let intents = await service.commands.map(\.intent)
        XCTAssertEqual(intents.filter { $0 == .cancelFullCharge }.count, 1)
        XCTAssertEqual(intents.filter { if case .setLimit = $0 { return true }; return false }, [.setLimit(82)])
        XCTAssertTrue(full.isEnabled, "Unknown stop keeps cancellation reachable")
        await service.releaseStart()
    }

    func testReturnCapturesCommittedValueBeforeNextPreviewAndEscape() async throws {
        let store = BatteryControlsMemoryStore()
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let model = BatteryCareModel(preferences: preferences, service: UnavailableBatteryCareService())
        let host = hosting(BatteryCareControlsView(model: model))
        await settle()
        let slider = try control("batteryCare.limit", in: host, as: NSSlider.self)
        slider.keyDown(with: try key(124, "\u{f703}"))
        slider.keyDown(with: try key(36, "\r"))
        slider.keyDown(with: try key(124, "\u{f703}"))
        slider.keyDown(with: try key(53, "\u{1b}"))
        await settle()
        XCTAssertEqual(store.values.map(\.batteryCare.limit), [81], "Escape cancels the new preview, not a prior committed input")
        XCTAssertNil(model.presentation.previewLimit)
    }

    func testRunningDischargeStopRemainsReachableAndReportsUnconfirmedRecovery() async throws {
        let snapshot = ready(mode: .discharging, recovery: .unconfirmed)
        let service = BatteryControlsService(snapshot)
        let model = makeModel(service: service, enabled: true)
        let host = hosting(BatteryCareControlsView(model: model))
        await settle()
        let stop = try control("batteryCare.discharge", in: host, as: NSButton.self)
        XCTAssertEqual(stop.title, "Stop discharge")
        XCTAssertTrue(stop.isEnabled)
        XCTAssertTrue(stop.accessibilityHelp()?.contains("Recovery unconfirmed") == true)
        XCTAssertTrue(stop.accessibilityPerformPress())
        await settle()
        let intents = await service.commands.map(\.intent)
        XCTAssertEqual(intents, [.stopDischarge])
        XCTAssertTrue(stop.accessibilityHelp()?.contains("Result unknown") == true)
    }

    func testRenderedDischargeStopDoesNotBecomeStartBeforeNextRender() async throws {
        try await checkRenderedStop(mode: .discharging, id: "batteryCare.discharge",
                                    title: "Stop discharge", intent: .stopDischarge)
    }

    func testRenderedFullChargeCancelDoesNotBecomeStartBeforeNextRender() async throws {
        try await checkRenderedStop(mode: .chargingToFull, id: "batteryCare.fullCharge",
                                    title: "Cancel full charge", intent: .cancelFullCharge)
    }

    private func checkRenderedStop(mode: BatteryCareTemporaryMode, id: String,
                                   title: String, intent: BatteryCareIntent) async throws {
        let service = BatteryControlsService(ready(mode: mode))
        let model = makeModel(service: service, enabled: true)
        let initial = expectation(description: "temporary mode received")
        let initialObservation = model.$presentation.first { $0.temporaryMode == mode }.sink { _ in initial.fulfill() }
        await fulfillment(of: [initial], timeout: 2)
        initialObservation.cancel()
        let controls = BatteryCareNativeControls(model: model)
        let button = try control(id, in: controls, as: NSButton.self)
        XCTAssertEqual(button.title, title)
        let received = expectation(description: "mode ended without native render")
        let observation = model.$presentation.first { $0.revision == 2 }.sink { _ in received.fulfill() }
        let regular = ready()
        await service.push(.init(settings: regular.settings, sample: regular.sample,
            capabilities: regular.capabilities, authorization: regular.authorization,
            recoveryStatus: .released, safetyLimits: regular.safetyLimits, revision: 2))
        await fulfillment(of: [received], timeout: 2)
        observation.cancel()
        XCTAssertTrue(model.presentation.startDischarge.isEnabled)
        XCTAssertTrue(model.presentation.startFullCharge.isEnabled)
        XCTAssertEqual(button.title, title, "No updateNSView has presented a start action")
        XCTAssertTrue(button.accessibilityPerformPress())
        await settle()
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [intent])
        await service.releaseStart()
    }

    func testPendingLimitCommitSurvivesConfigureAndPreservesLaterPreview() async throws {
        try await checkPendingLimitCommit(escapeBeforeSave: false, saveFails: false)
    }

    func testFallbackSwitchCancelsUncommittedPreviewAndRestoresKeyboardEditing() async throws {
        let store = BatteryControlsMemoryStore()
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let service = BatteryControlsService(.init())
        let model = BatteryCareModel(preferences: preferences, service: service)
        let host = DashboardListTestHost(DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: preferences,
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            batteryCareModel: model
        ).environment(\.dashboardPresentationIsPresented, false), height: 400)
        defer { host.close() }
        await settle(); host.settle()
        let original = try control("batteryCare.limit", in: host.controller.view, as: NSSlider.self)
        original.keyDown(with: try key(124, "\u{f703}"))
        host.settle()
        XCTAssertEqual(model.presentation.previewLimit, 81)
        host.resize(height: 80); host.settle()
        let fallback = try control("batteryCare.limit", in: host.controller.view, as: NSSlider.self)
        XCTAssertFalse(fallback === original)
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertEqual(fallback.integerValue, 80)
        fallback.keyDown(with: try key(36, "\r"))
        fallback.keyDown(with: try key(53, "\u{1b}"))
        XCTAssertNil(model.presentation.previewLimit, "rebuilt idle slider must not strand the old preview")
        fallback.keyDown(with: try key(124, "\u{f703}"))
        XCTAssertEqual(model.presentation.previewLimit, 81)
        host.resize(height: 400); host.settle()
        let restored = try control("batteryCare.limit", in: host.controller.view, as: NSSlider.self)
        XCTAssertFalse(restored === fallback)
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertEqual(restored.integerValue, 80)
        XCTAssertTrue(store.values.isEmpty)
        let before = await service.commands
        XCTAssertTrue(before.isEmpty, "layout changes only cancel preview, never send a command")
        restored.keyDown(with: try key(124, "\u{f703}"))
        XCTAssertEqual(model.presentation.previewLimit, 81)
        restored.keyDown(with: try key(53, "\u{1b}"))
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertEqual(restored.integerValue, 80)
        restored.keyDown(with: try key(124, "\u{f703}"))
        restored.keyDown(with: try key(36, "\r"))
        for _ in 0..<25 where store.values.isEmpty { await settle() }
        XCTAssertEqual(store.values.map(\.batteryCare.limit), [81])
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setLimit(81)])
    }

    func testFallbackSwitchPreservesSubmittedPendingLimitWithoutSendingLayoutCommands() async throws {
        let entered = expectation(description: "startup held across layout changes")
        let service = BatteryControlsService(.init(), startupEntered: entered)
        let store = BatteryControlsMemoryStore()
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let model = BatteryCareModel(preferences: preferences, service: service)
        await fulfillment(of: [entered], timeout: 2)
        let host = DashboardListTestHost(DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: preferences,
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            batteryCareModel: model
        ).environment(\.dashboardPresentationIsPresented, false), height: 400)
        defer { host.close() }
        host.settle()
        let original = try control("batteryCare.limit", in: host.controller.view, as: NSSlider.self)
        original.keyDown(with: try key(124, "\u{f703}"))
        original.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(model.presentation.pendingLimit, 81)
        original.keyDown(with: try key(124, "\u{f703}"))
        XCTAssertEqual(model.presentation.previewLimit, 82)
        host.resize(height: 80); host.settle()
        let fallback = try control("batteryCare.limit", in: host.controller.view, as: NSSlider.self)
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertEqual(model.presentation.pendingLimit, 81)
        XCTAssertEqual(fallback.integerValue, 81)
        host.resize(height: 400); host.settle()
        let restored = try control("batteryCare.limit", in: host.controller.view, as: NSSlider.self)
        restored.keyDown(with: try key(36, "\r"))
        restored.keyDown(with: try key(53, "\u{1b}"))
        XCTAssertEqual(model.presentation.pendingLimit, 81)
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertTrue(store.values.isEmpty)
        let before = await service.commands
        XCTAssertTrue(before.isEmpty)
        await service.releaseStartup()
        for _ in 0..<25 where store.values.isEmpty { await settle() }
        XCTAssertNil(model.presentation.pendingLimit)
        XCTAssertEqual(store.values.map(\.batteryCare.limit), [81])
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setLimit(81)], "only the already-submitted commit may send")
    }

    func testPendingLimitCommitEscapeRestoresPendingBaselineAcrossConfigure() async throws {
        try await checkPendingLimitCommit(escapeBeforeSave: true, saveFails: false)
    }

    func testFailedPendingLimitCommitPreservesLaterPreviewButEscapeRestoresAcceptedLimit() async throws {
        try await checkPendingLimitCommit(escapeBeforeSave: false, saveFails: true)
    }

    func testFailedPendingLimitCommitAfterEscapeRestoresAcceptedLimit() async throws {
        try await checkPendingLimitCommit(escapeBeforeSave: true, saveFails: true)
    }

    private func checkPendingLimitCommit(escapeBeforeSave: Bool, saveFails: Bool) async throws {
        let entered = expectation(description: "startup snapshot held")
        let service = BatteryControlsService(.init(), startupEntered: entered)
        let store = BatteryControlsMemoryStore()
        store.fails = saveFails
        let model = BatteryCareModel(preferences: .init(store: store,
            launchService: NoopLaunchAtLoginService()), service: service)
        await fulfillment(of: [entered], timeout: 2)
        let controls = BatteryCareNativeControls(model: model)
        let slider = try control("batteryCare.limit", in: controls, as: NSSlider.self)
        slider.keyDown(with: try key(124, "\u{f703}"))
        slider.keyDown(with: try key(36, "\r"))
        await settle() // The captured commit is now waiting on startup, not local persistence.
        XCTAssertTrue(store.values.isEmpty)
        XCTAssertEqual(model.presentation.savedLimit, 80)
        controls.update(model.presentation)
        XCTAssertEqual(slider.integerValue, 81, "Old saved=80 must not overwrite a committed pending input")
        XCTAssertEqual(try control("batteryCare.mirror", in: controls, as: NSTextField.self).stringValue, "Preview 81%")
        slider.keyDown(with: try key(124, "\u{f703}"))
        XCTAssertEqual(model.presentation.previewLimit, 82)
        controls.update(model.presentation)
        if escapeBeforeSave {
            slider.keyDown(with: try key(53, "\u{1b}"))
            controls.update(model.presentation)
            XCTAssertNil(model.presentation.previewLimit)
            XCTAssertEqual(slider.integerValue, 81)
        }
        await service.releaseStartup()
        await settle()
        controls.update(model.presentation)
        XCTAssertEqual(store.values.map(\.batteryCare.limit), saveFails ? [] : [81])
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), saveFails ? [] : [.setLimit(81)])
        XCTAssertEqual(model.presentation.savedLimit, saveFails ? 80 : 81)
        XCTAssertEqual(model.presentation.saveFailure, saveFails ? .limit : nil)
        if !escapeBeforeSave {
            XCTAssertEqual(model.presentation.previewLimit, 82, "Save completion must not consume a later preview")
            XCTAssertEqual(slider.integerValue, 82)
            slider.keyDown(with: try key(53, "\u{1b}"))
            XCTAssertEqual(slider.integerValue, saveFails ? 80 : 81, "Escape uses the accepted baseline after save resolves")
            controls.update(model.presentation)
        }
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertEqual(slider.integerValue, saveFails ? 80 : 81)
        slider.keyDown(with: try key(124, "\u{f703}"))
        XCTAssertEqual(model.presentation.previewLimit, saveFails ? 81 : 82)
        slider.keyDown(with: try key(53, "\u{1b}"))
    }

    func testSettingsUsesNativeDisabledToggleAndLocalizedMachineReason() async throws {
        let snapshot = ready(regular: .unsupported(reason: "helperIncompatible"), pause: "internal.untrusted.rawError")
        let model = makeModel(service: BatteryControlsService(snapshot))
        let host = hosting(BatteryCareSettingsView(model: model))
        await settle()
        let toggle = try control("batteryCare.management", in: host, as: NSButton.self)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertEqual(toggle.accessibilityHelp(), "Helper incompatible")
        let fields = views(host).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertFalse(fields.contains { $0.contains("internal.untrusted.rawError") })
        XCTAssertTrue(fields.contains("Helper incompatible"))
    }

    func testNativeAccessibilityValuesReasonsAndFocusAreNotOnlyHoverText() async throws {
        for (snapshot, reason) in [
            (ready(regular: .unverified), "Capability not verified"),
            (ready(authorization: .notAuthorized), "Not authorized"),
            (ready(regular: .unsupported(reason: "helperIncompatible")), "Helper incompatible"),
            (ready(recovery: .unconfirmed), "Recovery unconfirmed")
        ] {
            let model = makeModel(service: BatteryControlsService(snapshot), enabled: true)
            let controller = NSHostingController(rootView: BatteryCareControlsView(model: model))
            let window = NSWindow(contentViewController: controller)
            defer { window.close() }
            window.setContentSize(NSSize(width: 420, height: 200))
            window.orderFront(nil)
            await settle()
            controller.view.layoutSubtreeIfNeeded()
            let more = try control("batteryCare.more", in: controller.view, as: NSButton.self)
            let slider = try control("batteryCare.limit", in: controller.view, as: NSSlider.self)
            XCTAssertTrue(window.makeFirstResponder(more))
            XCTAssertTrue(window.firstResponder === more)
            XCTAssertTrue(more.nextKeyView === slider)
            window.selectNextKeyView(more)
            XCTAssertTrue(window.firstResponder === slider)
            XCTAssertTrue(more.accessibilityHelp()?.contains(reason) == true)
            XCTAssertEqual(slider.accessibilityValue() as? Int, 80)
            slider.keyDown(with: try key(124, "\u{f703}"))
            await settle()
            XCTAssertTrue(slider.accessibilityValueDescription()?.contains("Preview 81%") == true)
            XCTAssertEqual(slider.accessibilityValue() as? Int, 81)
        }
    }

    func testMoreButtonOpensLightweightSettingsWithSameModel() async throws {
        let model = makeTestBatteryCareModel()
        let controller = NSHostingController(rootView: BatteryCareControlsView(model: model))
        let window = NSWindow(contentViewController: controller)
        defer { window.close() }
        window.setContentSize(NSSize(width: 420, height: 200))
        window.orderFront(nil)
        await settle()
        let more = try control("batteryCare.more", in: controller.view, as: NSButton.self)
        XCTAssertTrue(more.accessibilityPerformPress())
        await settle()
        let settings = try XCTUnwrap(NSApplication.shared.windows.compactMap {
            $0.contentViewController as? NSHostingController<BatteryCareSettingsView>
        }.first { $0.rootView.model === model })
        XCTAssertTrue(settings.rootView.model === model)
        let toggle = try control("batteryCare.management", in: settings.view, as: NSButton.self)
        XCTAssertFalse(toggle.isEnabled)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertEqual(toggle.accessibilityHelp(), "Capability not verified")
        XCTAssertTrue(more.accessibilityPerformPress())
    }

    func testNativeKeyboardArrowsPreviewReturnCommitsAndEscapeCancels() throws {
        var value = 80
        var saved = 80
        var commits: [Int] = []
        var cancels = 0
        let host = NSHostingView(rootView: BatteryCareLimitSlider(
            value: Binding(get: { value }, set: { value = $0 }), isEnabled: true,
            onCommit: { commits.append(value); saved = value }, onCancel: { cancels += 1; value = saved }))
        host.frame = NSRect(x: 0, y: 0, width: 250, height: 30)
        host.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(views(host).compactMap { $0 as? NSSlider }.first)
        slider.keyDown(with: try key(124, "\u{f703}"))
        slider.keyDown(with: try key(124, "\u{f703}"))
        XCTAssertEqual(value, 82)
        XCTAssertEqual(commits, [])
        slider.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(commits, [82])
        slider.keyDown(with: try key(123, "\u{f702}"))
        slider.keyDown(with: try key(53, "\u{1b}"))
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(value, 82)
        XCTAssertEqual(commits, [82])
        slider.keyDown(with: try key(124, "\u{f703}"))
        XCTAssertEqual(value, 83, "Escape restores the native editing baseline before another event")
    }

    func testNativeMouseTrackingCommitsOnlyOnceAfterMouseUp() throws {
        for endX: CGFloat in [240, 450] {
            let (slider, probe, window) = mouseFixture()
            defer { window.close() }
            var value = 80
            var previews: [Int] = []
            var commits: [Int] = []
            let windowNumber = window.windowNumber
            slider.configure(value: value, isEnabled: true,
                onPreview: { value = $0; previews.append($0); XCTAssertTrue(commits.isEmpty) },
                onCommit: {
                    XCTAssertEqual(NSApp.currentEvent?.type, .leftMouseUp)
                    XCTAssertEqual(NSApp.currentEvent?.windowNumber, windowNumber)
                    commits.append(value)
                }, onCancel: { XCTFail("Matching mouse-up must commit, not cancel") })
            let start = ProcessInfo.processInfo.systemUptime
            let up = try mouse(.leftMouseUp, x: endX, slider: slider, timestamp: start + 0.03)
            if endX == 450 { XCTAssertFalse(window.contentView!.bounds.contains(up.locationInWindow)) }
            try track(slider, followups: [mouse(.leftMouseDragged, x: 200, slider: slider, timestamp: start + 0.01),
                                         mouse(.leftMouseDragged, x: endX, slider: slider, timestamp: start + 0.02), up])
            XCTAssertTrue(probe.startedOnKnob)
            XCTAssertTrue(probe.events.contains(.leftMouseDragged))
            XCTAssertEqual(probe.stopEvent, .leftMouseUp, "Observe native stopTracking, not merely an empty event queue")
            XCTAssertEqual(probe.stopWindow, window.windowNumber)
            XCTAssertEqual(try XCTUnwrap(probe.stopTimestamp), up.timestamp, accuracy: 0.000001)
            if endX == 450 {
                XCTAssertFalse(window.contentView!.bounds.contains(try XCTUnwrap(probe.stopLocation)),
                               "The event actually consumed by native tracking must be outside the window")
            }
            XCTAssertGreaterThan(value, 80)
            XCTAssertEqual(commits, [value])
            XCTAssertEqual(previews.last, value)
        }
    }

    func testNativeMouseTrackingReturnWithoutMouseUpCancelsInsteadOfCommitting() throws {
        let (slider, probe, window) = mouseFixture()
        defer { window.close() }
        var previews: [Int] = []
        var commits = 0
        var cancels = 0
        slider.configure(value: 80, isEnabled: true, onPreview: { previews.append($0) },
            onCommit: { commits += 1 }, onCancel: { cancels += 1 })
        try track(slider, followups: [], pressedButtons: 0)
        XCTAssertTrue(probe.startedOnKnob)
        XCTAssertEqual(probe.stopEvent, .leftMouseDown, "AppKit's early return is not a mouse-up")
        XCTAssertFalse(previews.isEmpty)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(slider.integerValue, 80)
    }

    func testEscapeOrWindowCloseDuringNativeDragCannotCommitOnLaterMouseUp() throws {
        for closeWindow in [false, true] {
            let (slider, probe, window) = mouseFixture()
            defer { probe.onContinue = {}; window.close() }
            var value = 80
            var commits = 0
            var cancels = 0
            slider.configure(value: value, isEnabled: true, onPreview: { value = $0 },
                onCommit: { commits += 1 }, onCancel: { cancels += 1; value = 80 })
            let escape = try key(53, "\u{1b}")
            var cancelled = false
            probe.onContinue = {
                guard !cancelled else { return }
                cancelled = true
                if closeWindow { window.close() } else { slider.keyDown(with: escape) }
            }
            try track(slider, followups: [mouse(.leftMouseDragged, x: 200, slider: slider),
                                         mouse(.leftMouseDragged, x: 450, slider: slider),
                                         mouse(.leftMouseUp, x: 450, slider: slider)])
            XCTAssertTrue(cancelled)
            XCTAssertEqual(commits, 0)
            XCTAssertEqual(cancels, 1)
            XCTAssertEqual(value, 80)
            XCTAssertEqual(slider.integerValue, 80)
        }
    }

    func testNativeMouseUpFromAnotherWindowDoesNotCommit() throws {
        let (slider, probe, window) = mouseFixture()
        let otherWindow = NSWindow(contentRect: NSRect(x: 500, y: 100, width: 100, height: 80),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        otherWindow.orderFront(nil)
        defer { window.close(); otherWindow.close() }
        var commits = 0
        var cancels = 0
        slider.configure(value: 80, isEnabled: true, onPreview: { _ in },
            onCommit: { commits += 1 }, onCancel: { cancels += 1 })
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.03, windowNumber: otherWindow.windowNumber,
            context: nil, eventNumber: 17, clickCount: 1, pressure: 0))
        try track(slider, followups: [mouse(.leftMouseDragged, x: 200, slider: slider), up,
                                     mouse(.leftMouseUp, x: 230, slider: slider, timestamp: up.timestamp + 0.01)])
        XCTAssertEqual(probe.stopEvent, .leftMouseUp)
        XCTAssertEqual(probe.stopWindow, otherWindow.windowNumber)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(cancels, 1)
    }

    func testNativeMousePreviewDoesNotSaveOrSendAndMatchingUpSendsFinalLimitOnce() async throws {
        let store = BatteryControlsMemoryStore()
        let service = BatteryControlsService(ready())
        let model = BatteryCareModel(preferences: PreferencesController(store: store,
            launchService: NoopLaunchAtLoginService()), service: service, now: { 101 })
        await settle()
        let controls = BatteryCareNativeControls(model: model)
        let nativeSlider = try control("batteryCare.limit", in: controls, as: BatteryCareNativeSlider.self)
        // Keep the real controls' Model callbacks; isolate native input from SwiftUI/window layout animation.
        let (slider, probe, window) = mouseFixture(slider: nativeSlider)
        defer { window.close() }
        var previews: [Int] = []
        let observation = model.$presentation.sink { presentation in
            if let preview = presentation.previewLimit {
                previews.append(preview)
                XCTAssertTrue(store.values.isEmpty, "Every down/drag preview precedes persistence")
            }
        }
        defer { observation.cancel() }
        try track(slider, followups: [], pressedButtons: 0)
        await settle()
        XCTAssertTrue(store.values.isEmpty)
        var commands = await service.commands
        XCTAssertTrue(commands.isEmpty, "Returning without up must not send a service command")
        XCTAssertNil(model.presentation.previewLimit)
        previews.removeAll()
        try track(slider, followups: [mouse(.leftMouseDragged, x: 200, slider: slider),
                                     mouse(.leftMouseDragged, x: 230, slider: slider),
                                     mouse(.leftMouseUp, x: 230, slider: slider)])
        XCTAssertEqual(probe.stopEvent, .leftMouseUp)
        let final = try XCTUnwrap(previews.last)
        XCTAssertGreaterThan(final, 80)
        await settle()
        XCTAssertEqual(store.values.map(\.batteryCare.limit), [final])
        commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setLimit(final)])
        XCTAssertNil(model.presentation.previewLimit)
    }

    func testRenderedRowsGrowForEnglishChineseAndLargeTextWithoutClippingCancel() async throws {
        for language in ["en", "zh-Hans", "de"] {
            AppLocalization.setPreferredLanguageIdentifier(language)
            for size in [DynamicTypeSize.large, .accessibility3] {
                let model = makeModel(service: BatteryControlsService(ready(mode: .chargingToFull)), enabled: true)
                let host = hosting(BatteryCareControlsView(model: model)
                    .environment(\.dynamicTypeSize, size)
                    .environment(\._accessibilityReduceMotion, true)
                    .environment(\._accessibilityReduceTransparency, true))
                await settle()
                let native = try XCTUnwrap(views(host).compactMap { $0 as? BatteryCareNativeControls }.first)
                let full = try control("batteryCare.fullCharge", in: host, as: NSButton.self)
                let cancelTitle = AppLocalization.string(.batteryCareCancelFullCharge)
                for _ in 0..<25 where full.title != cancelTitle || !full.isEnabled {
                    await settle()
                    host.layoutSubtreeIfNeeded()
                }
                let fitting = host.fittingSize
                host.frame.size = NSSize(width: 420, height: fitting.height)
                host.layoutSubtreeIfNeeded()
                let slider = try control("batteryCare.limit", in: host, as: NSSlider.self)
                let current = try control("batteryCare.current", in: host, as: NSTextField.self)
                XCTAssertTrue(full.isEnabled)
                XCTAssertEqual(full.title, AppLocalization.string(.batteryCareCancelFullCharge))
                XCTAssertGreaterThanOrEqual(full.font?.pointSize ?? 0, NSFont.systemFontSize)
                XCTAssertTrue(native.bounds.contains(full.frame))
                XCTAssertTrue(native.bounds.contains(slider.frame))
                XCTAssertTrue(native.bounds.contains(current.frame))
                XCTAssertLessThan(full.frame.maxY, slider.frame.minY)
                XCTAssertGreaterThanOrEqual(full.frame.height, (full.title as NSString).boundingRect(
                    with: NSSize(width: full.frame.width - 16, height: 1000), options: .usesLineFragmentOrigin,
                    attributes: [.font: full.font!]).height)
                print("A6 layout language=\(language) size=\(size) width=420 height=\(fitting.height) cancel=\(full.frame) current=\(current.frame)")
            }
        }
    }

    func testInitialUnavailableLayoutKeepsHeightStableAcrossPreviewDigits() async throws {
        for size in [DynamicTypeSize.large, .accessibility3] {
            let model = makeTestBatteryCareModel()
            let host = hosting(BatteryCareControlsView(model: model).environment(\.dynamicTypeSize, size))
            await settle()
            let initial = host.fittingSize.height
            print("A6 initial unavailable width=420 size=\(size) height=\(initial)")
            for value in [50, 80, 100] {
                model.previewLimit(value)
                await settle()
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.height, initial, accuracy: 0.5)
                XCTAssertEqual(try control("batteryCare.mirror", in: host, as: NSTextField.self).stringValue, "Preview \(value)%")
            }
            model.cancelPreview()
        }
    }

    func testNativeAccessibilityIncrementsCoalescePerRunLoopAndRespectBounds() async throws {
        var value = 98
        var commits: [Int] = []
        let host = NSHostingView(rootView: BatteryCareLimitSlider(
            value: Binding(get: { value }, set: { value = $0 }), isEnabled: true,
            onCommit: { commits.append(value) }, onCancel: {}))
        host.frame = NSRect(x: 0, y: 0, width: 250, height: 30)
        host.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(views(host).compactMap { $0 as? NSSlider }.first)
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertTrue(slider.accessibilityPerformIncrement())
        XCTAssertEqual(value, 100)
        XCTAssertEqual(commits, [])
        await settle()
        XCTAssertEqual(commits, [100])
        XCTAssertTrue(slider.accessibilityPerformDecrement())
        await settle()
        XCTAssertEqual(commits, [100, 99])
        XCTAssertEqual(slider.accessibilityLabel(), "Charge limit")
    }

    func testDisabledNativeSliderRejectsKeyboardAndAccessibilityInput() throws {
        var value = 80
        var commits = 0
        let host = NSHostingView(rootView: BatteryCareLimitSlider(
            value: Binding(get: { value }, set: { value = $0 }), isEnabled: false,
            onCommit: { commits += 1 }, onCancel: {}))
        host.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(views(host).compactMap { $0 as? NSSlider }.first)
        slider.keyDown(with: try key(124, "\u{f703}"))
        slider.keyDown(with: try key(36, "\r"))
        XCTAssertFalse(slider.accessibilityPerformIncrement())
        XCTAssertEqual(value, 80)
        XCTAssertEqual(commits, 0)
    }

    private func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func mouseFixture(slider suppliedSlider: BatteryCareNativeSlider? = nil) -> (BatteryCareNativeSlider, BatterySliderTrackingProbe, NSWindow) {
        let slider = suppliedSlider ?? BatteryCareNativeSlider()
        slider.frame = NSRect(x: 20, y: 20, width: 250, height: 24)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(slider)
        window.orderFront(nil)
        let probe = BatterySliderTrackingProbe()
        let target = slider.target
        let action = slider.action
        let value = slider.integerValue
        slider.cell = probe
        slider.minValue = 50
        slider.maxValue = 100
        slider.integerValue = value
        slider.isContinuous = true
        slider.target = target
        slider.action = action
        return (slider, probe, window)
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, slider: NSSlider, timestamp: TimeInterval? = nil) throws -> NSEvent {
        let window = try XCTUnwrap(slider.window)
        let point = slider.convert(NSPoint(x: x, y: slider.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
            location: point, modifierFlags: [],
            timestamp: timestamp ?? ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 17, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        return event
    }

    private func track(_ slider: NSSlider, followups: [NSEvent], pressedButtons: UInt = 1) throws {
        let cell = try XCTUnwrap(slider.cell as? NSSliderCell)
        let down = try mouse(.leftMouseDown, x: cell.knobRect(flipped: slider.isFlipped).midX, slider: slider,
                             timestamp: (followups.map(\.timestamp).min() ?? ProcessInfo.processInfo.systemUptime) - 0.01)
        XCTAssertTrue(slider.window?.contentView?.hitTest(down.locationInWindow) === slider)
        NSApp.postEvent(down, atStart: false)
        for event in followups { NSApp.postEvent(event, atStart: false) }
        defer {
            for _ in followups { _ = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) }
        }
        let dispatched = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: Date(), inMode: .default, dequeue: true))
        XCTAssertEqual(dispatched.windowNumber, slider.window?.windowNumber)
        XCTAssertEqual(NSApp.currentEvent?.type, .leftMouseDown)
        XCTAssertEqual(dispatched.timestamp, down.timestamp, accuracy: 0.000001)
        // postEvent does not set HID state. Override only this public process-local getter;
        // the native cell must still consume the queued drag/up and report its own stop boundary.
        let method = try XCTUnwrap(class_getClassMethod(NSEvent.self, NSSelectorFromString("pressedMouseButtons")))
        let imp = imp_implementationWithBlock({ (_: AnyObject) -> UInt in pressedButtons } as @convention(block) (AnyObject) -> UInt)
        let original = method_setImplementation(method, imp)
        defer { method_setImplementation(method, original); imp_removeBlock(imp) }
        // AppKit rebases dequeued synthetic event coordinates; pass the original knob-local down.
        slider.mouseDown(with: down)
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private func hosting<V: View>(_ view: V) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func control<T: NSView>(_ id: String, in host: NSView, as type: T.Type) throws -> T {
        try XCTUnwrap(views(host).first { $0.accessibilityIdentifier() == id } as? T, id)
    }

    private func makeModel(service: BatteryControlsService, enabled: Bool = false, limit: Int = 80) -> BatteryCareModel {
        let preferences = PreferencesController(store: BatteryControlsMemoryStore(enabled: enabled, limit: limit), launchService: NoopLaunchAtLoginService())
        return BatteryCareModel(preferences: preferences, service: service, now: { 101 })
    }

    private func ready(mode: BatteryCareTemporaryMode = .none, recovery: BatteryCareRecoveryStatus = .released,
                       regular: BatteryCareCapability = .verified(recordID: "test-only"), pause: String? = nil,
                       authorization: BatteryCareAuthorization = .authorized, limit: Int = 80) -> BatteryCareSnapshot {
        .init(settings: try! .init(isEnabled: true, limit: limit),
            sample: .init(identity: .init(batteryID: "ui", modelIdentifier: "test", osBuild: "test"),
                presence: .internalBattery, sequence: 1, observedAtUptime: 100, systemPercentage: 83,
                externalPower: true, isCharging: false, lowBatteryProtection: false),
            capabilities: Dictionary(uniqueKeysWithValues: BatteryCareOperation.allCases.map { ($0, $0 == .regularLimit ? regular : .verified(recordID: "test-only")) }),
            authorization: authorization, recoveryStatus: recovery,
            safetyLimits: try! .init(sampleIntervalNanoseconds: 1, maxSampleAgeNanoseconds: 20,
                maxCommandAgeNanoseconds: 20, maxReadbackNanoseconds: 20, maxStopNanoseconds: 20,
                leaseNanoseconds: 50, maxTemporaryModeNanoseconds: 100, maxNoProgressNanoseconds: 40), revision: 1,
            temporaryMode: mode, pauseReason: pause)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(40)) }
}

private final class BatterySliderTrackingProbe: NSSliderCell {
    var startedOnKnob = false
    var events: [NSEvent.EventType] = []
    var stopEvent: NSEvent.EventType?
    var stopWindow: Int?
    var stopTimestamp: TimeInterval?
    var stopLocation: NSPoint?
    var onContinue: () -> Void = {}
    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        startedOnKnob = knobRect(flipped: controlView.isFlipped).contains(startPoint)
        return super.startTracking(at: startPoint, in: controlView)
    }
    override func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool {
        let result = super.continueTracking(last: lastPoint, current: currentPoint, in: controlView)
        if let event = NSApp.currentEvent { events.append(event.type) }
        onContinue()
        return result
    }
    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        stopEvent = NSApp.currentEvent?.type
        stopWindow = NSApp.currentEvent?.windowNumber
        stopTimestamp = NSApp.currentEvent?.timestamp
        stopLocation = NSApp.currentEvent?.locationInWindow
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
    }
}

@MainActor
func makeTestBatteryCareModel(preferences: PreferencesController? = nil) -> BatteryCareModel {
    BatteryCareModel(preferences: preferences ?? PreferencesController(
        store: BatteryControlsMemoryStore(), launchService: NoopLaunchAtLoginService()),
        service: UnavailableBatteryCareService())
}

private final class BatteryControlsMemoryStore: PreferencesStoring, @unchecked Sendable {
    var values: [AppPreferences] = []
    var fails = false
    let enabled: Bool
    let limit: Int
    init(enabled: Bool = false, limit: Int = 80) { self.enabled = enabled; self.limit = limit }
    func load() -> AppPreferences {
        var value = AppPreferences.default
        value.batteryCare = try! .init(isEnabled: enabled, limit: limit)
        return value
    }
    func save(_ value: AppPreferences) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        values.append(value)
    }
}

// Reply/recording only. No admission, thresholds or synthetic policy transitions.
private actor BatteryControlsService: BatteryCareServicing {
    var value: BatteryCareSnapshot
    var commands: [BatteryCareCommand] = []
    private var held: CheckedContinuation<Void, Never>?
    private var continuation: AsyncStream<BatteryCareSnapshot>.Continuation?
    private var startupEntered: XCTestExpectation?
    private var startupHeld: CheckedContinuation<Void, Never>?
    init(_ value: BatteryCareSnapshot, startupEntered: XCTestExpectation? = nil) {
        self.value = value
        self.startupEntered = startupEntered
    }
    func snapshot() async -> BatteryCareSnapshot {
        if let startupEntered {
            self.startupEntered = nil
            await withCheckedContinuation { startupHeld = $0; startupEntered.fulfill() }
        }
        return value
    }
    func releaseStartup() { startupHeld?.resume(); startupHeld = nil }
    func updates() -> AsyncStream<BatteryCareSnapshot> {
        let (stream, continuation) = AsyncStream<BatteryCareSnapshot>.makeStream()
        self.continuation = continuation
        continuation.yield(value)
        return stream
    }
    func push(_ value: BatteryCareSnapshot) { self.value = value; continuation?.yield(value) }
    func send(_ command: BatteryCareCommand) async -> BatteryCareReply {
        commands.append(command)
        if command.intent == .startFullCharge { await withCheckedContinuation { held = $0 } }
        return .init(requestID: command.requestID, generation: command.generation, revision: value.revision, outcome: .outcomeUnknown)
    }
    func releaseStart() { held?.resume(); held = nil }
    func handleLifecycle(_ event: BatteryCareLifecycleEvent, generation: UInt64) -> BatteryCareReply {
        .init(requestID: UUID(), generation: generation, revision: value.revision, outcome: .outcomeUnknown)
    }
}
