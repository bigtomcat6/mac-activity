import Combine
import XCTest
import MacActivityBatteryControl
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class BatteryCareModelTests: XCTestCase {
    func testRegular100DisablesOnlyFullChargeStartNotCancellation() async throws {
        let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true, limit: 100),
                                               snapshot: ready(enabled: true, limit: 100))
        await push(ready(enabled: true, limit: 100, revision: 2), service: service, model: model)
        XCTAssertFalse(model.presentation.startFullCharge.isEnabled)
        XCTAssertFalse(model.presentation.cancelFullCharge.isEnabled)
        XCTAssertNotNil(model.presentation.startFullCharge.disabledReason)
        await push(ready(enabled: true, limit: 100, revision: 3, mode: .chargingToFull),
                   service: service, model: model)
        XCTAssertTrue(model.presentation.cancelFullCharge.isEnabled, "A changed limit must never block cancellation")
        await model.cancelFullCharge()
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.cancelFullCharge])
    }

    func testPreviewDoesNotSaveOrSendAndCommitSavesFinalIntegerOnce() async {
        let (model, store, service, _) = makeModel()
        XCTAssertEqual(model.presentation.savedLimit, 80)
        XCTAssertFalse(model.presentation.savedEnabled)
        for limit in 70...85 { model.previewLimit(limit) }
        XCTAssertEqual(model.presentation.previewLimit, 85)
        XCTAssertEqual(store.attempts, 0)
        let before = await service.commands
        XCTAssertTrue(before.isEmpty)
        await model.commitPreview()
        XCTAssertEqual(store.values.map(\.batteryCare.limit), [85])
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setLimit(85)])
        XCTAssertFalse(model.presentation.savedEnabled)
        XCTAssertNil(model.presentation.effectiveTarget)
    }

    func testCancelPreviewForEscapeCloseOrPageSwitchHasNoSideEffects() async {
        let (model, store, service, _) = makeModel()
        for _ in 0..<3 {
            model.previewLimit(65)
            model.cancelPreview()
            await model.commitPreview()
        }
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertEqual(store.attempts, 0)
        let commands = await service.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testLimitValidatesAndSavesBeforeSendAndFailureDoesNotSend() async {
        let (model, store, service, _) = makeModel()
        await service.onSend { _ in XCTAssertEqual(store.values.last?.batteryCare.limit, 72) }
        model.previewLimit(49)
        await model.commitPreview()
        XCTAssertEqual(store.attempts, 0)
        model.previewLimit(72)
        await model.commitPreview()
        store.fails = true
        model.previewLimit(77)
        await model.commitPreview()
        XCTAssertEqual(model.presentation.savedLimit, 72)
        XCTAssertNil(model.presentation.previewLimit)
        XCTAssertEqual(model.presentation.saveFailure, .limit)
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setLimit(72)])
    }

    func testSavedLimitSurvivesHardwareFailureWithoutAppliedClaim() async {
        let (model, _, service, _) = makeModel()
        await service.setOutcome(.outcomeUnknown)
        model.previewLimit(71)
        await model.commitPreview()
        XCTAssertEqual(model.presentation.savedLimit, 71)
        XCTAssertEqual(model.presentation.requestOutcome, .outcomeUnknown)
        XCTAssertNil(model.presentation.effectiveTarget)
    }

    func testEnableRejectionNeverSavesTrueOrAutomaticallyRetries() async {
        let (model, store, service, _) = makeModel(snapshot: ready())
        await service.setOutcome(.rejected(reason: "authorizationDenied"))
        await model.setManagementEnabled(true)
        XCTAssertFalse(model.presentation.savedEnabled)
        XCTAssertEqual(store.attempts, 0)
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setManagement(true)])
    }

    func testEnableSavesOnlyAfterAdmissionAndFailedSaveRequestsRelease() async {
        let (model, store, service, _) = makeModel(snapshot: ready())
        await service.onSend { command in
            if command.intent == .setManagement(true) { XCTAssertEqual(store.attempts, 0) }
        }
        store.fails = true
        await model.setManagementEnabled(true)
        XCTAssertFalse(model.presentation.savedEnabled)
        XCTAssertEqual(model.presentation.saveFailure, .enable)
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setManagement(true), .setManagement(false)])
        guard commands.count == 2 else { return }
        XCTAssertLessThan(commands[0].generation, commands[1].generation)
    }

    func testDisableSaveFailureStillRevokesAndReportsUnsavedDisable() async throws {
        let (model, store, service, _) = makeModel(settings: try .init(isEnabled: true), snapshot: ready(enabled: true))
        store.fails = true
        await model.setManagementEnabled(false)
        XCTAssertTrue(model.presentation.savedEnabled)
        XCTAssertEqual(model.presentation.saveFailure, .disable)
        XCTAssertNil(model.presentation.requestedTarget)
        XCTAssertNil(model.presentation.effectiveTarget)
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setManagement(false)])
    }

    func testAcceptedReadbackAndPhysicalObservationRemainSeparate() async throws {
        let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true), snapshot: ready(enabled: true))
        model.previewLimit(75)
        await model.commitPreview()
        XCTAssertNil(model.presentation.effectiveTarget)
        guard let command = await service.commands.last else { return XCTFail("Missing committed request") }
        await push(ready(enabled: true, limit: 75, generation: command.generation, revision: 10,
                         status: .accepted(requestID: command.requestID), phase: .inhibited,
                         readback: .confirmed(.inhibited)), service: service, model: model)
        XCTAssertEqual(model.presentation.effectiveTarget, .regular(limit: 75))
        XCTAssertEqual(model.presentation.physicalObservation, .unknown)
        XCTAssertEqual(model.presentation.completion, .unknown)
    }

    func testLateSnapshotCannotOverwriteNewIntent() async {
        let (model, _, service, _) = makeModel()
        model.previewLimit(70)
        await model.commitPreview()
        model.previewLimit(90)
        await model.commitPreview()
        let commands = await service.commands
        guard commands.count == 2 else { return XCTFail("Missing committed requests") }
        await push(ready(limit: 90, generation: commands[1].generation, revision: 20), service: service, model: model)
        await service.push(ready(limit: 70, generation: commands[0].generation, revision: 100))
        await service.push(ready(limit: 60, generation: commands[1].generation, revision: 19))
        await push(ready(limit: 90, generation: commands[1].generation, revision: 21), service: service, model: model)
        XCTAssertEqual(model.presentation.savedLimit, 90)
        XCTAssertEqual(model.presentation.acceptedSettings?.limit, 90)
        XCTAssertEqual(model.presentation.revision, 21)
        XCTAssertNotEqual(model.presentation.requestedTarget, .regular(limit: 70))
        await model.retryRegular()
        XCTAssertGreaterThan(model.presentation.generation, commands[1].generation)
    }

    func testAcceptedEnableSupersededByLimitStillPersistsLatestLimit() async {
        let (model, store, service, _) = makeModel(snapshot: ready())
        let entered = expectation(description: "enable send")
        await service.holdNextSend(entered)
        let enable = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [entered], timeout: 2)
        model.previewLimit(88)
        await model.commitPreview()
        await service.resumeSend(.accepted)
        await enable.value
        XCTAssertTrue(model.presentation.savedEnabled)
        XCTAssertEqual(store.values.last?.batteryCare.limit, 88)
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setManagement(true), .setLimit(88)])
    }

    func testLateEnableCannotUndoDisableOrSleep() async {
        for sleep in [false, true] {
            let (model, _, service, _) = makeModel(snapshot: ready())
            let entered = expectation(description: "enable")
            await service.holdNextSend(entered)
            let enable = Task { await model.setManagementEnabled(true) }
            await fulfillment(of: [entered], timeout: 2)
            if sleep { await model.handleLifecycle(.willSleep) }
            else { await model.setManagementEnabled(false) }
            await service.resumeSend(.accepted)
            await enable.value
            XCTAssertFalse(model.presentation.savedEnabled)
            XCTAssertNil(model.presentation.effectiveTarget)
        }
    }

    func testDisconnectStillAllowsCancelAndCannotClaimRestoredRegular() async throws {
        let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true),
            snapshot: ready(enabled: true, mode: .chargingToFull))
        await model.handleLifecycle(.connectionLost)
        await service.setOutcome(.outcomeUnknown)
        XCTAssertTrue(model.presentation.cancelFullCharge.isEnabled)
        await model.cancelFullCharge()
        XCTAssertEqual(model.presentation.lastIntent, .cancelFullCharge)
        XCTAssertEqual(model.presentation.requestOutcome, .outcomeUnknown)
        XCTAssertNil(model.presentation.effectiveTarget)
        XCTAssertEqual(model.presentation.recoveryStatus, .unknown)
    }

    func testPersistedEnableWithUnavailableServiceIsPausedNotResumed() async throws {
        let store = MemoryBatteryPreferences(settings: try .init(isEnabled: true, limit: 67))
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let model = BatteryCareModel(preferences: preferences, service: UnavailableBatteryCareService())
        let result = await model.shutdown()
        XCTAssertTrue(model.presentation.savedEnabled)
        XCTAssertTrue(model.presentation.isSuspended)
        XCTAssertNil(model.presentation.effectiveTarget)
        XCTAssertNil(model.presentation.currentSystemPercentage)
        XCTAssertEqual(result, .noControlAcquired)
        XCTAssertEqual(store.attempts, 0)
    }

    func testAbsentBatteryDisablesEditingButUnknownCanSaveIntent() async {
        let absent = BatteryCareSnapshot(sample: .init(identity: nil, presence: .absent, sequence: 1,
            observedAtUptime: 100, systemPercentage: nil, externalPower: nil, isCharging: nil, lowBatteryProtection: nil))
        let (model, store, _, _) = makeModel(snapshot: absent)
        await model.handleLifecycle(.didWake)
        XCTAssertEqual(model.presentation.presence, .absent)
        XCTAssertEqual(model.presentation.editLimit.disabledReason, .noInternalBattery)
        model.previewLimit(60)
        await model.commitPreview()
        XCTAssertEqual(store.attempts, 0)
        let (unknown, unknownStore, _, _) = makeModel()
        unknown.previewLimit(60)
        await unknown.commitPreview()
        XCTAssertEqual(unknown.presentation.presence, .unknown)
        XCTAssertEqual(unknownStore.values.last?.batteryCare.limit, 60)
    }

    func testUnrelatedMetricsCannotRefreshBatteryControlSample() async {
        let value = ready(isCharging: nil)
        let clock = BatteryModelClock()
        let (model, _, service, preferences) = makeModel(snapshot: value, now: clock.now)
        let metrics = MetricsStore()
        metrics.apply([.battery(.init(percentage: 82.5, isCharging: false, hardwarePercentage: 96))])
        await model.handleLifecycle(.didWake)
        XCTAssertEqual(model.presentation.currentSystemPercentage, 82.5)
        let sample = model.presentation.sample
        preferences.setShowsHardwareBatteryPercentage(true)
        // Real display store refreshes independently; its timestamp is never control evidence.
        for revision in 10...15 {
            metrics.apply([.cpu(.init(usagePercent: Double(revision)))],
                          timestamp: Date(timeIntervalSince1970: Double(revision)))
            await push(ready(generation: model.presentation.generation, revision: UInt64(revision), isCharging: nil),
                       service: service, model: model)
        }
        XCTAssertEqual(model.presentation.sample, sample)
        XCTAssertEqual(model.presentation.currentSystemPercentage, 82.5)
        XCTAssertNil(model.presentation.isCharging)
        XCTAssertEqual(model.presentation.sample?.observedAtUptime, 100)
        XCTAssertEqual(metrics.snapshot.timestamp, Date(timeIntervalSince1970: 15))
        XCTAssertEqual(metrics.snapshot.battery?.displayPercentage(showsHardwarePercentage: preferences.state.showsHardwareBatteryPercentage), 96)
        clock.set(120) // Exact sample-age boundary; CPU revisions must not extend it.
        await push(ready(generation: model.presentation.generation, revision: 16, isCharging: nil), service: service, model: model)
        XCTAssertEqual(model.presentation.sample, sample)
        XCTAssertNil(model.presentation.currentSystemPercentage)
    }

    func testShutdownUsesQuitAndDoesNotMistakeAcceptedForReleased() async {
        let (model, _, service, _) = makeModel(snapshot: ready())
        await model.setManagementEnabled(true)
        let result = await model.shutdown()
        XCTAssertEqual(result, .unconfirmed)
        let events = await service.lifecycles
        XCTAssertEqual(events.map(\.0), [.quit])
    }

    func testPendingTemporaryTargetIsNotRegularOrEffectiveAndActionsUseRealCommands() async throws {
        let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true), snapshot: ready(enabled: true))
        let entered = expectation(description: "full charge requested")
        await service.holdNextSend(entered)
        let full = Task { await model.startFullCharge() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(model.presentation.requestedTarget, .fullCharge)
        XCTAssertNil(model.presentation.effectiveTarget)
        await service.resumeSend(.accepted)
        await full.value
        await model.cancelFullCharge()
        await model.startDischarge()
        await model.stopDischarge()
        await model.retryRegular()
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.startFullCharge, .cancelFullCharge, .startDischarge, .stopDischarge, .retryRegular])
        XCTAssertEqual(commands.map(\.generation), [1, 2, 3, 4, 5])
        XCTAssertEqual(Set(commands.map(\.requestID)).count, 5)
    }

    func testUnconfirmedRestorationDoesNotPromoteRegularEvenWithFullCompletion() async throws {
        let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true),
            snapshot: ready(enabled: true, mode: .chargingToFull))
        await model.cancelFullCharge()
        let generation = model.presentation.generation
        let failedRestoration = BatteryCareSnapshot(settings: try .init(isEnabled: true),
            sample: ready().sample, capabilities: ready().capabilities, authorization: .authorized,
            requestStatus: .outcomeUnknown(requestID: UUID()), recoveryStatus: .unconfirmed,
            safetyLimits: ready().safetyLimits, generation: generation, revision: 10,
            completion: .confirmed(recordID: "test-only", sampleSequence: 1))
        await push(failedRestoration, service: service, model: model)
        XCTAssertEqual(model.presentation.completion, .confirmed(recordID: "test-only", sampleSequence: 1))
        XCTAssertNil(model.presentation.effectiveTarget)
        XCTAssertTrue(model.presentation.cancelFullCharge.isEnabled)
    }

    func testNewModelStartsAboveServiceGenerationAndNeverWrapsAtExhaustion() async {
        let (model, _, service, _) = makeModel(snapshot: ready(generation: 50, revision: 20))
        model.previewLimit(74)
        await model.commitPreview()
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.generation), [51])

        let (exhausted, _, exhaustedService, _) = makeModel(snapshot: ready(generation: .max, revision: 30))
        await exhausted.startFullCharge()
        let overflow = await exhaustedService.commands
        XCTAssertTrue(overflow.isEmpty)
        XCTAssertEqual(exhausted.presentation.requestOutcome, .outcomeUnknown)
        XCTAssertTrue(exhausted.presentation.isSuspended)
    }

    func testVerifiedQuitReleaseIsSeparateFromNoControlAcquired() async {
        let (model, _, service, _) = makeModel(snapshot: ready())
        await model.setManagementEnabled(true)
        await service.setLifecycleResponse(.accepted, snapshot: .init(
            requestStatus: .accepted(requestID: UUID()), recoveryStatus: .released, generation: 2, revision: 20))
        let result = await model.shutdown()
        XCTAssertEqual(result, .released)
    }

    func testUnknownEnableCannotLeaveUnpersistedControlRunning() async {
        let (model, store, service, _) = makeModel(snapshot: ready())
        await service.setOutcome(.outcomeUnknown)
        await model.setManagementEnabled(true)
        XCTAssertEqual(store.attempts, 0)
        XCTAssertFalse(model.presentation.savedEnabled)
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setManagement(true), .setManagement(false)])
        XCTAssertNil(model.presentation.effectiveTarget)
        let result = await model.shutdown()
        XCTAssertEqual(result, .unconfirmed)
    }

    func testCurrentPercentageRequiresServiceSampleIdentityAndFreshness() async {
        let identity = BatteryCareIdentity(batteryID: "test", modelIdentifier: "test", osBuild: "test")
        for (percentage, observedAt, sampleIdentity) in [
            (Double.nan, UInt64(100), identity as BatteryCareIdentity?),
            (101, 100, identity), (82, 81, identity), (82, 102, identity), (82, 100, nil)
        ] {
            let invalid = BatteryCareSnapshot(sample: .init(identity: sampleIdentity, presence: .internalBattery,
                sequence: 1, observedAtUptime: observedAt, systemPercentage: percentage,
                externalPower: true, isCharging: nil, lowBatteryProtection: nil), safetyLimits: ready().safetyLimits)
            let (model, _, _, _) = makeModel(snapshot: invalid)
            await model.handleLifecycle(.didWake)
            XCTAssertNil(model.presentation.currentSystemPercentage)
            XCTAssertNil(model.presentation.isCharging)
        }
    }

    func testShutdownCannotClaimNoControlWhileRiskReplyIsUnresolved() async {
        let (model, _, service, _) = makeModel(snapshot: ready())
        let entered = expectation(description: "unresolved enable")
        await service.holdNextSend(entered)
        let enable = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [entered], timeout: 2)
        let result = await model.shutdown()
        XCTAssertEqual(result, .unconfirmed)
        await service.resumeSend(.rejected(reason: "superseded"))
        await enable.value
    }

    func testOlderReplyCannotOverwriteNewerSameGenerationSnapshot() async throws {
        let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true), snapshot: ready(enabled: true))
        let entered = expectation(description: "limit pending")
        await service.holdNextSend(entered)
        model.previewLimit(75)
        let commit = Task { await model.commitPreview() }
        await fulfillment(of: [entered], timeout: 2)
        await push(ready(enabled: true, limit: 75, generation: 1, revision: 20,
                         status: .outcomeUnknown(requestID: UUID())), service: service, model: model)
        await service.resumeSend(.accepted)
        await commit.value
        XCTAssertEqual(model.presentation.revision, 20)
        XCTAssertEqual(model.presentation.requestOutcome, .outcomeUnknown)
        XCTAssertNil(model.presentation.effectiveTarget)
    }

    func testNewPendingIntentNeverPublishesPreviousEffectiveTarget() async throws {
        let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true))
        await push(ready(enabled: true, revision: 2, phase: .inhibited, readback: .confirmed(.inhibited)),
                   service: service, model: model)
        XCTAssertEqual(model.presentation.effectiveTarget, .regular(limit: 80))
        let subscription = model.$presentation.sink {
            if $0.lastIntent == .setLimit(75), $0.isPending { XCTAssertNil($0.effectiveTarget) }
        }
        model.previewLimit(75)
        await model.commitPreview()
        subscription.cancel()
    }

    func testActiveTemporaryModeDisablesNewStartsButKeepsCancelAndDisableAvailable() async throws {
        let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true))
        await push(ready(enabled: true, revision: 2, mode: .chargingToFull), service: service, model: model)
        XCTAssertEqual(model.presentation.startDischarge.disabledReason, .temporaryModeActive)
        XCTAssertEqual(model.presentation.startFullCharge.disabledReason, .temporaryModeActive)
        XCTAssertTrue(model.presentation.cancelFullCharge.isEnabled)
        XCTAssertTrue(model.presentation.disableManagement.isEnabled)
        XCTAssertTrue(model.presentation.editLimit.isEnabled)
    }

    func testRejectedTemporaryStartDoesNotLeaveAFalseActiveTargetOrCancelButton() async throws {
        let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true), snapshot: ready(enabled: true))
        await service.setOutcome(.rejected(reason: "admissionBlocked"))
        await model.startFullCharge()
        XCTAssertFalse(model.presentation.cancelFullCharge.isEnabled)
        XCTAssertEqual(model.presentation.requestedTarget, .regular(limit: 80))
        XCTAssertEqual(model.presentation.requestOutcome, .rejected(reason: "admissionBlocked"))
        await model.startDischarge()
        XCTAssertFalse(model.presentation.stopDischarge.isEnabled)
    }

    func testEnableSupersededBySleepIsWithdrawnBeforeWakeOrPlugIn() async {
        let (model, store, service, _) = makeModel(snapshot: ready())
        let entered = expectation(description: "admitted enable awaiting reply")
        await service.holdNextSend(entered)
        let enable = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [entered], timeout: 2)
        let commands = await service.commands
        guard let command = commands.last else { return XCTFail("Missing enable") }
        await push(ready(enabled: true, generation: command.generation, revision: 2,
                         status: .pending(requestID: command.requestID)), service: service, model: model)
        await model.handleLifecycle(.willSleep)
        await service.resumeSend(.accepted)
        await enable.value
        await model.handleLifecycle(.didWake)
        await model.handleLifecycle(.pluggedIn)
        let finalCommands = await service.commands
        XCTAssertEqual(finalCommands.map(\.intent), [.setManagement(true), .setManagement(false)])
        XCTAssertEqual(store.attempts, 0)
        XCTAssertFalse(model.presentation.savedEnabled)
        XCTAssertNil(model.presentation.effectiveTarget)
    }

    func testLateEnableCleanupCannotRevokeNewExplicitEnable() async {
        let (model, store, service, _) = makeModel(snapshot: ready())
        let entered = expectation(description: "older enable")
        await service.holdNextSend(entered)
        let older = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [entered], timeout: 2)
        await model.handleLifecycle(.willSleep)
        let newerEntered = expectation(description: "newer explicit enable still pending")
        await service.holdNextSend(newerEntered)
        let newer = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [newerEntered], timeout: 2)
        await service.resumeSend(.accepted)
        await older.value
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setManagement(true), .setManagement(true)])
        XCTAssertEqual(store.attempts, 0)
        await service.resumeSend(.accepted)
        await newer.value
        XCTAssertTrue(model.presentation.savedEnabled)
        XCTAssertEqual(store.attempts, 1)
    }

    func testEnableSynchronizesNonDefaultSavedLimitBeforeAdmission() async throws {
        let cases: [(Int, [BatteryCareIntent])] = [
            (80, [.setLimit(60), .setManagement(true)]), (60, [.setManagement(true)])
        ]
        for (serviceLimit, expected) in cases {
            let (model, store, service, _) = makeModel(settings: try .init(limit: 60), snapshot: ready(limit: serviceLimit))
            await service.onSend { _ in XCTAssertEqual(store.attempts, 0) }
            await model.setManagementEnabled(true)
            let commands = await service.commands
            XCTAssertEqual(commands.map(\.intent), expected)
            XCTAssertEqual(store.values.map(\.batteryCare), [try .init(isEnabled: true, limit: 60)])
        }
    }

    func testNewerRejectedEnableWithdrawsOlderUnpersistedGrantItInherited() async {
        let (model, store, service, _) = makeModel(snapshot: ready())
        let olderEntered = expectation(description: "older admitted enable")
        await service.holdNextSend(olderEntered)
        let older = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [olderEntered], timeout: 2)
        await model.handleLifecycle(.willSleep)
        let newerEntered = expectation(description: "newer enable")
        await service.holdNextSend(newerEntered)
        let newer = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [newerEntered], timeout: 2)
        await service.resumeSend(.accepted)
        await older.value
        let commands = await service.commands
        guard let latest = commands.last else { return XCTFail("Missing newer enable") }
        // A4 rejects a fresh enable without erasing settings from an earlier admitted intent.
        await push(ready(enabled: true, generation: latest.generation, revision: 4,
                         status: .rejected(requestID: latest.requestID, reason: "authorizationDenied")),
                   service: service, model: model)
        await service.resumeSend(.rejected(reason: "authorizationDenied"))
        await newer.value
        let finalCommands = await service.commands
        XCTAssertEqual(finalCommands.map(\.intent), [.setManagement(true), .setManagement(true), .setManagement(false)])
        XCTAssertEqual(store.attempts, 0)
        XCTAssertFalse(model.presentation.savedEnabled)
    }

    func testEnablePreparationUsesNewerAcceptedSavedLimitWithoutRedundantSync() async throws {
        let (model, store, service, _) = makeModel(settings: try .init(limit: 60), snapshot: ready())
        let entered = expectation(description: "initial limit sync")
        await service.holdNextSend(entered)
        let enable = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [entered], timeout: 2)
        model.previewLimit(55)
        await model.commitPreview()
        let commands = await service.commands
        guard let latest = commands.last else { return XCTFail("Missing new saved limit") }
        await push(ready(limit: 55, generation: latest.generation, revision: 3,
                         status: .accepted(requestID: latest.requestID)), service: service, model: model)
        await service.resumeSend(.accepted)
        await enable.value
        let finalCommands = await service.commands
        XCTAssertEqual(finalCommands.map(\.intent), [.setLimit(60), .setLimit(55), .setManagement(true)])
        XCTAssertEqual(store.values.last?.batteryCare, try .init(isEnabled: true, limit: 55))
    }

    func testLimitPreparationFailureOrLifecycleCannotProceedToEnable() async throws {
        for outcome: BatteryCareReply.Outcome in [.rejected(reason: "notAccepted"), .outcomeUnknown] {
            let (model, store, service, _) = makeModel(settings: try .init(limit: 60), snapshot: ready())
            await service.setOutcome(outcome)
            await model.setManagementEnabled(true)
            let commands = await service.commands
            XCTAssertEqual(commands.map(\.intent), [.setLimit(60)])
            XCTAssertEqual(store.attempts, 0)
        }
        let (model, store, service, _) = makeModel(settings: try .init(limit: 60), snapshot: ready())
        let entered = expectation(description: "limit preparation")
        await service.holdNextSend(entered)
        let enable = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [entered], timeout: 2)
        await model.handleLifecycle(.willSleep)
        await service.resumeSend(.accepted)
        await enable.value
        let commands = await service.commands
        XCTAssertEqual(commands.map(\.intent), [.setLimit(60)])
        XCTAssertEqual(store.attempts, 0)
    }

    func testInheritedGrantIsWithdrawnWhenPreparationExitsForSleep() async {
        await checkInheritedGrantPreparationExit(.accepted, sleep: true)
    }

    func testInheritedGrantIsWithdrawnWhenPreparationIsRejected() async {
        await checkInheritedGrantPreparationExit(.rejected(reason: "commandExpired"))
    }

    func testInheritedGrantIsWithdrawnWhenPreparationOutcomeIsUnknown() async {
        await checkInheritedGrantPreparationExit(.outcomeUnknown)
    }

    func testSupersededPreparationCleanupCannotWithdrawNewerEnable() async {
        await checkInheritedGrantPreparationExit(.outcomeUnknown, newerEnable: true)
    }

    private func checkInheritedGrantPreparationExit(_ outcome: BatteryCareReply.Outcome,
                                                    sleep: Bool = false, newerEnable: Bool = false) async {
        let (model, store, service, _) = makeModel(snapshot: ready())
        let admitted = expectation(description: "older admitted enable awaiting reply")
        await service.holdNextSend(admitted)
        let older = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [admitted], timeout: 2)
        let firstCommands = await service.commands
        guard let first = firstCommands.last else { return XCTFail("Missing older enable") }
        await push(ready(enabled: true, generation: first.generation, revision: 2,
                         status: .pending(requestID: first.requestID)), service: service, model: model)

        let limitSent = expectation(description: "new limit saved with service snapshot still in transit")
        await service.holdNextSend(limitSent)
        model.previewLimit(60)
        let commit = Task { await model.commitPreview() }
        await fulfillment(of: [limitSent], timeout: 2)
        let preparing = expectation(description: "new choice preparing saved limit")
        await service.holdNextSend(preparing)
        let enable = Task { await model.setManagementEnabled(true) }
        await fulfillment(of: [preparing], timeout: 2)
        await service.resumeSend(.accepted) // Older grant is now owned by the newer choice.
        await older.value
        await service.resumeSend(.accepted)
        await commit.value

        var newest: Task<Void, Never>?
        if newerEnable {
            let newestPreparing = expectation(description: "newest explicit enable still pending")
            await service.holdNextSend(newestPreparing)
            newest = Task { await model.setManagementEnabled(true) }
            await fulfillment(of: [newestPreparing], timeout: 2)
        }
        if sleep { await model.handleLifecycle(.willSleep) }
        await service.resumeSend(outcome)
        await enable.value
        let commands = await service.commands
        let prefix: [BatteryCareIntent] = [.setManagement(true), .setLimit(60), .setLimit(60)]
        XCTAssertEqual(commands.map(\.intent), prefix + (newerEnable ? [.setLimit(60)] : [.setManagement(false)]))
        XCTAssertEqual(store.attempts, 1)
        XCTAssertEqual(store.values.last?.batteryCare.limit, 60)
        XCTAssertFalse(model.presentation.savedEnabled)
        if let newest {
            await service.resumeSend(.accepted)
            await newest.value
            XCTAssertTrue(model.presentation.savedEnabled)
            let finalCommands = await service.commands
            XCTAssertFalse(finalCommands.contains { $0.intent == .setManagement(false) })
        } else {
            await model.handleLifecycle(.didWake)
            await model.handleLifecycle(.pluggedIn)
            XCTAssertFalse(model.presentation.savedEnabled)
            XCTAssertNil(model.presentation.effectiveTarget)
        }
    }

    func testSavedLimitAndFailedEnablePersistenceWithRealSessionStayDisabledAfterWakeAndPlug() async throws {
        let snapshot = ready()
        let identity = BatteryCareIdentity(batteryID: "test", modelIdentifier: "test", osBuild: "test")
        let backend = RegularReplyBatteryBackend(context: .init(
            sample: .init(identity: identity, presence: .internalBattery, sequence: 1, observedAtUptime: 100,
                          systemPercentage: 70, externalPower: true, isCharging: false, lowBatteryProtection: false),
            expectedIdentity: identity, capabilities: snapshot.capabilities, authorization: .authorized,
            recoveryStatus: .released, safetyLimits: snapshot.safetyLimits, nowUptime: 101))
        let session = BatteryCareSession(backend: backend, now: { 101 })
        let store = MemoryBatteryPreferences(settings: try .init(limit: 60))
        store.fails = true
        let model = BatteryCareModel(preferences: .init(store: store, launchService: NoopLaunchAtLoginService()),
                                     service: session, now: { 101 })
        await model.setManagementEnabled(true)
        let beforeWake = await session.snapshot()
        XCTAssertEqual(beforeWake.settings, try .init(limit: 60))
        let effects = await backend.effects
        XCTAssertEqual(effects, [.inhibitCharging, .releaseOwnedControls])
        for event: BatteryCareLifecycleEvent in [.didWake, .pluggedIn] {
            await model.handleLifecycle(event)
            let afterLifecycle = await session.snapshot()
            XCTAssertFalse(afterLifecycle.settings.isEnabled)
        }
        XCTAssertFalse(model.presentation.savedEnabled)
        XCTAssertEqual(model.presentation.saveFailure, .enable)
        let finalEffects = await backend.effects
        XCTAssertEqual(finalEffects, [.inhibitCharging, .releaseOwnedControls])
    }

    func testPendingAdmissionKeepsTemporaryCancelAndMutualExclusionUntilConfirmedStop() async throws {
        for fullCharge in [true, false] {
            let (model, _, service, _) = makeModel(settings: try .init(isEnabled: true), snapshot: ready(enabled: true))
            let entered = expectation(description: "temporary admission pending")
            await service.holdNextSend(entered)
            let start = Task {
                if fullCharge { await model.startFullCharge() }
                else { await model.startDischarge() }
            }
            await fulfillment(of: [entered], timeout: 2)
            let commands = await service.commands
            guard let command = commands.last else { return XCTFail("Missing temporary start") }
            await push(ready(enabled: true, generation: command.generation, revision: 2,
                             status: .pending(requestID: command.requestID)), service: service, model: model)
            XCTAssertTrue(fullCharge ? model.presentation.cancelFullCharge.isEnabled : model.presentation.stopDischarge.isEnabled)
            XCTAssertFalse(model.presentation.startDischarge.isEnabled)
            XCTAssertFalse(model.presentation.startFullCharge.isEnabled)
            XCTAssertNil(model.presentation.effectiveTarget)
            await service.setOutcome(.outcomeUnknown)
            if fullCharge { await model.cancelFullCharge() }
            else { await model.stopDischarge() }
            await service.resumeSend(.rejected(reason: "superseded"))
            await start.value
            XCTAssertTrue(fullCharge ? model.presentation.cancelFullCharge.isEnabled : model.presentation.stopDischarge.isEnabled)
            let finalCommands = await service.commands
            XCTAssertEqual(finalCommands.map(\.intent), fullCharge ? [.startFullCharge, .cancelFullCharge] : [.startDischarge, .stopDischarge])
            await push(ready(enabled: true, generation: model.presentation.generation, revision: 3,
                             status: .accepted(requestID: finalCommands.last!.requestID)), service: service, model: model)
            XCTAssertFalse(model.presentation.cancelFullCharge.isEnabled)
            XCTAssertFalse(model.presentation.stopDischarge.isEnabled)
        }
    }

    private func makeModel(settings: BatteryCareSettings = .default, snapshot: BatteryCareSnapshot = .init(),
                           now: @escaping @Sendable () -> UInt64 = { 101 })
        -> (BatteryCareModel, MemoryBatteryPreferences, ReplyBatteryService, PreferencesController) {
        let store = MemoryBatteryPreferences(settings: settings)
        let preferences = PreferencesController(store: store, launchService: NoopLaunchAtLoginService())
        let service = ReplyBatteryService(snapshot)
        return (BatteryCareModel(preferences: preferences, service: service, now: now), store, service, preferences)
    }

    private func push(_ value: BatteryCareSnapshot, service: ReplyBatteryService, model: BatteryCareModel) async {
        let received = expectation(description: "snapshot \(value.revision)")
        let subscription = model.$presentation.first(where: { $0.revision == value.revision })
            .sink { _ in received.fulfill() }
        await service.push(value)
        let result = await XCTWaiter.fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(result, .completed)
        subscription.cancel()
    }

    private func ready(enabled: Bool = false, limit: Int = 80, generation: UInt64 = 0, revision: UInt64 = 1,
                       status: BatteryCareRequestStatus = .idle, phase: BatteryCareConfirmedPhase = .unknown,
                       readback: BatteryCareReadback = .unknown, mode: BatteryCareTemporaryMode = .none,
                       isCharging: Bool? = false) -> BatteryCareSnapshot {
        .init(settings: try! .init(isEnabled: enabled, limit: limit),
            sample: .init(identity: .init(batteryID: "test", modelIdentifier: "test", osBuild: "test"),
                          presence: .internalBattery, sequence: 1, observedAtUptime: 100,
                          systemPercentage: 82.5, externalPower: true, isCharging: isCharging, lowBatteryProtection: false),
            capabilities: Dictionary(uniqueKeysWithValues: BatteryCareOperation.allCases.map { ($0, .verified(recordID: "test-only")) }),
            authorization: .authorized, requestStatus: status, readback: readback, recoveryStatus: .released,
            safetyLimits: try! .init(sampleIntervalNanoseconds: 1, maxSampleAgeNanoseconds: 20,
                maxCommandAgeNanoseconds: 20, maxReadbackNanoseconds: 20, maxStopNanoseconds: 20,
                leaseNanoseconds: 50, maxTemporaryModeNanoseconds: 100, maxNoProgressNanoseconds: 40),
            generation: generation, revision: revision, confirmedPhase: phase, temporaryMode: mode)
    }
}

