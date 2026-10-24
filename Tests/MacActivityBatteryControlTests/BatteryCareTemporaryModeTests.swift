import Foundation
import XCTest
import MacActivityBatteryControl

final class BatteryCareTemporaryModeTests: XCTestCase {
    // SYNTHETIC device/records and virtual nanoseconds, never hardware defaults.
    private let identity = BatteryCareIdentity(batteryID: "test-battery", modelIdentifier: "test-model", osBuild: "test-build")

    func testDischargeRequiresExplicitAdmittedStartAndStopsAtLimitOnce() throws {
        let base = try enabled()
        let ordinary = step(base, .sampleChanged)
        XCTAssertFalse(ordinary.effects.contains(.startDischarge))
        let start = step(base, .intent(.startDischarge))
        XCTAssertEqual(start.effects, [.startDischarge])
        XCTAssertEqual(start.state.temporaryMode, .discharging)
        let running = acknowledge(start.state)
        XCTAssertEqual(running.state.confirmedPhase, .unknown)
        let above = step(running.state, .sampleChanged, input(80.01, seq: 2, time: 101))
        XCTAssertEqual(above.effects, [])
        let target = step(above.state, .sampleChanged, input(80, seq: 3, time: 102))
        XCTAssertEqual(target.effects, [.endTemporaryMode])
        XCTAssertEqual(target.state.temporaryMode, .none)
        XCTAssertEqual(target.state.recoveryStatus, .unconfirmed)
        let stopped = acknowledge(target.state, input(80, seq: 3, time: 102))
        let later = step(stopped.state, .sampleChanged, input(81, seq: 4, time: 103))
        XCTAssertEqual(later.effects, [.inhibitCharging])
        XCTAssertFalse(later.effects.contains(.startDischarge))
    }

    func testTemporaryAdmissionAndMutualExclusion() throws {
        var bad = [input(80), input(79.99)]
        for operation in [BatteryCareOperation.regularLimit, .manualDischarge, .releaseOwnedControls] {
            var value = input()
            value.capabilities[operation] = .unverified
            bad.append(value)
        }
        for recovery in [BatteryCareRecoveryStatus.unknown, .unconfirmed, .conflict] {
            var value = input(); value.recoveryStatus = recovery; bad.append(value)
        }
        var noLimits = input(); noLimits.safetyLimits = nil; bad.append(noLimits)
        var noAuth = input(); noAuth.authorization = .notAuthorized; bad.append(noAuth)
        var noPower = input(); noPower.sample = sample(90, power: false); bad.append(noPower)
        var noSample = input(); noSample.sample = nil; bad.append(noSample)
        for value in bad {
            XCTAssertFalse(step(try enabled(), .intent(.startDischarge), value).effects.contains(.startDischarge))
        }
        XCTAssertFalse(step(.init(), .intent(.startDischarge)).effects.contains(.startDischarge))
        let discharge = step(try enabled(), .intent(.startDischarge))
        XCTAssertEqual(step(discharge.state, .intent(.startFullCharge)).state.temporaryMode, .discharging)
        XCTAssertEqual(step(discharge.state, .intent(.startDischarge)).effects, [])
        let full = step(try enabled(), .intent(.startFullCharge))
        XCTAssertEqual(step(full.state, .intent(.startDischarge)).state.temporaryMode, .chargingToFull)
        var unavailable = input(); unavailable.capabilities[.temporaryFullCharge] = .unverified
        XCTAssertNotEqual(step(try enabled(), .intent(.startFullCharge), unavailable).state.temporaryMode, .chargingToFull)
    }

