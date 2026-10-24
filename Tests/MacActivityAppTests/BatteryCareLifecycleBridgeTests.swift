import AppKit
import Combine
import MacActivityBatteryControl
import MacActivityCore
import XCTest
@testable import MacActivityApp

@MainActor
final class BatteryCareLifecycleBridgeTests: XCTestCase {
    func testStartStopAndDuplicateNotificationsPreserveOrderedLifecycleWithoutDisplayScheduler() async {
        let service = LifecycleBatteryService()
        let model = BatteryCareModel(preferences: lifecyclePreferences(), service: service)
        let center = LifecycleNotificationCenter() // Never post power events to NSWorkspace.shared.
        let bridge = BatteryCareLifecycleBridge(model: model, workspaceCenter: center)
        model.previewLimit(90)
        bridge.start()
        bridge.start()
        XCTAssertEqual(center.installedCount, 2)
        await Task.detached {
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
        }.value
        await waitForLifecycles(2, service)
        var events = await service.events
        XCTAssertEqual(events.map(\.0), [.willSleep, .didWake])
        XCTAssertEqual(events.map(\.1), [1, 2])
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertEqual(model.presentation.temporaryMode, .none)
        bridge.stop()
        bridge.stop()
        XCTAssertEqual(center.removedCount, 2)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        events = await service.events
        XCTAssertEqual(events.count, 2)
        bridge.start()
        XCTAssertEqual(center.installedCount, 4)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await waitForLifecycles(3, service)
        events = await service.events
        XCTAssertEqual(events.map(\.0), [.willSleep, .didWake, .willSleep])
        bridge.stop()
        XCTAssertEqual(center.removedCount, 4)
        let commands = await service.commands
        XCTAssertTrue(commands.isEmpty, "wake must not synthesize a temporary start")
    }

    func testStopDiscardsQueuedNotificationsAndReleasesObservers() async {
        let service = LifecycleBatteryService()
        let model = BatteryCareModel(preferences: lifecyclePreferences(), service: service)
        let center = NotificationCenter()
        weak var released: BatteryCareLifecycleBridge?
        autoreleasepool {
            let bridge = BatteryCareLifecycleBridge(model: model, workspaceCenter: center)
            released = bridge
            bridge.start()
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            bridge.stop() // MainActor consumer has not run yet.
        }
        XCTAssertNil(released)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        let events = await service.events
        XCTAssertTrue(events.isEmpty)
    }

    func testDeinitRemovesBothWorkspaceObserversWithoutRequiringStop() async {
        let center = LifecycleNotificationCenter()
        let model = BatteryCareModel(preferences: lifecyclePreferences(), service: LifecycleBatteryService())
        weak var released: BatteryCareLifecycleBridge?
        autoreleasepool {
            let bridge = BatteryCareLifecycleBridge(model: model, workspaceCenter: center)
            released = bridge
            bridge.start()
            XCTAssertEqual(center.installedCount, 2)
        }
        XCTAssertNil(released)
        for _ in 0..<200 {
            if center.removedCount == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(center.removedCount, 2)
    }

    func testQuitRejectsQueuedRiskActionsAfterLateStartupAndKeepsSavedIntent() async throws {
        let store = LifecycleBatteryPreferences(settings: try .init(isEnabled: true, limit: 63))
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let service = LifecycleBatteryService(holdStartup: true)
        let model = BatteryCareModel(preferences: preferences, service: service)
        let entered = expectation(description: "startup held")
        await service.onStartup(entered)
        await fulfillment(of: [entered], timeout: 2)
        let enable = Task { await model.setManagementEnabled(true) }
        let full = Task { await model.startFullCharge() }
        let retry = Task { await model.retryRegular() }
        await Task.yield()
        let quit = Task { await model.shutdown() }
        await Task.yield()
        await service.releaseStartup()
        let result = await quit.value
        await enable.value; await full.value; await retry.value
        XCTAssertEqual(result, .noControlAcquired)
        await model.handleLifecycle(.didWake)
        let commands = await service.commands
        let events = await service.events
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(events.map(\.0), [.quit])
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(preferences.state.batteryCare, try .init(isEnabled: true, limit: 63))
        XCTAssertTrue(model.presentation.isSuspended)
        XCTAssertNil(model.presentation.effectiveTarget)
    }

    func testUnavailableShutdownIsNotAReleaseAndIsIdempotent() async {
        let model = BatteryCareModel(preferences: lifecyclePreferences(), service: UnavailableBatteryCareService())
        let first = await model.shutdown()
        let generation = model.presentation.generation
        let second = await model.shutdown()
        XCTAssertEqual(first, .noControlAcquired)
        XCTAssertEqual(second, .noControlAcquired)
        XCTAssertEqual(model.presentation.generation, generation)
        XCTAssertNotEqual(model.presentation.recoveryStatus, .released)
    }

    func testBridgeSleepReachesRealSessionRetiresGenerationAndWakeDoesNotRestartTemporaryMode() async throws {
        let identity = BatteryCareIdentity(batteryID: "test", modelIdentifier: "test", osBuild: "test")
        let limits = try BatteryCareSafetyLimits(sampleIntervalNanoseconds: 1, maxSampleAgeNanoseconds: 20,
            maxCommandAgeNanoseconds: 20, maxReadbackNanoseconds: 20, maxStopNanoseconds: 20,
            leaseNanoseconds: 50, maxTemporaryModeNanoseconds: 100, maxNoProgressNanoseconds: 40)
        let backend = LifecycleBatteryBackend(context: .init(
            sample: .init(identity: identity, presence: .internalBattery, sequence: 1, observedAtUptime: 100,
                systemPercentage: 85, externalPower: true, isCharging: false, lowBatteryProtection: false),
            expectedIdentity: identity,
            capabilities: Dictionary(uniqueKeysWithValues: BatteryCareOperation.allCases.map {
                ($0, .verified(recordID: "test-only"))
            }), authorization: .authorized, recoveryStatus: .released, safetyLimits: limits, nowUptime: 101))
        let session = BatteryCareSession(backend: backend, now: { 101 })
        let preferences = lifecyclePreferences()
        let model = BatteryCareModel(preferences: preferences, service: session, now: { 101 })
        await model.setManagementEnabled(true)
        await model.startDischarge()
        let before = await session.snapshot()
        XCTAssertEqual(before.temporaryMode, .discharging)
        let center = NotificationCenter()
        let bridge = BatteryCareLifecycleBridge(model: model, workspaceCenter: center)
        bridge.start()
        defer { bridge.stop() }
        let slept = expectation(description: "session sleep delivered")
        let sleepObserver = model.$presentation.first(where: {
            $0.generation > before.generation && !$0.isPending
        }).sink { _ in MainActor.assertIsolated(); slept.fulfill() }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [slept], timeout: 2)
        sleepObserver.cancel()
        let afterSleep = await session.snapshot()
        XCTAssertGreaterThan(afterSleep.generation, before.generation)
        XCTAssertEqual(afterSleep.temporaryMode, .none)
        let stale = await session.send(.init(requestID: UUID(), generation: before.generation, intent: .startDischarge))
        XCTAssertEqual(stale.outcome, .rejected(reason: "staleGeneration"))
        let wake = expectation(description: "wake delivered")
        let wakeObserver = model.$presentation.first(where: {
            $0.generation > afterSleep.generation && !$0.isPending
        }).sink { _ in wake.fulfill() }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [wake], timeout: 2)
        wakeObserver.cancel()
        let afterWake = await session.snapshot()
        XCTAssertEqual(afterWake.temporaryMode, .none)
        let effects = await backend.effects
        XCTAssertEqual(effects, [.inhibitCharging, .startDischarge, .releaseOwnedControls])
        XCTAssertTrue(preferences.state.batteryCare.isEnabled, "normal quit/sleep preserves saved intent")
    }

    private func waitForLifecycles(_ count: Int, _ service: LifecycleBatteryService) async {
        for _ in 0..<200 {
            if await service.events.count >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("lifecycle \(count) not delivered")
    }
}