private final class BatteryModelClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 101
    func now() -> UInt64 { lock.withLock { value } }
    func set(_ value: UInt64) { lock.withLock { self.value = value } }
}

// One narrow real Session check. Replies describe effects only; no thresholds, admission or lifecycle policy.
private actor RegularReplyBatteryBackend: BatteryCareBackend {
    let context: BatteryCareContext
    var effects: [BatteryCareEffect] = []
    init(context: BatteryCareContext) { self.context = context }
    func observe() -> BatteryCareContext { context }
    func apply(_ effect: BatteryCareEffect) -> BatteryCareExecution {
        effects.append(effect)
        let readback: BatteryCareReadback
        switch effect {
        case .allowCharging: readback = .confirmed(.allowed)
        case .inhibitCharging: readback = .confirmed(.inhibited)
        default: readback = .unknown
        }
        return .init(effect: effect, generation: 0, outcome: .accepted, readback: readback, recoveryStatus: .released)
    }
}

// Used only by MainActor PreferencesController and MainActor test assertions/observers.
private final class MemoryBatteryPreferences: PreferencesStoring, @unchecked Sendable {
    var values: [AppPreferences] = []
    var attempts = 0
    var fails = false
    let initial: AppPreferences
    init(settings: BatteryCareSettings) {
        var initial = AppPreferences.default
        initial.batteryCare = settings
        self.initial = initial
    }
    func load() -> AppPreferences { initial }
    func save(_ value: AppPreferences) throws {
        attempts += 1
        if fails { throw CocoaError(.fileWriteUnknown) }
        values.append(value)
    }
}

