import Foundation
import XCTest
import MacActivityBatteryControl

final class BatteryCarePolicyTests: XCTestCase {
    // All identities, verified records and nanosecond limits below are SYNTHETIC.
    // They are reducer inputs, not hardware validation, authentication or production defaults.
    private let identity = BatteryCareIdentity(batteryID: "synthetic-internal", modelIdentifier: "test-model", osBuild: "test-build")

    func testDefaultAndEditingNeverEnableControl() throws {
        for limit in [80, 60] {
            let settings = try BatteryCareSettings(limit: limit)
            let result = reduce(.init(), .settingsAccepted(settings))
            XCTAssertEqual(result.state.settings, settings)
            XCTAssertFalse(result.state.settings.isEnabled)
            XCTAssertEqual(result.effects, [])
            XCTAssertEqual(result.state.confirmedPhase, .unknown)
        }
        let settings = try BatteryCareSettings(isEnabled: true, limit: 60)
        let result = reduce(.init(), .settingsAccepted(settings), context: context(sample: sample(externalPower: false)))
        XCTAssertEqual(result.state.settings, settings)
        XCTAssertEqual(result.effects, [])
    }

    func testHysteresisUsesUnroundedSystemPercentage() throws {
        let rows: [(Int, Double, BatteryCareConfirmedPhase, [BatteryCareEffect])] = [
            (80, 79.99, .unknown, [.allowCharging]), (80, 80, .unknown, [.inhibitCharging]),
            (80, 80.01, .unknown, [.inhibitCharging]), (80, 75.01, .inhibited, []),
            (80, 75, .inhibited, [.allowCharging]), (80, 74.99, .inhibited, [.allowCharging]),
            (80, 79.99, .allowed, []), (80, 80, .allowed, [.inhibitCharging]),
            (50, 45.01, .inhibited, []), (50, 45, .inhibited, [.allowCharging]),
            (50, 49.99, .unknown, [.allowCharging]), (50, 50, .unknown, [.inhibitCharging]),
            (99, 94.01, .inhibited, []), (99, 94, .inhibited, [.allowCharging]),
            (99, 99, .allowed, [.inhibitCharging])
        ]
        for (limit, percentage, phase, effects) in rows {
            let result = reduce(try state(limit: limit, phase: phase), context: context(sample: sample(percentage)))
            XCTAssertEqual(result.effects, effects, "L=\(limit), p=\(percentage), phase=\(phase)")
            if !effects.isEmpty { XCTAssertEqual(result.state.confirmedPhase, .unknown) }
            XCTAssertFalse(result.effects.contains(.startDischarge))
        }
    }

    func testBandKeepsOnlyConfirmedPhase() throws {
        for phase in [BatteryCareConfirmedPhase.allowed, .inhibited] {
            let result = reduce(try state(phase: phase), context: context(sample: sample(77, isCharging: false)))
            XCTAssertEqual(result.state.confirmedPhase, phase)
            XCTAssertEqual(result.effects, [])
        }
        let initial = reduce(try state(), context: context(sample: sample(77, isCharging: false)))
        XCTAssertEqual(initial.effects, [.allowCharging])
        XCTAssertEqual(initial.state.confirmedPhase, .unknown)
        XCTAssertEqual(reduce(initial.state).effects, []) // no duplicate while awaiting readback

        let confirmed = observe(initial.state, effect: .allowCharging, readback: .confirmed(.allowed))
        XCTAssertEqual(confirmed.state.confirmedPhase, .allowed)
        XCTAssertNil(confirmed.state.pendingEffect)
        XCTAssertEqual(confirmed.effects, [])
        XCTAssertEqual(reduce(confirmed.state).effects, [])

        let stopped = reduce(try state(), context: context(sample: sample(80)))
        XCTAssertEqual(stopped.state.confirmedPhase, .unknown)
        let stopConfirmed = observe(stopped.state, effect: .inhibitCharging, readback: .confirmed(.inhibited))
        XCTAssertEqual(stopConfirmed.state.confirmedPhase, .inhibited)
        XCTAssertEqual(stopConfirmed.effects, [])
        XCTAssertEqual(reduce(stopConfirmed.state, context: context(sample: sample(75.01, sequence: 2, time: 101), now: 101)).effects, [])
    }