@MainActor
func lifecyclePreferences() -> PreferencesController {
    PreferencesController(store: LifecycleBatteryPreferences(), launchService: NoopLaunchAtLoginService())
}

// Memory only, accessed by MainActor PreferencesController/tests.
final class LifecycleBatteryPreferences: PreferencesStoring, @unchecked Sendable {
    let initial: AppPreferences
    var saved: [AppPreferences] = []
    init(settings: BatteryCareSettings = .default) {
        var value = AppPreferences.default
        value.batteryCare = settings
        initial = value
    }
    func load() -> AppPreferences { initial }
    func save(_ value: AppPreferences) throws { saved.append(value) }
}

// Records the App contract only. No admission, thresholds, effects or policy implementation.
actor LifecycleBatteryService: BatteryCareServicing {
    var events: [(BatteryCareLifecycleEvent, UInt64)] = []
    var commands: [BatteryCareCommand] = []
    private var holdStartup: Bool
    private var startupEntered = false
    private var entry: XCTestExpectation?
    private var held: CheckedContinuation<Void, Never>?
    init(holdStartup: Bool = false) { self.holdStartup = holdStartup }
    func onStartup(_ entry: XCTestExpectation) {
        if startupEntered { entry.fulfill() } else { self.entry = entry }
    }
    func snapshot() async -> BatteryCareSnapshot {
        if holdStartup {
            startupEntered = true
            entry?.fulfill(); entry = nil
            await withCheckedContinuation { held = $0 }
        }
        return .init()
    }
    func releaseStartup() { holdStartup = false; held?.resume(); held = nil }
    func updates() -> AsyncStream<BatteryCareSnapshot> { AsyncStream { $0.finish() } }
    func send(_ command: BatteryCareCommand) -> BatteryCareReply {
        commands.append(command)
        return .init(requestID: command.requestID, generation: command.generation, revision: 0,
                     outcome: .rejected(reason: "testUnavailable"))
    }
    func handleLifecycle(_ event: BatteryCareLifecycleEvent, generation: UInt64) -> BatteryCareReply {
        events.append((event, generation))
        return .init(requestID: UUID(), generation: generation, revision: 0, outcome: .outcomeUnknown)
    }
}

private actor LifecycleBatteryBackend: BatteryCareBackend {
    let context: BatteryCareContext
    var effects: [BatteryCareEffect] = []
    init(context: BatteryCareContext) { self.context = context }
    func observe() -> BatteryCareContext { context }
    func apply(_ effect: BatteryCareEffect) -> BatteryCareExecution {
        effects.append(effect)
        return .init(effect: effect, generation: 0, outcome: .accepted,
            readback: effect == .inhibitCharging || effect == .startDischarge ? .confirmed(.inhibited) : .unknown,
            recoveryStatus: .released)
    }
}

private final class LifecycleNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var installed = 0
    private var removed = 0
    var installedCount: Int { lock.withLock { installed } }
    var removedCount: Int { lock.withLock { removed } }
    override func addObserver(forName name: Notification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        lock.withLock { installed += 1 }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
    override func removeObserver(_ observer: Any) {
        lock.withLock { removed += 1 }
        super.removeObserver(observer)
    }
}