    func testAcceptedLimitFollowsOnlyCurrentDischargeAndCannotUndoStop() throws {
        let running = acknowledge(step(try enabled(), .intent(.startDischarge)).state).state
        // There is intentionally no preview event; an unchanged tick still targets accepted 80.
        XCTAssertEqual(step(running, .tick, input(81)).state.settings.limit, 80)
        let lower = step(running, .settingsAccepted(try .init(isEnabled: true, limit: 70)))
        XCTAssertEqual(lower.effects, [])
        XCTAssertEqual(lower.state.temporaryMode, .discharging)
        let higher = step(lower.state, .settingsAccepted(try .init(isEnabled: true, limit: 95)))
        XCTAssertEqual(higher.effects, [.endTemporaryMode])
        let stopGeneration = higher.state.generation
        let lowerAgain = step(higher.state, .settingsAccepted(try .init(isEnabled: true, limit: 60)))
        XCTAssertEqual(lowerAgain.effects, [])
        XCTAssertEqual(lowerAgain.state.pendingEffect, .endTemporaryMode)
        XCTAssertEqual(lowerAgain.state.generation, stopGeneration)
        XCTAssertEqual(step(lowerAgain.state, .intent(.startDischarge)).effects, [])
        XCTAssertEqual(step(lowerAgain.state, .intent(.retryRegular)).effects, [])
        let exit = acknowledge(lowerAgain.state)
        XCTAssertEqual(step(exit.state, .tick).effects, [.inhibitCharging])
    }

    func testFullChargeKeepsRegularLimitAndCancelsOnlyOnDifferentAcceptedLimit() throws {
        let start = step(try enabled(), .intent(.startFullCharge))
        XCTAssertEqual(start.effects, [.allowCharging])
        XCTAssertEqual(start.state.settings.limit, 80)
        XCTAssertEqual(start.state.temporaryMode, .chargingToFull)
        let running = acknowledge(start.state).state
        let unchanged = step(running, .settingsAccepted(try .init(isEnabled: true, limit: 80)))
        XCTAssertEqual(unchanged.effects, [])
        XCTAssertEqual(unchanged.state.temporaryMode, .chargingToFull)
        for limit in [85, 100] {
            let change = step(running, .settingsAccepted(try .init(isEnabled: true, limit: limit)))
            XCTAssertEqual(change.effects, [.endTemporaryMode])
            XCTAssertEqual(change.state.settings.limit, limit)
            XCTAssertEqual(change.state.temporaryMode, .none)
            XCTAssertEqual(change.state.confirmedPhase, .unknown)
            let exit = acknowledge(change.state)
            XCTAssertEqual(step(exit.state, .tick).effects, limit == 100 ? [] : [.inhibitCharging])
        }
        let prohibited = step(try enabled(100), .intent(.startFullCharge))
        XCTAssertEqual(prohibited.effects, [])
        XCTAssertEqual(prohibited.state.temporaryMode, .none)
        XCTAssertNotNil(prohibited.state.pauseReason)
    }

    func testSameLimitExitUsesFivePointBandAndDifferentLimitRebuilds() throws {
        for startIntent in [BatteryCareIntent.startFullCharge, .startDischarge] {
            let running = acknowledge(step(try enabled(), .intent(startIntent)).state).state
            let stop: BatteryCareIntent = startIntent == .startFullCharge ? .cancelFullCharge : .stopDischarge
            let ending = step(running, .intent(stop))
            XCTAssertEqual(ending.effects, [.endTemporaryMode])
            for (p, effect) in [(75.01, BatteryCareEffect.inhibitCharging), (75, .allowCharging), (74.99, .allowCharging)] {
                let exit = acknowledge(ending.state)
                XCTAssertEqual(step(exit.state, .sampleChanged, input(p, seq: 2, time: 101)).effects, [effect])
            }
            let changed = step(ending.state, .intent(.setLimit(85)))
            let exit = acknowledge(changed.state)
            XCTAssertEqual(step(exit.state, .sampleChanged, input(82, seq: 2, time: 101)).effects, [.allowCharging])
        }
    }