    func testNewLimitRebuildsPhase() throws {
        let rows: [(Int, Int, Double, BatteryCareConfirmedPhase, [BatteryCareEffect])] = [
            (80, 85, 82, .inhibited, [.allowCharging]), (80, 60, 70, .allowed, [.inhibitCharging]),
            (80, 85, 85, .allowed, [.inhibitCharging]), (80, 80, 77, .inhibited, [])
        ]
        for (old, new, percentage, phase, effects) in rows {
            let result = reduce(try state(limit: old, phase: phase),
                                .settingsAccepted(try BatteryCareSettings(isEnabled: true, limit: new)),
                                context: context(sample: sample(percentage)))
            XCTAssertEqual(result.state.settings.limit, new)
            XCTAssertEqual(result.effects, effects)
        }
        for (percentage, effect) in [(77.0, BatteryCareEffect.allowCharging), (80.0, .inhibitCharging)] {
            let sleeping = reduce(try state(phase: .inhibited), .lifecycle(.willSleep))
            XCTAssertEqual(sleeping.effects, [.releaseOwnedControls])
            XCTAssertEqual(sleeping.state.confirmedPhase, .unknown)
            XCTAssertEqual(sleeping.state.recoveryStatus, .unconfirmed)
            let released = observe(sleeping.state, effect: .releaseOwnedControls, readback: .unknown)
            let wake = reduce(released.state, .lifecycle(.didWake))
            XCTAssertEqual(wake.effects, []) // pre-wake sample is not revalidation
            let fresh = reduce(wake.state, context: context(sample: sample(percentage, sequence: 2, time: 101), now: 101))
            XCTAssertEqual(fresh.effects, [effect])
        }
    }

    func testRegular100ReleasesRestrictionWithoutFullClaim() throws {
        for percentage in [95.0, 100] {
            let result = reduce(try state(phase: .inhibited),
                                .settingsAccepted(try BatteryCareSettings(isEnabled: true, limit: 100)),
                                context: context(sample: sample(percentage)))
            XCTAssertEqual(result.effects, [.releaseOwnedControls])
            XCTAssertEqual(result.state.confirmedPhase, .unknown)
            XCTAssertEqual(result.state.temporaryMode, .none)
            XCTAssertEqual(result.state.recoveryStatus, .unconfirmed)
            let released = observe(result.state, effect: .releaseOwnedControls, readback: .unknown)
            XCTAssertEqual(released.state.recoveryStatus, .released)
            XCTAssertEqual(released.state.confirmedPhase, .unknown)
            for p in [94.0, 95, 99.99, 100] {
                XCTAssertEqual(reduce(released.state, context: context(sample: sample(p))).effects, [])
            }
        }
        // Already released baseline needs no redundant command, nor completion evidence.
        XCTAssertEqual(reduce(try state(limit: 100)).effects, [])
    }

    func testInvalidInputFailsClosed() throws {
        var invalid: [(String, BatteryCareContext)] = []
        for p in [Double?](arrayLiteral: .nan, .infinity, -.infinity, -0.01, 100.01, nil) {
            invalid.append(("invalid percentage \(String(describing: p))", context(sample: sample(p))))
        }
        invalid += [
            ("no sample", context(sample: nil)),
            ("too old", context(now: 151)), ("age boundary", context(now: 150)),
            ("future timestamp", context(now: 99)), ("no limits", context(limits: nil)),
            ("no regular capability", context(capabilities: [.releaseOwnedControls: .verified(recordID: "synthetic-release")])),
            ("no stop capability", context(capabilities: [.regularLimit: .verified(recordID: "synthetic-regular")])),
            ("unsupported", context(capabilities: [.regularLimit: .unsupported(reason: "synthetic")])),
            ("unverified", context(capabilities: [:])),
            ("not authorized", context(authorization: .notAuthorized)),
            ("unknown protection", context(sample: sample(lowProtection: nil))),
            ("unknown external power", context(sample: sample(externalPower: nil)))
        ]
        for recovery in [BatteryCareRecoveryStatus.unknown, .unconfirmed, .conflict] {
            invalid.append(("recovery \(recovery)", context(recovery: recovery)))
        }
        for (name, input) in invalid {
            for phase in [BatteryCareConfirmedPhase.unknown, .allowed, .inhibited] {
                let result = reduce(try state(phase: phase), context: input)
                XCTAssertFalse(result.effects.contains(.allowCharging), name)
                XCTAssertFalse(result.effects.contains(.inhibitCharging), name)
                XCTAssertFalse(result.effects.contains(.startDischarge), name)
                XCTAssertEqual(result.state.confirmedPhase, .unknown, name)
            }
        }
        XCTAssertEqual(reduce(try state(), context: context(now: 149)).effects, [.allowCharging])
        // Physical charging state and completion are not prerequisites for regular limiting.
        XCTAssertEqual(reduce(try state(), context: context(sample: sample(isCharging: nil))).effects, [.allowCharging])
    }

