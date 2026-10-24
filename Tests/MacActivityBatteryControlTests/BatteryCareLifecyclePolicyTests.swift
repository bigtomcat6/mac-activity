import Foundation
import XCTest
import MacActivityBatteryControl

final class BatteryCareLifecyclePolicyTests: XCTestCase {
    // SYNTHETIC identity, verification records and virtual clock only.
    private let identity = BatteryCareIdentity(batteryID: "test-battery", modelIdentifier: "test-model", osBuild: "test-build")

    func testLifecycleNeverResumesTemporaryMode() throws {
        for intent in [BatteryCareIntent.startDischarge, .startFullCharge] {
            for event in [BatteryCareEvent.lifecycle(.unplugged), .lifecycle(.willSleep), .lifecycle(.quit),
                          .lifecycle(.connectionLost), .intent(.setManagement(false))] {
                let running = try start(intent)
                let ended = step(running, event, input(seq: 11, time: 101))
                XCTAssertEqual(ended.state.temporaryMode, .none)
                XCTAssertEqual(ended.effects, [.releaseOwnedControls])
                XCTAssertNotEqual(ended.state.generation, running.generation)
                XCTAssertEqual(ended.state.recoveryStatus, .unconfirmed)
                let exit = release(ended.state)
                let wake = step(exit, .lifecycle(.didWake), input(seq: 11, time: 102))
                XCTAssertEqual(wake.effects, [])
                let fresh = step(wake.state, .sampleChanged, input(seq: 12, time: 103))
                XCTAssertEqual(fresh.state.temporaryMode, .none)
                XCTAssertFalse(fresh.effects.contains(.startDischarge))
                if ended.state.requiresRetry || !ended.state.settings.isEnabled {
                    XCTAssertEqual(fresh.effects, [])
                } else { XCTAssertEqual(fresh.effects, [.inhibitCharging]) }
            }
        }
    }

    func testLowBatteryProtectionIsFallbackAndNeverAutomaticResume() throws {
        for intent in [BatteryCareIntent.startDischarge, .startFullCharge] {
            for (p, protection) in [(20.0, false), (20.01, true), (90.0, true)] {
                let ended = step(try start(intent), .sampleChanged, input(p, seq: 11, time: 101, protection: protection))
                XCTAssertEqual(ended.state.temporaryMode, .none)
                XCTAssertEqual(ended.effects, [.releaseOwnedControls])
                XCTAssertTrue(ended.state.requiresRetry)
                let exit = release(ended.state)
                let healthy = step(exit, .sampleChanged, input(seq: 12, time: 102))
                XCTAssertEqual(healthy.effects, [])
                let retried = step(healthy.state, .intent(.retryRegular), input(seq: 12, time: 102))
                XCTAssertEqual(retried.effects, [.inhibitCharging])
                XCTAssertEqual(retried.state.temporaryMode, .none)
            }
        }
        let reached = step(try start(.startDischarge), .sampleChanged, input(50, seq: 11, time: 101))
        XCTAssertEqual(reached.effects, [.endTemporaryMode]) // much earlier than fallback 20
        let justAbove = step(try start(.startFullCharge), .sampleChanged, input(20.01, seq: 11, time: 101))
        XCTAssertEqual(justAbove.state.temporaryMode, .chargingToFull)
        XCTAssertFalse(justAbove.state.requiresRetry)
    }

    func testMissingContextStillReleasesAndDoesNotPretendReleased() throws {
        for intent in [BatteryCareIntent.startDischarge, .startFullCharge] {
            let running = try start(intent)
            for event in [BatteryCareEvent.tick, .executionObserved, .lifecycle(.willSleep), .intent(.stopDischarge),
                          .intent(.cancelFullCharge), .intent(.releaseOwnedControls(reason: .userRequested))] {
                var value = input(); value.sample = nil
                let result = step(running, event, value)
                XCTAssertEqual(result.state.temporaryMode, .none)
                XCTAssertTrue(result.effects == [.releaseOwnedControls] || result.effects == [.endTemporaryMode])
                XCTAssertEqual(result.state.recoveryStatus, .unconfirmed)
                XCTAssertEqual(result.state.confirmedPhase, .unknown)
            }
            var unavailable = input(); unavailable.sample = nil; unavailable.authorization = .notAuthorized
            let failed = step(running, .tick, unavailable)
            XCTAssertEqual(failed.state.temporaryMode, .none)
            XCTAssertEqual(failed.state.recoveryStatus, .unconfirmed)
            XCTAssertTrue(failed.state.requiresRetry)
            XCTAssertNotEqual(failed.state.generation, running.generation)
            XCTAssertEqual(failed.effects, [])
            let reconnected = step(failed.state, .tick, input(seq: 11, time: 101))
            XCTAssertEqual(reconnected.effects, [.releaseOwnedControls])
            XCTAssertEqual(reconnected.state.temporaryMode, .none)
            let premature = step(reconnected.state, .intent(.retryRegular), input(seq: 11, time: 101))
            XCTAssertEqual(premature.effects, [])
        }
    }

    func testSleepUnplugAndFaultRetainSequenceBaseline() throws {
        let running = try start(.startDischarge)
        for event in [BatteryCareEvent.lifecycle(.willSleep), .lifecycle(.unplugged), .tick] {
            var context = input(seq: 11, time: 101)
            if event == .tick { context.sample = nil }
            let ending = step(running, event, context)
            XCTAssertGreaterThanOrEqual(ending.state.lastSample?.sequence ?? 0, 10)
            let exit = release(ending.state)
            let wake = step(exit, .lifecycle(.didWake), input(seq: 11, time: 102))
            for invalid in [input(seq: 9, time: 103), input(seq: 10, time: 103), input(seq: 12, time: 100)] {
                let result = step(wake.state, .intent(.retryRegular), invalid)
                XCTAssertEqual(result.effects, [])
                XCTAssertEqual(result.state.confirmedPhase, .unknown)
                XCTAssertEqual(result.state.temporaryMode, .none)
            }
        }
    }