    func testDisplayed100AndStoppedChargingDoNotConfirmFull() throws {
        for charging in [true, false] {
            let start = step(try enabled(), .intent(.startFullCharge), input(100, charging: charging))
            let running = acknowledge(start.state, input(100, charging: charging)).state
            let waiting = step(running, .sampleChanged, input(100, seq: 2, time: 101, charging: charging))
            XCTAssertEqual(waiting.state.temporaryMode, .chargingToFull)
            XCTAssertNotEqual(waiting.state.completion, .confirmed(recordID: "test-full", sampleSequence: 2))
            XCTAssertEqual(waiting.effects, []) // notComplete is valid waiting, including optimized pauses.
        }
        // No current/power threshold or synthesized completion signal exists in policy input.
        let start = step(try enabled(), .intent(.startFullCharge))
        let running = acknowledge(start.state).state
        var confirmed = input(100, seq: 2, time: 101, charging: false)
        confirmed.completion = .confirmed(recordID: "test-full", sampleSequence: 2)
        let completed = step(running, .sampleChanged, confirmed)
        XCTAssertEqual(completed.effects, [.endTemporaryMode])
        XCTAssertEqual(completed.state.completion, confirmed.completion)
        XCTAssertEqual(completed.state.confirmedPhase, .unknown)
        let released = acknowledge(completed.state, confirmed)
        let regular = step(released.state, .tick, confirmed)
        XCTAssertEqual(regular.effects, [.inhibitCharging])
        XCTAssertEqual(regular.state.completion, confirmed.completion)
        let failedRestore = acknowledge(completed.state, confirmed, recovery: .unconfirmed)
        XCTAssertEqual(failedRestore.state.completion, confirmed.completion)
        XCTAssertNotEqual(failedRestore.state.recoveryStatus, .released)
        XCTAssertEqual(failedRestore.state.confirmedPhase, .unknown)
        XCTAssertFalse(failedRestore.effects.contains(.startDischarge))
    }

    func testFullEvidenceMustBeFreshBoundToSessionAndVerifiedRecord() throws {
        let running = acknowledge(step(try enabled(), .intent(.startFullCharge)).state).state
        var invalid: [BatteryCareContext] = []
        var unknown = input(); unknown.completion = .unknown; invalid.append(unknown)
        var noCharging = input(charging: nil); invalid.append(noCharging)
        for completion in [BatteryCareCompletion.confirmed(recordID: "wrong", sampleSequence: 2),
                           .confirmed(recordID: "test-full", sampleSequence: 1),
                           .confirmed(recordID: "test-full", sampleSequence: 3)] {
            var value = input(100, seq: 2, time: 101); value.completion = completion; invalid.append(value)
        }
        var contradiction = input(100, seq: 2, time: 101, charging: true)
        contradiction.completion = .confirmed(recordID: "test-full", sampleSequence: 2); invalid.append(contradiction)
        var changedRecord = input(); changedRecord.capabilities[.temporaryFullCharge] = .verified(recordID: "other"); invalid.append(changedRecord)
        var expired = input(); expired.nowUptime = 150; invalid.append(expired)
        for value in invalid {
            let result = step(running, .tick, value)
            XCTAssertEqual(result.state.temporaryMode, .none)
            XCTAssertTrue(result.state.requiresRetry)
            XCTAssertEqual(result.effects, [.releaseOwnedControls])
            XCTAssertEqual(result.state.completion, .unknown)
        }
        noCharging.completion = .unknown
        XCTAssertNotEqual(step(try enabled(), .intent(.startFullCharge), noCharging).state.temporaryMode, .chargingToFull)
    }

    func testValidWaitingAndNoProgressHaveInjectedFiniteDeadlines() throws {
        for intent in [BatteryCareIntent.startFullCharge, .startDischarge] {
            let start = step(try enabled(), .intent(intent))
            let running = acknowledge(start.state).state
            let before = step(running, .tick, input(90, seq: 2, time: 199))
            XCTAssertEqual(before.state.temporaryMode, running.temporaryMode)
            let timeout = step(before.state, .tick, input(90, seq: 3, time: 200))
            XCTAssertEqual(timeout.state.temporaryMode, .none)
            XCTAssertTrue(timeout.state.requiresRetry)
            XCTAssertEqual(timeout.effects, [.releaseOwnedControls])
            XCTAssertEqual(timeout.state.completion, .unknown)
            let progressP = intent == .startFullCharge ? 91.0 : 89.0
            let progress = step(running, .sampleChanged, input(progressP, seq: 2, time: 190))
            let stillRunning = step(progress.state, .tick, input(progressP, seq: 3, time: 250))
            XCTAssertEqual(stillRunning.state.temporaryMode, running.temporaryMode)
            let total = step(stillRunning.state, .tick, input(intent == .startFullCharge ? 92 : 88, seq: 4, time: 300))
            XCTAssertEqual(total.state.temporaryMode, .none)
            XCTAssertTrue(total.state.requiresRetry)
        }
    }