    func testPresenceIsNotInferredFromPercentage() throws {
        let other = BatteryCareIdentity(batteryID: "synthetic-UPS", modelIdentifier: "test-model", osBuild: "test-build")
        let mismatches = [other,
            BatteryCareIdentity(batteryID: identity.batteryID, modelIdentifier: "other-model", osBuild: identity.osBuild),
            BatteryCareIdentity(batteryID: identity.batteryID, modelIdentifier: identity.modelIdentifier, osBuild: "other-build")]
        var inputs = [context(sample: sample(presence: .absent)), context(sample: sample(presence: .unknown)),
                      context(sample: sample(identity: nil)), context(expectedIdentity: nil)]
        inputs += mismatches.map { context(sample: sample(identity: $0)) }
        for input in inputs {
            let result = reduce(try state(), context: input)
            XCTAssertEqual(result.effects, [])
            XCTAssertEqual(result.state.confirmedPhase, .unknown)
        }
        // Neither record names nor internalBattery presence supply a trusted comparison baseline.
        XCTAssertEqual(reduce(try state(), context: context(expectedIdentity: nil)).effects, [])
    }

    func testHardwareDisplayPreferenceCannotChangePolicy() throws {
        // Display choice/rounded hardware percentages deliberately never enter the context.
        for displayPercentage in [0.0, 75, 80, 100] {
            for displayHardware in [false, true] {
                let result = reduce(try state(), context: context(sample: sample(79.99)))
                XCTAssertEqual(result.effects, [.allowCharging], "display=\(displayPercentage), hardware=\(displayHardware)")
            }
        }
    }

    func testFrozenAndRegressingSamplesCannotRefreshAdmission() throws {
        let started = reduce(try state(phase: .allowed))
        for next in [sample(sequence: 1, time: 101), sample(78, sequence: 1),
                     sample(sequence: 0), sample(sequence: 2), sample(sequence: 2, time: 99)] {
            let result = reduce(started.state, context: context(sample: next, now: 101))
            XCTAssertTrue(result.state.requiresRetry)
            XCTAssertEqual(result.state.confirmedPhase, .unknown)
            XCTAssertEqual(result.effects, [.releaseOwnedControls])
        }
        let repeated = reduce(started.state, context: context(now: 149))
        XCTAssertEqual(repeated.state.confirmedPhase, .allowed)
        XCTAssertEqual(repeated.effects, [])
        let expired = reduce(repeated.state, .tick, context: context(now: 150))
        XCTAssertTrue(expired.state.requiresRetry)
        XCTAssertEqual(expired.effects, [.releaseOwnedControls])
        let advancing = reduce(started.state, context: context(sample: sample(sequence: 2, time: 101), now: 101))
        XCTAssertEqual(advancing.state.confirmedPhase, .allowed)
        XCTAssertEqual(advancing.effects, [])
    }

