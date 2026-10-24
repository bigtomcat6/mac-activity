import AppKit
import Combine
import MacActivityBatteryControl
import MacActivityCore
import XCTest
@testable import MacActivityApp

@MainActor
final class BatteryCareIntegrationTests: XCTestCase {
    func testCommittedLimitFlowsThroughRealSessionAndPolicy() async throws {
        // At p78, L80 allows charging; the committed L75 must instead inhibit it.
        let backend = IntegrationBatteryBackend(context: try syntheticContext(percentage: 78))
        let session = BatteryCareSession(backend: backend, now: { 101 })
        let store = IntegrationBatteryPreferences()
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let model = BatteryCareModel(preferences: preferences, service: session, now: { 101 })
        await model.setManagementEnabled(true)
        XCTAssertEqual(store.saved.map(\.batteryCare), [try .init(isEnabled: true, limit: 80)])
        var effects = await backend.effects
        XCTAssertEqual(effects, [.allowCharging])

        model.previewLimit(76)
        model.previewLimit(75)
        XCTAssertEqual(model.presentation.previewLimit, 75)
        XCTAssertEqual(model.presentation.savedLimit, 80)
        XCTAssertEqual(store.saved.count, 1)
        effects = await backend.effects
        XCTAssertEqual(effects, [.allowCharging], "preview must not reach the real Policy/backend")

        let held = expectation(description: "new limit apply continuation installed")
        await backend.suspendNextApply(held)
        let committed = XCTestExpectation(description: "limit commit returned")
        let joined = XCTestExpectation(description: "limit commit cleanup joined")
        let commit = Task { await model.commitPreview(); committed.fulfill(); joined.fulfill() }
        cleanUpCommit(commit, finished: joined, backend: backend)
        try await waitFor(held)
        let pending = expectation(description: "Model receives Session pending snapshot")
        let pendingObserver = model.$presentation.first(where: {
            $0.acceptedSettings?.limit == 75 && $0.isPending
        }).sink { _ in pending.fulfill() }
        defer { pendingObserver.cancel() }
        try await waitFor(pending)
        XCTAssertEqual(store.saved.map(\.batteryCare), [try .init(isEnabled: true, limit: 80),
                                                       try .init(isEnabled: true, limit: 75)])
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertNil(model.presentation.effectiveTarget)
        XCTAssertEqual(model.presentation.readback, .unknown)
        XCTAssertEqual(model.presentation.physicalObservation, .unknown)
        effects = await backend.effects
        XCTAssertEqual(effects, [.allowCharging, .inhibitCharging])
        let heldEffect = await backend.heldEffect
        _ = try XCTUnwrap(heldEffect == .inhibitCharging ? heldEffect : nil, "Expected limit inhibition before supplying its receipt")

        await backend.resumeApply(with: receipt(.inhibitCharging, readback: .confirmed(.inhibited)))
        try await waitFor(committed)
        XCTAssertEqual(preferences.state.batteryCare, try .init(isEnabled: true, limit: 75))
        XCTAssertEqual(model.presentation.acceptedSettings, try .init(isEnabled: true, limit: 75))
        XCTAssertEqual(model.presentation.requestOutcome, .accepted)
        XCTAssertEqual(model.presentation.readback, .confirmed(.inhibited))
        XCTAssertEqual(model.presentation.effectiveTarget, .regular(limit: 75))
        XCTAssertEqual(model.presentation.physicalObservation, .unknown,
                       "accepted intent and confirmed readback do not prove physical effect")
        _ = await model.shutdown()
    }