    func testIntentSettingsValidateAndNeverImplicitlyEnable() throws {
        for limit in [49, 101, Int.min, Int.max] {
            let result = step(try enabled(), .intent(.setLimit(limit)))
            XCTAssertEqual(result.state.settings.limit, 80)
            XCTAssertEqual(result.effects, [])
            XCTAssertNotNil(result.state.pauseReason)
        }
        let edit = step(.init(), .intent(.setLimit(60)))
        XCTAssertFalse(edit.state.settings.isEnabled)
        XCTAssertEqual(edit.state.settings.limit, 60)
        XCTAssertEqual(edit.effects, [])
        let enable = step(edit.state, .intent(.setManagement(true)))
        XCTAssertTrue(enable.state.settings.isEnabled)
        XCTAssertEqual(enable.effects, [.inhibitCharging])
    }

    func testPendingStartDeadlineCannotBeConvertedIntoNormalCompletion() throws {
        for intent in [BatteryCareIntent.startDischarge, .startFullCharge] {
            let start = step(try enabled(), .intent(intent))
            var value = input(intent == .startDischarge ? 80 : 100, seq: 2, time: 120)
            if intent == .startFullCharge { value.completion = .confirmed(recordID: "test-full", sampleSequence: 2) }
            let result = step(start.state, .sampleChanged, value)
            XCTAssertEqual(result.state.temporaryMode, .none)
            XCTAssertTrue(result.state.requiresRetry)
            XCTAssertEqual(result.effects, [.releaseOwnedControls])
            XCTAssertEqual(result.state.completion, .unknown)
        }
    }

    func testGenerationExhaustionCannotLeaveAnUnstartedTemporaryIntent() throws {
        for intent in [BatteryCareIntent.startDischarge, .startFullCharge] {
            var state = try enabled(); state.generation = .max
            let result = step(state, .intent(intent))
            XCTAssertEqual(result.state.temporaryMode, .none)
            XCTAssertNil(result.state.pendingEffect)
            XCTAssertEqual(result.effects, [])
            XCTAssertTrue(result.state.requiresRetry)
        }
    }

    func testRetryWithoutFaultDoesNotBypassExitHysteresis() throws {
        let full = acknowledge(step(try enabled(), .intent(.startFullCharge)).state).state
        let end = step(full, .intent(.cancelFullCharge))
        let exit = acknowledge(end.state).state
        XCTAssertEqual(step(exit, .intent(.retryRegular), input(77, seq: 2, time: 101)).effects, [.inhibitCharging])
    }

    func testAlreadyFullStartStillRequiresANewSessionSample() throws {
        var initial = input(100)
        initial.completion = .confirmed(recordID: "test-full", sampleSequence: 1)
        let start = step(try enabled(), .intent(.startFullCharge), initial)
        XCTAssertEqual(start.state.temporaryMode, .chargingToFull)
        XCTAssertEqual(start.state.completion, .unknown)
        var fresh = input(100, seq: 2, time: 101)
        fresh.completion = .confirmed(recordID: "test-full", sampleSequence: 2)
        let completed = step(start.state, .sampleChanged, fresh)
        XCTAssertEqual(completed.effects, [.endTemporaryMode])
        XCTAssertEqual(completed.state.completion, fresh.completion)
    }

    func testContinuingDischargeUsesLatestLimitBandAtItsLaterExit() throws {
        let running = acknowledge(step(try enabled(), .intent(.startDischarge)).state).state
        let lower = step(running, .intent(.setLimit(70)))
        XCTAssertEqual(lower.state.temporaryMode, .discharging)
        let target = step(lower.state, .sampleChanged, input(69.99, seq: 2, time: 101))
        XCTAssertEqual(target.effects, [.endTemporaryMode])
        let stopped = acknowledge(target.state, input(69.99, seq: 2, time: 101))
        XCTAssertEqual(step(stopped.state, .tick, input(69.99, seq: 2, time: 101)).effects, [.inhibitCharging])
    }

    func testContradictedStartReceiptCannotBecomeNormalFullCompletion() throws {
        for (outcome, readback) in [(BatteryCareReply.Outcome.outcomeUnknown, BatteryCareReadback.confirmed(.allowed)),
                                    (.rejected(reason: "test-rejection"), .confirmed(.allowed)),
                                    (.accepted, .contradicted), (.accepted, .unknown)] {
            let start = step(try enabled(), .intent(.startFullCharge))
            var value = input(100, seq: 2, time: 101)
            value.completion = .confirmed(recordID: "test-full", sampleSequence: 2)
            value.execution = .init(effect: .allowCharging, generation: start.state.generation,
                                    outcome: outcome, readback: readback)
            let result = step(start.state, .executionObserved, value)
            XCTAssertEqual(result.state.completion, .unknown)
            XCTAssertTrue(result.state.requiresRetry)
            XCTAssertEqual(result.effects, [.releaseOwnedControls])
        }
    }