    func testExecutionAndRecoveryMustBothConfirmBeforeNewRisk() throws {
        let pending = reduce(try state())
        for (outcome, readback) in [(BatteryCareReply.Outcome.accepted, BatteryCareReadback.unknown),
                                   (.outcomeUnknown, .confirmed(.allowed)),
                                   (.rejected(reason: "synthetic"), .confirmed(.allowed)),
                                   (.accepted, .contradicted), (.accepted, .confirmed(.inhibited))] {
            let result = observe(pending.state, effect: .allowCharging, outcome: outcome, readback: readback)
            XCTAssertEqual(result.state.confirmedPhase, .unknown)
            XCTAssertTrue(result.state.requiresRetry)
            XCTAssertEqual(result.effects, [.releaseOwnedControls])
        }
        let unconfirmed = observe(pending.state, effect: .allowCharging, readback: .confirmed(.allowed), recovery: .unconfirmed)
        XCTAssertEqual(unconfirmed.state.confirmedPhase, .unknown)
        XCTAssertTrue(unconfirmed.state.requiresRetry)
        let old = observe(pending.state, effect: .allowCharging, readback: .confirmed(.allowed), generation: 99)
        XCTAssertEqual(old.state.pendingEffect, .allowCharging)
        XCTAssertEqual(old.state.confirmedPhase, .unknown)
        XCTAssertEqual(old.effects, [])
        let wrongEffect = observe(pending.state, effect: .inhibitCharging, readback: .confirmed(.inhibited))
        XCTAssertEqual(wrongEffect.state.pendingEffect, .allowCharging)
        XCTAssertEqual(wrongEffect.state.confirmedPhase, .unknown)

        let releasing = reduce(try state(phase: .inhibited), .settingsAccepted(.default))
        let notReleased = observe(releasing.state, effect: .releaseOwnedControls, readback: .unknown, recovery: .unconfirmed)
        XCTAssertEqual(notReleased.state.recoveryStatus, .unconfirmed)
        XCTAssertEqual(notReleased.state.confirmedPhase, .unknown)
        XCTAssertTrue(notReleased.state.requiresRetry)
    }

    func testPendingDeadlineAndFaultNeedExplicitRetry() throws {
        let pending = reduce(try state())
        XCTAssertEqual(reduce(pending.state, .tick, context: context(now: 119)).effects, [])
        let timeout = reduce(pending.state, .tick, context: context(now: 120))
        XCTAssertTrue(timeout.state.requiresRetry)
        XCTAssertEqual(timeout.state.confirmedPhase, .unknown)
        XCTAssertEqual(timeout.effects, [.releaseOwnedControls])
        let release = observe(timeout.state, effect: .releaseOwnedControls, readback: .unknown)
        XCTAssertEqual(reduce(release.state).effects, [])
        let retry = reduce(release.state, .retryRequested)
        XCTAssertEqual(retry.effects, [.allowCharging])
        XCTAssertFalse(retry.state.requiresRetry)
        let premature = reduce(timeout.state, .retryRequested)
        XCTAssertEqual(premature.effects, []) // context alone cannot acknowledge an outstanding release

        let stopTimeout = reduce(timeout.state, .tick, context: context(now: 140))
        XCTAssertEqual(stopTimeout.effects, []) // do not repeatedly issue an unconfirmed stop
        XCTAssertEqual(stopTimeout.state.recoveryStatus, .unconfirmed)
        var recoveredInput = context(now: 141)
        recoveredInput.execution = BatteryCareExecution(effect: .releaseOwnedControls,
            generation: stopTimeout.state.generation, outcome: .accepted, readback: .unknown)
        let recovered = reduce(stopTimeout.state, .executionObserved, context: recoveredInput)
        XCTAssertEqual(recovered.state.recoveryStatus, .released)
        XCTAssertNil(recovered.state.pendingEffect)
        XCTAssertTrue(recovered.state.requiresRetry) // late safe recovery is not a new risk grant
        XCTAssertEqual(recovered.effects, [])
    }

    func testChangedIntentDoesNotMistakeLateReadbackForCurrentPhase() throws {
        let pending = reduce(try state())
        let changed = reduce(pending.state, .settingsAccepted(try BatteryCareSettings(isEnabled: true, limit: 60)))
        XCTAssertEqual(changed.effects, [.releaseOwnedControls])
        XCTAssertEqual(changed.state.confirmedPhase, .unknown)
        let late = observe(changed.state, effect: .allowCharging, readback: .confirmed(.allowed), generation: pending.state.generation)
        XCTAssertEqual(late.state.confirmedPhase, .unknown)
        XCTAssertEqual(late.state.pendingEffect, .releaseOwnedControls)
        XCTAssertEqual(late.effects, [])
    }