    func testFullChargeLimitChangeWaitsForReleaseBeforeRegularPolicy() async throws {
        // At p85, new L90 permits charging, unlike old L80's confirmed inhibition.
        let backend = IntegrationBatteryBackend(context: try syntheticContext(percentage: 85))
        let session = BatteryCareSession(backend: backend, now: { 101 })
        let store = IntegrationBatteryPreferences()
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let model = BatteryCareModel(preferences: preferences, service: session, now: { 101 })
        await model.setManagementEnabled(true)
        await model.startFullCharge()
        XCTAssertEqual(model.presentation.temporaryMode, .chargingToFull)
        XCTAssertEqual(model.presentation.effectiveTarget, .fullCharge)
        model.previewLimit(90)
        var effects = await backend.effects
        XCTAssertEqual(effects, [.inhibitCharging, .allowCharging])

        let releaseHeld = expectation(description: "endTemporaryMode apply continuation installed")
        await backend.suspendNextApply(releaseHeld)
        let committed = XCTestExpectation(description: "full-charge limit commit returned")
        let joined = XCTestExpectation(description: "full-charge limit commit cleanup joined")
        let commit = Task { await model.commitPreview(); committed.fulfill(); joined.fulfill() }
        cleanUpCommit(commit, finished: joined, backend: backend)
        try await waitFor(releaseHeld)
        effects = await backend.effects
        XCTAssertEqual(effects, [.inhibitCharging, .allowCharging, .endTemporaryMode],
                       "no new regular risk write while release is unconfirmed")
        let heldEffect = await backend.heldEffect
        _ = try XCTUnwrap(heldEffect == .endTemporaryMode ? heldEffect : nil,
                          "Do not arm another hold or supply an exit receipt to a different effect")
        let stopping = expectation(description: "Model receives unconfirmed exit")
        let stoppingObserver = model.$presentation.first(where: {
            $0.acceptedSettings?.limit == 90 && $0.recoveryStatus == .unconfirmed
        }).sink { _ in stopping.fulfill() }
        defer { stoppingObserver.cancel() }
        try await waitFor(stopping)
        XCTAssertEqual(model.presentation.savedLimit, 90)
        XCTAssertNil(model.presentation.effectiveTarget)
        XCTAssertTrue(model.presentation.cancelFullCharge.isEnabled)
        // Hold the *next* apply too: reaching it proves Session consumed the release receipt,
        // not merely that send returned or the backend started releasing.
        let regularHeld = expectation(description: "new regular apply after release receipt")
        await backend.suspendNextApply(regularHeld)
        let released = expectation(description: "Model receives actual release confirmation")
        let releaseObserver = model.$presentation.first(where: {
            $0.acceptedSettings?.limit == 90 && $0.recoveryStatus == .released && $0.temporaryMode == .none
        }).sink { _ in released.fulfill() }
        await backend.resumeApply(with: receipt(.endTemporaryMode, readback: .unknown))
        defer { releaseObserver.cancel() }
        try await waitFor(released)
        let afterRelease = await session.snapshot()
        XCTAssertEqual(afterRelease.recoveryStatus, .released)
        XCTAssertEqual(afterRelease.temporaryMode, .none)
        XCTAssertEqual(afterRelease.settings, try .init(isEnabled: true, limit: 90))
        try await waitFor(committed)
        XCTAssertNil(model.presentation.effectiveTarget, "release confirmation is not regular readback")
        // A4's independent collector/watchdog input, not UI refresh or an invented timer.
        await session.receive(.tick)
        try await waitFor(regularHeld)
        effects = await backend.effects
        XCTAssertEqual(effects, [.inhibitCharging, .allowCharging, .endTemporaryMode, .allowCharging])
        XCTAssertFalse(effects.contains(.startDischarge))
        let regularEffect = await backend.heldEffect
        _ = try XCTUnwrap(regularEffect == .allowCharging ? regularEffect : nil,
                          "Expected new regular apply before supplying its receipt")

        let regular = expectation(description: "Model receives confirmed latest regular target")
        let regularObserver = model.$presentation.first(where: {
            $0.effectiveTarget == .regular(limit: 90) && $0.readback == .confirmed(.allowed)
        }).sink { _ in regular.fulfill() }
        await backend.resumeApply(with: receipt(.allowCharging, readback: .confirmed(.allowed)))
        defer { regularObserver.cancel() }
        try await waitFor(regular)
        XCTAssertEqual(model.presentation.requestOutcome, .accepted)
        XCTAssertEqual(model.presentation.temporaryMode, .none)
        XCTAssertEqual(model.presentation.effectiveTarget, .regular(limit: 90))
        XCTAssertEqual(model.presentation.readback, .confirmed(.allowed))
        XCTAssertEqual(model.presentation.physicalObservation, .unknown)
        XCTAssertFalse(model.presentation.cancelFullCharge.isEnabled)
        XCTAssertEqual(store.saved.map(\.batteryCare), [try .init(isEnabled: true, limit: 80),
                                                       try .init(isEnabled: true, limit: 90)])
        _ = await model.shutdown()
    }