// Transport double only: no reducer, thresholds, authorization or policy transitions.
private actor ReplyBatteryService: BatteryCareServicing {
    var commands: [BatteryCareCommand] = []
    var lifecycles: [(BatteryCareLifecycleEvent, UInt64)] = []
    private var value: BatteryCareSnapshot
    private var outcome: BatteryCareReply.Outcome = .accepted
    private var continuation: AsyncStream<BatteryCareSnapshot>.Continuation?
    private var sendObserver: (@MainActor @Sendable (BatteryCareCommand) -> Void)?
    private var held: [CheckedContinuation<BatteryCareReply.Outcome, Never>] = []
    private var entered: XCTestExpectation?
    private var lifecycleResponse: (BatteryCareReply.Outcome, BatteryCareSnapshot)?
    init(_ value: BatteryCareSnapshot) { self.value = value }
    func snapshot() -> BatteryCareSnapshot { value }
    func updates() -> AsyncStream<BatteryCareSnapshot> {
        let (stream, continuation) = AsyncStream<BatteryCareSnapshot>.makeStream()
        self.continuation = continuation
        continuation.yield(value)
        return stream
    }
    func setOutcome(_ outcome: BatteryCareReply.Outcome) { self.outcome = outcome }
    func setLifecycleResponse(_ outcome: BatteryCareReply.Outcome, snapshot: BatteryCareSnapshot) {
        lifecycleResponse = (outcome, snapshot)
    }
    func onSend(_ observer: @escaping @MainActor @Sendable (BatteryCareCommand) -> Void) { sendObserver = observer }
    func holdNextSend(_ expectation: XCTestExpectation) { entered = expectation }
    func resumeSend(_ outcome: BatteryCareReply.Outcome) {
        guard !held.isEmpty else { return }
        held.removeFirst().resume(returning: outcome)
    }
    func send(_ command: BatteryCareCommand) async -> BatteryCareReply {
        commands.append(command)
        let replyRevision = value.revision
        await sendObserver?(command)
        let replyOutcome: BatteryCareReply.Outcome
        if let entered {
            self.entered = nil
            replyOutcome = await withCheckedContinuation { held.append($0); entered.fulfill() }
        } else { replyOutcome = outcome }
        return .init(requestID: command.requestID, generation: command.generation, revision: replyRevision, outcome: replyOutcome)
    }
    func handleLifecycle(_ event: BatteryCareLifecycleEvent, generation: UInt64) -> BatteryCareReply {
        lifecycles.append((event, generation))
        if let lifecycleResponse { push(lifecycleResponse.1) }
        return .init(requestID: UUID(), generation: generation, revision: value.revision,
                     outcome: lifecycleResponse?.0 ?? .outcomeUnknown)
    }
    func push(_ value: BatteryCareSnapshot) { self.value = value; continuation?.yield(value) }
}