    func testUnavailableReleaseCannotBeForgottenOrAcknowledgedByContextAlone() throws {
        let stopped = reduce(try state(phase: .inhibited), context: context(authorization: .notAuthorized))
        XCTAssertEqual(stopped.effects, [])
        XCTAssertEqual(stopped.state.recoveryStatus, .unconfirmed)
        let safeRelease = reduce(stopped.state)
        XCTAssertEqual(safeRelease.effects, [.releaseOwnedControls])
        XCTAssertEqual(safeRelease.state.recoveryStatus, .unconfirmed)

        let pending = reduce(try state())
        let fault = reduce(pending.state, context: context(authorization: .notAuthorized))
        XCTAssertNotEqual(fault.state.generation, pending.state.generation)
        XCTAssertNil(fault.state.pendingEffect) // retire the old risk even if release is unavailable
        let late = observe(fault.state, effect: .allowCharging, readback: .confirmed(.allowed))
        XCTAssertEqual(late.state.confirmedPhase, .unknown)
        XCTAssertTrue(late.state.requiresRetry)
        XCTAssertFalse(late.effects.contains(.allowCharging))
        XCTAssertFalse(late.effects.contains(.inhibitCharging))

        let conflict = reduce(try state(phase: .inhibited), context: context(recovery: .conflict))
        XCTAssertEqual(conflict.state.recoveryStatus, .conflict)
        let conflictObserved = observe(conflict.state, effect: .releaseOwnedControls, readback: .unknown, recovery: .conflict)
        XCTAssertEqual(conflictObserved.state.recoveryStatus, .conflict)
        XCTAssertEqual(conflictObserved.state.confirmedPhase, .unknown)

        let release = reduce(try state(phase: .inhibited), .settingsAccepted(.default))
        let contradictory = observe(release.state, effect: .releaseOwnedControls, readback: .confirmed(.inhibited))
        XCTAssertNotEqual(contradictory.state.recoveryStatus, .released)
        XCTAssertEqual(contradictory.state.pendingEffect, .releaseOwnedControls)
    }

    func testRegularSafetyAndFreshReplugAdmission() throws {
        for p in [0.0, 20] {
            let result = reduce(try state(phase: .inhibited), context: context(sample: sample(p)))
            XCTAssertEqual(result.effects, [.releaseOwnedControls])
            XCTAssertTrue(result.state.requiresRetry)
        }
        let protection = reduce(try state(phase: .inhibited), context: context(sample: sample(77, lowProtection: true)))
        XCTAssertEqual(protection.effects, [.releaseOwnedControls])
        XCTAssertTrue(protection.state.requiresRetry)
        XCTAssertEqual(reduce(try state(), context: context(sample: sample(20.01))).effects, [.allowCharging])

        let running = reduce(try state(phase: .inhibited))
        let unplug = reduce(running.state, context: context(sample: sample(externalPower: false)))
        XCTAssertEqual(unplug.effects, [.releaseOwnedControls])
        let released = observe(unplug.state, effect: .releaseOwnedControls, readback: .unknown)
        XCTAssertEqual(reduce(released.state).effects, []) // old plugged-in sample must not revive control
        let fresh = reduce(released.state, context: context(sample: sample(sequence: 2, time: 101), now: 101))
        XCTAssertEqual(fresh.effects, [.allowCharging])
    }

    func testDefaultsAndMissingExecutionNeverGrantConfirmation() throws {
        let input = BatteryCareContext(nowUptime: 100)
        for event in [BatteryCareEvent.sampleChanged, .tick, .retryRequested, .executionObserved,
                      .settingsAccepted(try BatteryCareSettings(isEnabled: true))] {
            let result = reduce(try state(), event, context: input)
            XCTAssertEqual(result.effects, [])
            XCTAssertEqual(result.state.confirmedPhase, .unknown)
        }
        let pending = reduce(try state())
        let missing = reduce(pending.state, .executionObserved)
        XCTAssertEqual(missing.state.pendingEffect, .allowCharging)
        XCTAssertEqual(missing.state.confirmedPhase, .unknown)
        XCTAssertEqual(missing.effects, [])

        for empty in [BatteryCareIdentity(batteryID: "", modelIdentifier: "test-model", osBuild: "test-build"),
                      BatteryCareIdentity(batteryID: "synthetic-internal", modelIdentifier: "", osBuild: "test-build"),
                      BatteryCareIdentity(batteryID: "synthetic-internal", modelIdentifier: "test-model", osBuild: "")] {
            let result = reduce(try state(), context: context(sample: sample(identity: empty), expectedIdentity: empty, limits: syntheticLimits()))
            XCTAssertEqual(result.effects, [])
        }
        var exhausted = try state()
        exhausted.generation = .max
        let result = reduce(exhausted)
        XCTAssertEqual(result.effects, [])
        XCTAssertTrue(result.state.requiresRetry)
        XCTAssertEqual(result.state.generation, .max)
    }