    func testProductionAppAssemblyRemainsUnavailableWithoutExecutableBackend() async throws {
        let store = IntegrationBatteryPreferences()
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let delegate = AppDelegate(releasePageOpener: { _ in XCTFail("must not open an external URL") })
        // Exercise the same assembly method as applicationDidFinishLaunching, without launching
        // the app, reading user defaults, starting Sparkle/audio, or posting real power events.
        delegate.testingStartBatteryCare(preferences: preferences, workspaceCenter: NotificationCenter())
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let model = try XCTUnwrap(delegate.testingBatteryCareModel)
        let service = try XCTUnwrap(Mirror(reflecting: model).children.first { $0.label == "service" }?.value)
        XCTAssertTrue(service is UnavailableBatteryCareService,
                      "actual App composition must not instantiate Session or an executable backend")
        await model.setManagementEnabled(true)
        XCTAssertEqual(model.presentation.requestOutcome, .rejected(reason: "serviceUnavailable"))
        await model.startFullCharge()
        XCTAssertEqual(model.presentation.requestOutcome, .rejected(reason: "serviceUnavailable"))
        await model.startDischarge()
        XCTAssertEqual(model.presentation.requestOutcome, .rejected(reason: "serviceUnavailable"))
        XCTAssertFalse(model.presentation.savedEnabled)
        XCTAssertEqual(model.presentation.savedLimit, 80)
        XCTAssertEqual(model.presentation.acceptedSettings, .default)
        XCTAssertFalse(model.presentation.enableManagement.isEnabled)
        XCTAssertFalse(model.presentation.startFullCharge.isEnabled)
        XCTAssertFalse(model.presentation.startDischarge.isEnabled)
        for operation in BatteryCareOperation.allCases {
            XCTAssertEqual(model.presentation.capabilities[operation] ?? .unverified, .unverified)
        }
        XCTAssertEqual(model.presentation.authorization, .notAuthorized)
        XCTAssertNil(model.presentation.currentSystemPercentage)
        XCTAssertNil(model.presentation.effectiveTarget)
        XCTAssertEqual(model.presentation.readback, .unknown)
        XCTAssertEqual(model.presentation.physicalObservation, .unknown)
        XCTAssertEqual(model.presentation.recoveryStatus, .unknown)
        XCTAssertTrue(store.saved.isEmpty)
        let result = await model.shutdown()
        XCTAssertEqual(result, .noControlAcquired, "not a verified release or hardware success")
    }

    private func syntheticContext(percentage: Double) throws -> BatteryCareContext {
        let identity = BatteryCareIdentity(batteryID: "SYNTHETIC", modelIdentifier: "SYNTHETIC", osBuild: "SYNTHETIC")
        return .init(sample: .init(identity: identity, presence: .internalBattery, sequence: 1,
            observedAtUptime: 100, systemPercentage: percentage, externalPower: true,
            isCharging: false, lowBatteryProtection: false), expectedIdentity: identity,
            capabilities: Dictionary(uniqueKeysWithValues: BatteryCareOperation.allCases.map {
                ($0, .verified(recordID: "SYNTHETIC-\($0)"))
            }), authorization: .authorized, recoveryStatus: .released,
            safetyLimits: try .init(sampleIntervalNanoseconds: 1, maxSampleAgeNanoseconds: 20,
                maxCommandAgeNanoseconds: 20, maxReadbackNanoseconds: 20, maxStopNanoseconds: 20,
                leaseNanoseconds: 50, maxTemporaryModeNanoseconds: 100, maxNoProgressNanoseconds: 40),
            completion: .notComplete, nowUptime: 101)
    }