    func testStopTimeoutLateReceiptAndNewLimitCannotBypassRecovery() throws {
        let running = try start(.startDischarge)
        let stop = step(running, .intent(.stopDischarge), input())
        var oldReceipt = input()
        oldReceipt.execution = .init(effect: .startDischarge, generation: running.generation,
                                    outcome: .accepted, readback: .confirmed(.inhibited))
        let stale = step(stop.state, .executionObserved, oldReceipt)
        XCTAssertEqual(stale.state.pendingEffect, .endTemporaryMode)
        let timeout = step(stale.state, .tick, input(seq: 11, time: 120))
        XCTAssertTrue(timeout.state.requiresRetry)
        XCTAssertEqual(timeout.state.recoveryStatus, .unconfirmed)
        XCTAssertEqual(timeout.effects, [.releaseOwnedControls])
        let change = step(timeout.state, .intent(.setLimit(60)), input(seq: 12, time: 121))
        XCTAssertEqual(change.effects, [])
        XCTAssertEqual(change.state.pendingEffect, .releaseOwnedControls)
        XCTAssertEqual(change.state.temporaryMode, .none)
        let released = release(change.state, time: 121)
        XCTAssertTrue(released.requiresRetry)
        XCTAssertEqual(step(released, .intent(.startDischarge), input(seq: 13, time: 122)).effects, [])
        XCTAssertEqual(step(released, .intent(.retryRegular), input(seq: 13, time: 122)).effects, [.inhibitCharging])
    }

    func testProtectionAndMissingEvidenceTakePriorityEvenWhileStopping() throws {
        for intent in [BatteryCareIntent.startDischarge, .startFullCharge] {
            let running = try start(intent)
            let stop: BatteryCareIntent = intent == .startDischarge ? .stopDischarge : .cancelFullCharge
            let stopping = step(running, .intent(stop), input())
            var missing = input(seq: 11, time: 101); missing.sample = nil
            for value in [input(20, seq: 11, time: 101), input(seq: 11, time: 101, protection: true), missing] {
                for prior in [running, stopping.state] {
                    let result = step(prior, .intent(stop), value)
                    XCTAssertEqual(result.state.temporaryMode, .none)
                    XCTAssertTrue(result.state.requiresRetry)
                    XCTAssertEqual(result.effects, [.releaseOwnedControls])
                    XCTAssertEqual(result.state.recoveryStatus, .unconfirmed)
                }
            }
        }
    }

    func testTemporaryFaultRequiresPostFaultSampleAndRetainsBaseline() throws {
        let running = try start(.startFullCharge)
        var missing = input(seq: 11, time: 110); missing.completion = .unknown
        let failed = step(running, .tick, missing)
        XCTAssertEqual(failed.state.lastSample?.sequence, 10)
        let exit = release(failed.state, time: 111)
        let replay = step(exit, .intent(.retryRegular), input(seq: 11, time: 105))
        XCTAssertEqual(replay.effects, [])
        XCTAssertEqual(replay.state.confirmedPhase, .unknown)
        let fresh = step(exit, .intent(.retryRegular), input(seq: 12, time: 112))
        XCTAssertEqual(fresh.effects, [.inhibitCharging])
    }

    private func input(_ p: Double = 90, seq: UInt64 = 10, time: UInt64 = 100,
                       protection: Bool? = false) -> BatteryCareContext {
        .init(sample: .init(identity: identity, presence: .internalBattery, sequence: seq, observedAtUptime: time,
                            systemPercentage: p, externalPower: true, isCharging: false, lowBatteryProtection: protection),
              expectedIdentity: identity,
              capabilities: [.regularLimit: .verified(recordID: "test-regular"), .manualDischarge: .verified(recordID: "test-discharge"),
                             .temporaryFullCharge: .verified(recordID: "test-full"), .releaseOwnedControls: .verified(recordID: "test-release")],
              authorization: .authorized, recoveryStatus: .released,
              safetyLimits: try! .init(sampleIntervalNanoseconds: 10, maxSampleAgeNanoseconds: 50,
                  maxCommandAgeNanoseconds: 20, maxReadbackNanoseconds: 20, maxStopNanoseconds: 20,
                  leaseNanoseconds: 100, maxTemporaryModeNanoseconds: 200, maxNoProgressNanoseconds: 100),
              completion: .notComplete, nowUptime: time)
    }

    private func step(_ state: BatteryCareState, _ event: BatteryCareEvent,
                      _ context: BatteryCareContext) -> BatteryCareTransition {
        BatteryCarePolicy.reduce(state: state, event: event, context: context)
    }

    private func start(_ intent: BatteryCareIntent) throws -> BatteryCareState {
        let result = step(.init(settings: try .init(isEnabled: true)), .intent(intent), input())
        var value = input()
        value.execution = .init(effect: result.state.pendingEffect ?? .startDischarge, generation: result.state.generation,
                                outcome: .accepted, readback: .confirmed(intent == .startDischarge ? .inhibited : .allowed))
        return step(result.state, .executionObserved, value).state
    }

    private func release(_ state: BatteryCareState, time: UInt64 = 101) -> BatteryCareState {
        var value = input(seq: 11, time: time)
        value.execution = .init(effect: state.pendingEffect ?? .releaseOwnedControls, generation: state.generation,
                                outcome: .accepted, readback: .unknown)
        return step(state, .executionObserved, value).state
    }
}