    func testRebuildingThresholdRetainsCleanupResponsibilityWhenSampleIsMissing() throws {
        let stopped = reduce(try state(), context: context(sample: sample(80)))
        let confirmed = observe(stopped.state, effect: .inhibitCharging, readback: .confirmed(.inhibited))
        XCTAssertEqual(confirmed.state.confirmedPhase, .inhibited)
        for event in [BatteryCareEvent.settingsAccepted(try BatteryCareSettings(isEnabled: true, limit: 85)),
                      .retryRequested] {
            let result = reduce(confirmed.state, event, context: context(sample: nil))
            XCTAssertEqual(result.effects, [.releaseOwnedControls])
            XCTAssertEqual(result.state.confirmedPhase, .unknown)
            XCTAssertEqual(result.state.pendingEffect, .releaseOwnedControls)
            XCTAssertEqual(result.state.recoveryStatus, .unconfirmed)
            XCTAssertTrue(result.state.requiresRetry)
            if case .settingsAccepted = event { XCTAssertEqual(result.state.settings.limit, 85) }
        }
    }

    func testUnplugPreservesSequenceAndTimeBaselineUntilFreshReplug() throws {
        let running = reduce(try state(phase: .inhibited), context: context(sample: sample(sequence: 10, time: 100)))
        for event in [BatteryCareEvent.sampleChanged, .lifecycle(.unplugged)] {
            let unplug = reduce(running.state, event,
                                context: context(sample: sample(sequence: 11, time: 101, externalPower: false), now: 101))
            XCTAssertEqual(unplug.effects, [.releaseOwnedControls])
            XCTAssertEqual(unplug.state.lastSample?.sequence, 11)
            XCTAssertEqual(unplug.state.lastSample?.observedAtUptime, 101)
            let released = observe(unplug.state, effect: .releaseOwnedControls, readback: .unknown)
            let plugged = reduce(released.state, .lifecycle(.pluggedIn), context: context(now: 101))
            for invalid in [sample(sequence: 10, time: 102), sample(sequence: 11, time: 102),
                            sample(sequence: 12, time: 101)] {
                let result = reduce(plugged.state, context: context(sample: invalid, now: 102))
                XCTAssertEqual(result.effects, [])
                XCTAssertEqual(result.state.confirmedPhase, .unknown)
            }
            let fresh = reduce(plugged.state, context: context(sample: sample(sequence: 12, time: 102), now: 102))
            XCTAssertEqual(fresh.effects, [.allowCharging])
        }
    }

    func testStaleReceiptCannotHideCurrentLossOfAdmission() throws {
        let pending = reduce(try state())
        for invalid in [context(authorization: .notAuthorized), context(sample: nil), context(capabilities: [:])] {
            var input = invalid
            input.execution = BatteryCareExecution(effect: .allowCharging, generation: pending.state.generation - 1,
                                                    outcome: .accepted, readback: .confirmed(.allowed))
            let lostAdmission = reduce(pending.state, .executionObserved, context: input)
            XCTAssertEqual(lostAdmission.state.confirmedPhase, .unknown)
            XCTAssertTrue(lostAdmission.state.requiresRetry)
            XCTAssertNotEqual(lostAdmission.state.generation, pending.state.generation)
            XCTAssertNotEqual(lostAdmission.state.pendingEffect, .allowCharging)
            XCTAssertEqual(lostAdmission.state.recoveryStatus, .unconfirmed)

            var restored = context()
            restored.execution = BatteryCareExecution(effect: .allowCharging, generation: pending.state.generation,
                                                       outcome: .accepted, readback: .confirmed(.allowed))
            let lateSuccess = reduce(lostAdmission.state, .executionObserved, context: restored)
            XCTAssertEqual(lateSuccess.state.confirmedPhase, .unknown)
            XCTAssertTrue(lateSuccess.state.requiresRetry)
            XCTAssertFalse(lateSuccess.effects.contains(.allowCharging))
            XCTAssertFalse(lateSuccess.effects.contains(.inhibitCharging))
        }
    }

    private func state(limit: Int = 80, phase: BatteryCareConfirmedPhase = .unknown) throws -> BatteryCareState {
        BatteryCareState(settings: try BatteryCareSettings(isEnabled: true, limit: limit), confirmedPhase: phase)
    }