    func testRejectedNewStartCannotHideUnsafeExistingRegularControl() throws {
        let pending = step(try enabled(), .sampleChanged)
        var value = input()
        value.execution = .init(effect: .inhibitCharging, generation: pending.state.generation,
                                outcome: .accepted, readback: .confirmed(.inhibited))
        let regular = step(pending.state, .executionObserved, value)
        XCTAssertEqual(regular.state.confirmedPhase, .inhibited)
        value.sample = nil
        let denied = step(regular.state, .intent(.startFullCharge), value)
        XCTAssertEqual(denied.state.temporaryMode, .none)
        XCTAssertTrue(denied.state.requiresRetry)
        XCTAssertEqual(denied.effects, [.releaseOwnedControls])
        XCTAssertEqual(denied.state.confirmedPhase, .unknown)
    }

    func testInvalidLimitDuringTemporaryModeStopsRatherThanChasingUncertainTarget() throws {
        for intent in [BatteryCareIntent.startDischarge, .startFullCharge] {
            let running = acknowledge(step(try enabled(), .intent(intent)).state).state
            let invalid = step(running, .intent(.setLimit(49)))
            XCTAssertEqual(invalid.state.settings.limit, 80)
            XCTAssertEqual(invalid.state.temporaryMode, .none)
            XCTAssertTrue(invalid.state.requiresRetry)
            XCTAssertEqual(invalid.effects, [.releaseOwnedControls])
        }
    }

    func testCancelAndChangedLimitCannotBypassTemporaryOrPendingStartDeadlines() throws {
        let start = step(try enabled(), .intent(.startFullCharge))
        let running = acknowledge(start.state).state
        let progress = step(running, .sampleChanged, input(91, seq: 2, time: 190)).state
        let recentProgress = step(progress, .sampleChanged, input(92, seq: 3, time: 280)).state
        for event in [BatteryCareEvent.intent(.cancelFullCharge), .intent(.setLimit(85))] {
            let rows: [(BatteryCareState, BatteryCareContext, Bool)] = [
                (running, input(90, seq: 2, time: 199), false),
                (running, input(90, seq: 2, time: 200), true),
                (recentProgress, input(92, seq: 4, time: 299), false),
                (recentProgress, input(92, seq: 4, time: 300), true),
                (start.state, input(90, seq: 2, time: 119), false),
                (start.state, input(90, seq: 2, time: 120), true)
            ]
            for (state, value, expired) in rows {
                let result = step(state, event, value)
                XCTAssertEqual(result.state.temporaryMode, .none)
                XCTAssertEqual(result.effects, expired ? [.releaseOwnedControls] : [.endTemporaryMode])
                XCTAssertEqual(result.state.requiresRetry, expired)
                XCTAssertEqual(result.state.recoveryStatus, .unconfirmed)
                XCTAssertEqual(result.state.settings.limit, event == .intent(.setLimit(85)) ? 85 : 80)
                if expired {
                    let released = acknowledge(result.state, value).state
                    XCTAssertEqual(released.recoveryStatus, .released)
                    XCTAssertTrue(released.requiresRetry)
                    let fresh = input(92, seq: value.sample!.sequence + 1, time: value.nowUptime + 1)
                    XCTAssertEqual(step(released, .tick, fresh).effects, [])
                    XCTAssertEqual(step(released, .intent(.retryRegular), fresh).effects, [.inhibitCharging])
                }
            }
        }
    }