    private func waitFor(_ boundary: XCTestExpectation, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = await XCTWaiter.fulfillment(of: [boundary], timeout: 2)
        _ = try XCTUnwrap(result == .completed ? result : nil, "Boundary not reached: \(boundary.expectationDescription)",
                          file: file, line: line)
    }

    private func cleanUpCommit(_ commit: Task<Void, Never>, finished: XCTestExpectation,
                               backend: IntegrationBatteryBackend) {
        addTeardownBlock { @MainActor in
            // Clear BOTH an unconsumed next hold and the actual held effect before joining.
            await backend.releaseAllApplies()
            let result = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(result, .completed, "Commit must finish after all fixture continuations are released")
            if result == .completed { await commit.value }
            else { commit.cancel() } // Never turn a failed boundary into an unbounded await.
        }
    }

    private func receipt(_ effect: BatteryCareEffect, readback: BatteryCareReadback) -> BatteryCareExecution {
        .init(effect: effect, generation: 0, outcome: .accepted, readback: readback,
              physicalObservation: .unknown, recoveryStatus: .released)
    }
}

// MainActor-only PreferencesController/test access; no UserDefaults or persistent suites.
private final class IntegrationBatteryPreferences: PreferencesStoring, @unchecked Sendable {
    var saved: [AppPreferences] = []
    func load() -> AppPreferences { .default }
    func save(_ value: AppPreferences) throws { saved.append(value) }
}

// Only synthetic observations, recorded effects and receipt continuations. No policy decisions.
private actor IntegrationBatteryBackend: BatteryCareBackend {
    let context: BatteryCareContext
    var effects: [BatteryCareEffect] = []
    private var nextApply: XCTestExpectation?
    private var gate: (effect: BatteryCareEffect, continuation: CheckedContinuation<BatteryCareExecution, Never>)?
    var heldEffect: BatteryCareEffect? { gate?.effect }
    init(context: BatteryCareContext) { self.context = context }
    func observe() -> BatteryCareContext { context }
    func suspendNextApply(_ entered: XCTestExpectation) { nextApply = entered }
    func resumeApply(with receipt: BatteryCareExecution) {
        let held = gate
        gate = nil
        if held == nil { nextApply = nil } // A failed entry assertion must not hang later test cleanup.
        held?.continuation.resume(returning: receipt)
    }
    func releaseAllApplies() {
        nextApply = nil
        let held = gate
        gate = nil
        if let held { held.continuation.resume(returning: predefinedReceipt(for: held.effect)) }
    }
    func apply(_ effect: BatteryCareEffect) async -> BatteryCareExecution {
        effects.append(effect)
        if let entered = nextApply {
            nextApply = nil
            return await withCheckedContinuation { gate = (effect, $0); entered.fulfill() }
        }
        return predefinedReceipt(for: effect)
    }
    private func predefinedReceipt(for effect: BatteryCareEffect) -> BatteryCareExecution {
        // Predefined low-level facts, not a reducer or threshold implementation.
        let readback: BatteryCareReadback
        switch effect {
        case .allowCharging: readback = .confirmed(.allowed)
        case .inhibitCharging: readback = .confirmed(.inhibited)
        default: readback = .unknown
        }
        return .init(effect: effect, generation: 0, outcome: .accepted, readback: readback,
                     physicalObservation: .unknown, recoveryStatus: .released)
    }
}