    private func sample(
        _ percentage: Double? = 77, presence: BatteryCarePresence = .internalBattery,
        sequence: UInt64 = 1, time: UInt64 = 100, externalPower: Bool? = true,
        isCharging: Bool? = false, lowProtection: Bool? = false
    ) -> BatteryCareSample {
        sample(percentage, identity: identity, presence: presence, sequence: sequence, time: time,
               externalPower: externalPower, isCharging: isCharging, lowProtection: lowProtection)
    }

    private func sample(
        _ percentage: Double? = 77, identity: BatteryCareIdentity?, presence: BatteryCarePresence = .internalBattery,
        sequence: UInt64 = 1, time: UInt64 = 100, externalPower: Bool? = true,
        isCharging: Bool? = false, lowProtection: Bool? = false
    ) -> BatteryCareSample {
        BatteryCareSample(identity: identity, presence: presence, sequence: sequence, observedAtUptime: time,
                          systemPercentage: percentage, externalPower: externalPower,
                          isCharging: isCharging, lowBatteryProtection: lowProtection)
    }

    private func context(
        now: UInt64 = 100,
        capabilities: [BatteryCareOperation: BatteryCareCapability]? = nil,
        authorization: BatteryCareAuthorization = .authorized, recovery: BatteryCareRecoveryStatus = .released
    ) -> BatteryCareContext {
        context(sample: sample(), now: now, capabilities: capabilities, authorization: authorization, recovery: recovery)
    }

    private func context(
        sample: BatteryCareSample?, now: UInt64 = 100,
        capabilities: [BatteryCareOperation: BatteryCareCapability]? = nil,
        authorization: BatteryCareAuthorization = .authorized, recovery: BatteryCareRecoveryStatus = .released
    ) -> BatteryCareContext {
        context(sample: sample, expectedIdentity: identity, now: now,
                capabilities: capabilities, authorization: authorization, recovery: recovery, limits: syntheticLimits())
    }

    private func context(
        sample: BatteryCareSample? = nil, expectedIdentity: BatteryCareIdentity?, now: UInt64 = 100,
        capabilities: [BatteryCareOperation: BatteryCareCapability]? = nil,
        authorization: BatteryCareAuthorization = .authorized, recovery: BatteryCareRecoveryStatus = .released,
        limits: BatteryCareSafetyLimits?
    ) -> BatteryCareContext {
        BatteryCareContext(sample: sample, expectedIdentity: expectedIdentity,
                           capabilities: capabilities ?? [.regularLimit: .verified(recordID: "synthetic-regular"),
                                                          .releaseOwnedControls: .verified(recordID: "synthetic-release")],
                           authorization: authorization, recoveryStatus: recovery, safetyLimits: limits,
                           nowUptime: now)
    }

    private func context(limits: BatteryCareSafetyLimits?) -> BatteryCareContext {
        context(sample: sample(), expectedIdentity: identity, limits: limits)
    }

    private func context(expectedIdentity: BatteryCareIdentity?) -> BatteryCareContext {
        context(sample: sample(), expectedIdentity: expectedIdentity, limits: syntheticLimits())
    }

    private func syntheticLimits() -> BatteryCareSafetyLimits {
        try! BatteryCareSafetyLimits(sampleIntervalNanoseconds: 10, maxSampleAgeNanoseconds: 50,
                                     maxCommandAgeNanoseconds: 20, maxReadbackNanoseconds: 20,
                                     maxStopNanoseconds: 20, leaseNanoseconds: 100,
                                     maxTemporaryModeNanoseconds: 200, maxNoProgressNanoseconds: 100)
    }

    private func reduce(_ state: BatteryCareState, _ event: BatteryCareEvent = .sampleChanged,
                        context: BatteryCareContext? = nil) -> BatteryCareTransition {
        BatteryCarePolicy.reduce(state: state, event: event, context: context ?? self.context())
    }

    private func observe(
        _ state: BatteryCareState, effect: BatteryCareEffect, outcome: BatteryCareReply.Outcome = .accepted,
        readback: BatteryCareReadback, recovery: BatteryCareRecoveryStatus = .released, generation: UInt64? = nil
    ) -> BatteryCareTransition {
        var input = context(sample: state.lastSample ?? sample(), now: state.pendingSinceUptime ?? 100, recovery: recovery)
        input.execution = BatteryCareExecution(effect: effect, generation: generation ?? state.generation,
                                                outcome: outcome, readback: readback)
        return reduce(state, .executionObserved, context: input)
    }
}