    func testFullCompletionNeedsPostStartSequenceAndTimeButValidOldEvidenceCanWait() throws {
        var initial = input(90, seq: 10, time: 100)
        initial.nowUptime = 110
        let started = step(try enabled(), .intent(.startFullCharge), initial)
        let running = acknowledge(started.state, initial).state
        for time in [UInt64(105), 110, 111] {
            var candidate = input(100, seq: 11, time: time)
            candidate.nowUptime = 112
            candidate.completion = .confirmed(recordID: "test-full", sampleSequence: 11)
            let result = step(running, .sampleChanged, candidate)
            XCTAssertFalse(result.state.requiresRetry)
            if time > 110 {
                XCTAssertEqual(result.state.completion, candidate.completion)
                XCTAssertEqual(result.effects, [.endTemporaryMode])
            } else {
                XCTAssertEqual(result.state.completion, .unknown)
                XCTAssertEqual(result.state.temporaryMode, .chargingToFull)
                XCTAssertEqual(result.effects, [])
            }
        }

        var alreadyFull = input(100, seq: 10, time: 100)
        alreadyFull.completion = .confirmed(recordID: "test-full", sampleSequence: 10)
        let fullStart = step(try enabled(), .intent(.startFullCharge), alreadyFull)
        alreadyFull.nowUptime = 101
        let receipt = acknowledge(fullStart.state, alreadyFull)
        XCTAssertEqual(receipt.state.temporaryMode, .chargingToFull)
        XCTAssertFalse(receipt.state.requiresRetry)
        XCTAssertNil(receipt.state.pendingEffect)
        XCTAssertEqual(receipt.state.completion, .unknown)
        XCTAssertEqual(receipt.effects, [])
        var fresh = input(100, seq: 11, time: 102)
        fresh.completion = .confirmed(recordID: "test-full", sampleSequence: 11)
        let completed = step(receipt.state, .sampleChanged, fresh)
        XCTAssertEqual(completed.effects, [.endTemporaryMode])
        XCTAssertEqual(completed.state.completion, fresh.completion)

        var missing = alreadyFull; missing.completion = .unknown
        let failed = step(fullStart.state, .tick, missing)
        XCTAssertEqual(failed.effects, [.releaseOwnedControls])
        XCTAssertTrue(failed.state.requiresRetry)
    }

    private func enabled(_ limit: Int = 80) throws -> BatteryCareState {
        .init(settings: try .init(isEnabled: true, limit: limit))
    }

    private func sample(_ p: Double = 90, seq: UInt64 = 1, time: UInt64 = 100,
                        power: Bool? = true, charging: Bool? = false) -> BatteryCareSample {
        .init(identity: identity, presence: .internalBattery, sequence: seq, observedAtUptime: time,
              systemPercentage: p, externalPower: power, isCharging: charging, lowBatteryProtection: false)
    }

    private func input(_ p: Double = 90, seq: UInt64 = 1, time: UInt64 = 100,
                       charging: Bool? = false) -> BatteryCareContext {
        .init(sample: sample(p, seq: seq, time: time, charging: charging), expectedIdentity: identity,
              capabilities: [.regularLimit: .verified(recordID: "test-regular"),
                             .manualDischarge: .verified(recordID: "test-discharge"),
                             .temporaryFullCharge: .verified(recordID: "test-full"),
                             .releaseOwnedControls: .verified(recordID: "test-release")],
              authorization: .authorized, recoveryStatus: .released,
              safetyLimits: try! .init(sampleIntervalNanoseconds: 10, maxSampleAgeNanoseconds: 50,
                  maxCommandAgeNanoseconds: 20, maxReadbackNanoseconds: 20, maxStopNanoseconds: 20,
                  leaseNanoseconds: 100, maxTemporaryModeNanoseconds: 200, maxNoProgressNanoseconds: 100),
              completion: .notComplete, nowUptime: time)
    }

    private func step(_ state: BatteryCareState, _ event: BatteryCareEvent,
                      _ context: BatteryCareContext? = nil) -> BatteryCareTransition {
        BatteryCarePolicy.reduce(state: state, event: event, context: context ?? input())
    }

    private func acknowledge(_ state: BatteryCareState, _ context: BatteryCareContext? = nil,
                             recovery: BatteryCareRecoveryStatus = .released) -> BatteryCareTransition {
        var value = context ?? input()
        value.recoveryStatus = recovery
        let effect = state.pendingEffect ?? .endTemporaryMode
        let readback: BatteryCareReadback = effect == .startDischarge ? .confirmed(.inhibited)
            : effect == .allowCharging ? .confirmed(.allowed) : .unknown
        value.execution = .init(effect: effect, generation: state.generation, outcome: .accepted, readback: readback)
        return step(state, .executionObserved, value)
    }
}
