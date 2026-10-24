import Foundation
import XCTest
import MacActivityBatteryControl

@MainActor
final class BatteryCareSessionTests: XCTestCase {
    func testSemanticAdmissionUsesRealPolicyAndKeepsFactsSeparate() async {
        for mutation in 0..<4 {
            let backend = BatteryCareTestBackend()
            var context = BatteryCareTestBackend.context()
            if mutation == 1 { context.authorization = .notAuthorized }
            if mutation == 2 { context.capabilities[.regularLimit] = .unverified }
            if mutation == 3 { context.recoveryStatus = .conflict }
            await backend.configure(context: context)
            let session = BatteryCareSession(backend: backend, now: { 100 })
            let reply = await send(mutation == 0 ? .setLimit(49) : .setManagement(true), to: session)
            guard case .rejected = reply.outcome else { XCTFail("admission must reject"); continue }
            let calls = await backend.recorded()
            XCTAssertFalse(calls.contains(.allowCharging) || calls.contains(.inhibitCharging))
            let snapshot = await session.snapshot()
            XCTAssertFalse(snapshot.settings.isEnabled)
            XCTAssertEqual(snapshot.readback, .unknown)
            XCTAssertEqual(snapshot.physicalObservation, .unknown)
        }
        let (session, backend, _) = await enabled()
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.confirmedPhase, .inhibited)
        XCTAssertEqual(snapshot.physicalObservation, .unknown)
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging])
    }

    func testIdempotencyConflictsAndOldGenerationNeverReplay() async {
        let backend = BatteryCareTestBackend()
        let session = BatteryCareSession(backend: backend, now: { 100 })
        let command = BatteryCareCommand(requestID: UUID(), generation: 1, intent: .setManagement(true))
        let first = await session.send(command)
        let duplicate = await session.send(command)
        XCTAssertEqual(first, duplicate)
        let conflict = await session.send(.init(requestID: command.requestID, generation: 1, intent: .setLimit(60)))
        guard case .rejected = conflict.outcome else { return XCTFail("ID conflict") }
        _ = await send(.setLimit(85), to: session)
        let old = await session.send(command)
        guard case .rejected = old.outcome else { return XCTFail("old generation") }
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging]) // Changing L need not repeat an already confirmed inhibit.
        // A current-generation duplicate can be retained without growing a request history.
        for generation in 3...100 {
            _ = await session.send(.init(requestID: UUID(), generation: UInt64(generation), intent: .setLimit(85)))
        }
        let replay = await session.send(command)
        guard case .rejected = replay.outcome else { return XCTFail("eviction must not permit replay") }
    }

    func testExpiredRiskCommandNeverReachesBackend() async {
        let backend = BatteryCareTestBackend()
        let clock = BatteryCareTestClock()
        let session = BatteryCareSession(backend: backend, now: clock.now)
        let held = expectation(description: "previous observation held")
        await backend.suspendObserve(held)
        let previous = Task { await self.send(.setLimit(85), to: session) }
        await fulfillment(of: [held], timeout: 2)
        let risk = await enqueue(.setManagement(true), session: session)
        clock.set(120) // Fresh sample, but the queued intent itself has reached its age boundary.
        await backend.configure(context: BatteryCareTestBackend.context(time: 120, sequence: 11))
        await backend.resumeObserve()
        _ = await previous.value
        let expired = await risk.value
        XCTAssertEqual(expired.outcome, .rejected(reason: "commandExpired"))
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [])
    }

    func testInFlightDeadlineQueuesReleaseButReplyDoesNotWaitForPhysicalStop() async {
        let (session, backend, clock) = await enabled()
        let held = expectation(description: "apply held")
        await backend.suspendApply(held)
        let first = Task { await self.send(.startDischarge, to: session) }
        await fulfillment(of: [held], timeout: 2)
        let latest = await enqueue(.setLimit(60), session: session)
        clock.set(120)
        await backend.configure(context: BatteryCareTestBackend.context(time: 120, sequence: 11))
        await session.receive(.tick)
        await backend.resumeApply(BatteryCareTestBackend.execution(.startDischarge))
        _ = await first.value
        _ = await latest.value
        let updates = await session.updates()
        for await value in updates where value.recoveryStatus == .released { break }
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging, .startDischarge, .releaseOwnedControls])
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.confirmedPhase, .unknown)
        XCTAssertEqual(snapshot.temporaryMode, .none)
    }

    func testObserveReentrancyRechecksGenerationAndFreshness() async {
        for invalidateGeneration in [false, true] {
            let backend = BatteryCareTestBackend()
            await backend.configure(context: BatteryCareTestBackend.context(sampleAge: 5))
            let clock = BatteryCareTestClock()
            let session = BatteryCareSession(backend: backend, now: clock.now)
            let held = expectation(description: "observe held")
            await backend.suspendObserve(held)
            let enable = Task { await self.send(.setManagement(true), to: session) }
            await fulfillment(of: [held], timeout: 2)
            var stop: Task<BatteryCareReply, Never>?
            if invalidateGeneration { stop = await enqueue(.setManagement(false), session: session) }
            else { clock.set(105) } // Sample expired, command age 5 is still below its independent budget 20.
            await backend.resumeObserve()
            _ = await enable.value
            _ = await stop?.value
            let calls = await backend.recorded()
            XCTAssertFalse(calls.contains(.inhibitCharging) || calls.contains(.allowCharging))
        }
    }

    func testLateCompletionCannotRestartCancelledMode() async {
        let (session, backend, _) = await enabled()
        let held = expectation(description: "start held")
        await backend.suspendApply(held)
        let start = Task { await self.send(.startFullCharge, to: session) }
        await fulfillment(of: [held], timeout: 2)
        let cancel = await enqueue(.cancelFullCharge, session: session)
        let revoked = await session.snapshot()
        XCTAssertEqual(revoked.temporaryMode, .none)
        XCTAssertEqual(revoked.recoveryStatus, .unconfirmed)
        let before = await backend.recorded()
        XCTAssertEqual(before, [.inhibitCharging, .allowCharging])
        await backend.resumeApply(BatteryCareTestBackend.execution(.allowCharging))
        _ = await start.value
        _ = await cancel.value
        let stopped = await session.snapshot()
        XCTAssertEqual(stopped.temporaryMode, .none)
        XCTAssertEqual(stopped.confirmedPhase, .unknown)
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging, .allowCharging, .endTemporaryMode])
    }

    func testStopPriorityAndLatestLimitCoalescingDuringApply() async {
        let (session, backend, _) = await enabled()
        let held = expectation(description: "full held")
        await backend.suspendApply(held)
        let start = Task { await self.send(.startFullCharge, to: session) }
        await fulfillment(of: [held], timeout: 2)
        let limit1 = await enqueue(.setLimit(60), session: session)
        let limit2 = await enqueue(.setLimit(65), session: session)
        let limit3 = await enqueue(.setLimit(70), session: session)
        let sleep = Task { await session.handleLifecycle(.willSleep, generation: 6) }
        let stream = await session.updates()
        for await value in stream where value.generation >= 6 { break }
        let pending = await backend.recorded()
        XCTAssertEqual(pending, [.inhibitCharging, .allowCharging])
        await backend.resumeApply(BatteryCareTestBackend.execution(.allowCharging))
        _ = await start.value; _ = await limit1.value; _ = await limit2.value; _ = await limit3.value; _ = await sleep.value
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging, .allowCharging, .releaseOwnedControls])
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.settings.limit, 70)
        XCTAssertEqual(snapshot.temporaryMode, .none)
    }

    func testTimeoutIsUnknownAndBlocksNewRiskWrites() async {
        let (session, backend, clock) = await enabled()
        let held = expectation(description: "start held")
        await backend.suspendApply(held)
        let start = Task { await self.send(.startDischarge, to: session) }
        await fulfillment(of: [held], timeout: 2)
        clock.set(120)
        await session.receive(.tick)
        let timedOut = await start.value
        XCTAssertEqual(timedOut.outcome, .outcomeUnknown)
        let retry = await enqueue(.retryRegular, session: session)
        let callsBefore = await backend.recorded()
        XCTAssertEqual(callsBefore, [.inhibitCharging, .startDischarge])
        await backend.respond(to: .releaseOwnedControls, with: BatteryCareTestBackend.execution(.releaseOwnedControls, recovery: .conflict))
        await backend.resumeApply(BatteryCareTestBackend.execution(.startDischarge))
        _ = await retry.value
        let updates = await session.updates()
        for await value in updates where value.recoveryStatus == .conflict { break }
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.temporaryMode, .none)
        XCTAssertEqual(snapshot.recoveryStatus, .conflict)
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging, .startDischarge, .releaseOwnedControls])
    }

    func testPartialAndContradictedResponsesAreUnknownAndRequireRelease() async {
        for receipt in [BatteryCareTestBackend.execution(.inhibitCharging, outcome: .outcomeUnknown),
                        BatteryCareTestBackend.execution(.inhibitCharging, readback: .contradicted)] {
            let backend = BatteryCareTestBackend()
            await backend.respond(to: .inhibitCharging, with: receipt)
            await backend.respond(to: .releaseOwnedControls, with: BatteryCareTestBackend.execution(.releaseOwnedControls, recovery: .unknown))
            let session = BatteryCareSession(backend: backend, now: { 100 })
            let reply = await send(.setManagement(true), to: session)
            XCTAssertEqual(reply.outcome, .outcomeUnknown)
            let value = await session.snapshot()
            XCTAssertEqual(value.confirmedPhase, .unknown)
            XCTAssertNotEqual(value.recoveryStatus, .released)
            let calls = await backend.recorded()
            XCTAssertEqual(calls, [.inhibitCharging, .releaseOwnedControls])
        }
    }

    func testIndependentTickExpiresSampleAndLeaseWithoutDisplayActivity() async {
        for expireSample in [false, true] {
            let (session, backend, clock) = await enabled(sampleAge: expireSample ? 50 : 1000, lease: 60)
            _ = await send(.startDischarge, to: session)
            let held = expectation(description: "release held")
            await backend.suspendApply(held)
            clock.set(expireSample ? 150 : 160)
            await session.receive(.tick)
            await fulfillment(of: [held], timeout: 2)
            let pending = await session.snapshot()
            XCTAssertEqual(pending.temporaryMode, .none)
            XCTAssertEqual(pending.recoveryStatus, .unconfirmed)
            await backend.resumeApply(BatteryCareTestBackend.execution(.releaseOwnedControls))
            let stream = await session.updates()
            for await value in stream where value.recoveryStatus == .released { break }
        }
    }

    func testConnectionLossAndNewSessionNeverReplayTemporaryIntent() async {
        let (session, backend, clock) = await enabled()
        _ = await send(.startDischarge, to: session)
        let oldGeneration = await session.snapshot().generation
        _ = await session.handleLifecycle(.connectionLost, generation: oldGeneration + 1)
        clock.set(101)
        await backend.configure(context: BatteryCareTestBackend.context(time: 101, sequence: 11))
        await session.receive(.sampleChanged)
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.temporaryMode, .none)
        let replay = await session.send(.init(requestID: UUID(), generation: oldGeneration, intent: .startDischarge))
        guard case .rejected = replay.outcome else { return XCTFail("replay") }
        let fresh = BatteryCareSession(backend: backend, now: clock.now)
        let initial = await fresh.snapshot()
        XCTAssertFalse(initial.settings.isEnabled)
        XCTAssertEqual(initial.temporaryMode, .none)
    }

    func testBackwardClockAndOverflowSafeAgeRejectRiskButKeepStop() async {
        for time in [UInt64(99), UInt64.max] {
            let (session, backend, clock) = await enabled()
            let held = expectation(description: "observe held")
            await backend.suspendObserve(held)
            let risk = Task { await self.send(.startDischarge, to: session) }
            await fulfillment(of: [held], timeout: 2)
            clock.set(time)
            await backend.resumeObserve()
            _ = await risk.value
            _ = await send(.setManagement(false), to: session)
            let calls = await backend.recorded()
            XCTAssertFalse(calls.contains(.startDischarge))
            XCTAssertTrue(calls.contains(.releaseOwnedControls))
        }
    }

    func testUpdatesPublishInitialPendingAndConfirmedSnapshotsWithIncreasingRevision() async {
        let backend = BatteryCareTestBackend()
        let session = BatteryCareSession(backend: backend, now: { 100 })
        let stream = await session.updates()
        var iterator = stream.makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.revision, 0)
        let held = expectation(description: "write held")
        await backend.suspendApply(held)
        let task = Task { await self.send(.setManagement(true), to: session) }
        await fulfillment(of: [held], timeout: 2)
        let pending = await iterator.next()
        guard case .pending = pending?.requestStatus else { return XCTFail("pending status") }
        XCTAssertEqual(pending?.confirmedPhase, .unknown)
        await backend.resumeApply(BatteryCareTestBackend.execution(.inhibitCharging))
        _ = await task.value
        let final = await iterator.next()
        XCTAssertEqual(final?.confirmedPhase, .inhibited)
        XCTAssertGreaterThan(final?.revision ?? 0, pending?.revision ?? 0)
    }

    func testPendingDuplicateDoesNotAddAWriterOrWaiter() async {
        let backend = BatteryCareTestBackend()
        let session = BatteryCareSession(backend: backend, now: { 100 })
        let held = expectation(description: "write held")
        await backend.suspendApply(held)
        let command = BatteryCareCommand(requestID: UUID(), generation: 1, intent: .setManagement(true))
        let task = Task { await session.send(command) }
        await fulfillment(of: [held], timeout: 2)
        let duplicate = await session.send(command)
        XCTAssertEqual(duplicate.outcome, .accepted) // Intent admission only; snapshot remains pending.
        let pending = await session.snapshot()
        XCTAssertEqual(pending.requestStatus, .pending(requestID: command.requestID))
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging])
        await backend.resumeApply(BatteryCareTestBackend.execution(.inhibitCharging))
        _ = await task.value
    }

    func testDuplicateDuringInitialObserveCannotClaimAuthorizationAdmission() async {
        let backend = BatteryCareTestBackend()
        var denied = BatteryCareTestBackend.context()
        denied.authorization = .notAuthorized
        await backend.configure(context: denied)
        let session = BatteryCareSession(backend: backend, now: { 100 })
        let held = expectation(description: "admission observe held")
        await backend.suspendObserve(held)
        let command = BatteryCareCommand(requestID: UUID(), generation: 1, intent: .setManagement(true))
        let original = Task { await session.send(command) }
        await fulfillment(of: [held], timeout: 2)
        let duplicate = await session.send(command)
        XCTAssertEqual(duplicate.outcome, .rejected(reason: "requestPending"))
        await backend.resumeObserve()
        let rejected = await original.value
        guard case .rejected = rejected.outcome else { return XCTFail("unauthorized admission") }
    }

    func testUnconfirmedReleaseCannotBeClearedByObserveOrNewLimit() async {
        let (session, backend, _) = await enabled()
        _ = await send(.startDischarge, to: session)
        await backend.respond(to: .endTemporaryMode, with: BatteryCareTestBackend.execution(.endTemporaryMode, recovery: .unknown))
        await backend.respond(to: .releaseOwnedControls, with: BatteryCareTestBackend.execution(.releaseOwnedControls, recovery: .unknown))
        let stop = await send(.stopDischarge, to: session)
        XCTAssertEqual(stop.outcome, .outcomeUnknown)
        let before = await backend.recorded()
        _ = await send(.setLimit(60), to: session)
        _ = await send(.startDischarge, to: session)
        let after = await backend.recorded()
        XCTAssertEqual(after, before)
        let snapshot = await session.snapshot()
        XCTAssertNotEqual(snapshot.recoveryStatus, .released)
        XCTAssertEqual(snapshot.temporaryMode, .none)
    }

    func testSafetyWriteRechecksAuthorizationAfterObserveAwait() async {
        let (session, backend, _) = await enabled()
        let held = expectation(description: "release observe held")
        await backend.suspendObserve(held)
        let stop = Task { await self.send(.setManagement(false), to: session) }
        await fulfillment(of: [held], timeout: 2)
        var denied = BatteryCareTestBackend.context()
        denied.authorization = .notAuthorized
        await backend.configure(context: denied)
        await backend.resumeObserve()
        let reply = await stop.value
        XCTAssertEqual(reply.outcome, .outcomeUnknown)
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging])
        let value = await session.snapshot()
        XCTAssertEqual(value.recoveryStatus, .unconfirmed)
    }

    func testAutomaticSampleEffectHasItsOwnQueueAgeNotTheLastUICommandAge() async {
        let (session, backend, clock) = await enabled()
        clock.set(125) // Last UI command is older than maxCommandAge, but the lease is still valid.
        await backend.configure(context: BatteryCareTestBackend.context(time: 125, sequence: 11, percentage: 75))
        let stream = await session.updates()
        await session.receive(.sampleChanged)
        for await value in stream where value.confirmedPhase == .allowed || value.requiresRetry { break }
        let value = await session.snapshot()
        XCTAssertEqual(value.confirmedPhase, .allowed)
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging, .allowCharging])
    }

    func testPendingStopDoesNotFalselyAcceptEnableOrTemporaryStart() async {
        let (session, backend, _) = await enabled()
        _ = await send(.startFullCharge, to: session)
        let held = expectation(description: "stop held")
        await backend.suspendApply(held)
        let cancel = Task { await self.send(.cancelFullCharge, to: session) }
        await fulfillment(of: [held], timeout: 2)
        var attempts: [Task<BatteryCareReply, Never>] = []
        for intent in [BatteryCareIntent.startFullCharge, .startDischarge, .setManagement(true)] {
            attempts.append(await enqueue(intent, session: session))
        }
        await backend.resumeApply(BatteryCareTestBackend.execution(.endTemporaryMode))
        _ = await cancel.value
        for attempt in attempts {
            let response = await attempt.value
            guard case .rejected = response.outcome else { XCTFail("stop pending must block risk admission"); continue }
        }
    }

    func testSampleSignalDuringObserveCannotBeOverwrittenByOlderFreshObservation() async {
        let (session, backend, clock) = await enabled()
        let held = expectation(description: "risk observation held")
        await backend.suspendObserve(held)
        let risk = Task { await self.send(.startDischarge, to: session) }
        await fulfillment(of: [held], timeout: 2)
        clock.set(101)
        await backend.configure(context: BatteryCareTestBackend.context(time: 101, sequence: 11, percentage: 10))
        await session.receive(.sampleChanged)
        let releaseObserved = expectation(description: "release pre-write observation held")
        // Skip the replacement admission observe, then hold the queued release before it can apply.
        await backend.suspendObserve(releaseObserved, after: 1)
        await backend.resumeObserve(returning: BatteryCareTestBackend.context())
        await fulfillment(of: [releaseObserved], timeout: 2)
        let pending = await session.snapshot()
        XCTAssertEqual(pending.sample?.sequence, 11)
        XCTAssertEqual(pending.sample?.systemPercentage, 10)
        XCTAssertEqual(pending.recoveryStatus, .unconfirmed)
        XCTAssertEqual(pending.temporaryMode, .none)
        XCTAssertTrue(pending.requiresRetry)
        let beforeRelease = await backend.recorded()
        XCTAssertEqual(beforeRelease, [.inhibitCharging], "No risk apply while release observation is suspended")
        let updates = await session.updates()
        await backend.resumeObserve()
        // Rejection finishes the waiter before drain completes the separately queued safety release.
        for await value in updates where value.recoveryStatus == .released { break }
        let rejected = await risk.value
        XCTAssertEqual(rejected.outcome, .rejected(reason: "admissionUnavailable"))
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging, .releaseOwnedControls])
        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.sample?.sequence, 11)
        XCTAssertEqual(snapshot.sample?.systemPercentage, 10)
        XCTAssertEqual(snapshot.temporaryMode, .none)
        XCTAssertTrue(snapshot.requiresRetry)
    }

    func testOfflineEnableStillRequiresAuthorizationCapabilitiesAndSafetyLimits() async {
        for missing in 0..<4 {
            let backend = BatteryCareTestBackend()
            var context = BatteryCareTestBackend.context(externalPower: false)
            if missing == 0 { context.authorization = .notAuthorized }
            if missing == 1 { context.capabilities[.regularLimit] = .unverified }
            if missing == 2 { context.safetyLimits = nil }
            if missing == 3 { context.capabilities[.releaseOwnedControls] = .unverified }
            await backend.configure(context: context)
            let session = BatteryCareSession(backend: backend, now: { 100 })
            let response = await send(.setManagement(true), to: session)
            guard case .rejected = response.outcome else { XCTFail("enable lacks admission"); continue }
            let value = await session.snapshot()
            XCTAssertFalse(value.settings.isEnabled)
            let calls = await backend.recorded()
            XCTAssertEqual(calls, [])
        }
    }

    func testDisabledOfflineLimitIsAcceptedWithoutGrantingManagementOrWrites() async {
        let backend = BatteryCareTestBackend()
        await backend.configure(context: .init(nowUptime: 100))
        let session = BatteryCareSession(backend: backend, now: { 100 })
        let reply = await send(.setLimit(60), to: session)
        XCTAssertEqual(reply.outcome, .accepted)
        let value = await session.snapshot()
        XCTAssertEqual(value.settings.limit, 60)
        XCTAssertFalse(value.settings.isEnabled)
        XCTAssertEqual(value.recoveryStatus, .unknown)
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [])
    }

    func testQueuedRegularWriteIsReevaluatedAgainstLatestPercentageBeforeApply() async {
        for (initial, queued, latest, phase, onlyEffect) in [
            (90.0, 75.0, 90.0, BatteryCareConfirmedPhase.inhibited, BatteryCareEffect.inhibitCharging),
            (70.0, 80.0, 70.0, .allowed, .allowCharging)
        ] {
            let (session, backend, clock) = await enabled(percentage: initial)
            let held = expectation(description: "queued regular pre-write observe")
            await backend.suspendObserve(held, after: 1) // Refresh queues the effect; hold its pre-write observation.
            clock.set(101)
            await backend.configure(context: BatteryCareTestBackend.context(time: 101, sequence: 11, percentage: queued))
            await session.receive(.sampleChanged)
            await fulfillment(of: [held], timeout: 2)
            clock.set(102)
            await backend.configure(context: BatteryCareTestBackend.context(time: 102, sequence: 12, percentage: latest))
            let stream = await session.updates()
            await backend.resumeObserve()
            for await value in stream where value.sample?.sequence == 12 && value.confirmedPhase != .unknown { break }
            let value = await session.snapshot()
            XCTAssertEqual(value.confirmedPhase, phase)
            let calls = await backend.recorded()
            XCTAssertEqual(calls, [onlyEffect], "No stale queued regular write may reach apply")
        }
    }

    func testSupersededEnableReplyAgreesWithRetainedSettingsAndEffects() async {
        let backend = BatteryCareTestBackend()
        let session = BatteryCareSession(backend: backend, now: { 100 })
        _ = await send(.setLimit(80), to: session) // Seed cached observations, not an enable grant.
        let held = expectation(description: "enable pre-write observe")
        await backend.suspendObserve(held)
        let enable = Task { await self.send(.setManagement(true), to: session) }
        await fulfillment(of: [held], timeout: 2)
        let sameLimit = await enqueue(.setLimit(80), session: session)
        let response = await enable.value
        await backend.resumeObserve()
        _ = await sameLimit.value
        let value = await session.snapshot()
        let calls = await backend.recorded()
        if case .rejected = response.outcome {
            XCTAssertFalse(value.settings.isEnabled, "Rejected enable cannot leave a retained enable grant")
            XCTAssertEqual(calls, [], "Rejected enable cannot silently initiate control")
        } else {
            XCTAssertEqual(response.outcome, .accepted, "Before apply, supersession can report admitted intent, not physical success")
            XCTAssertTrue(value.settings.isEnabled)
            XCTAssertEqual(calls, [.inhibitCharging])
        }
    }

    func testEnableWaitsForCurrentObservationAndRejectsLostOfflineAdmission() async {
        for missing in 0..<6 {
            let backend = BatteryCareTestBackend()
            await backend.configure(context: BatteryCareTestBackend.context(externalPower: false))
            let session = BatteryCareSession(backend: backend, now: { 100 })
            _ = await send(.setLimit(80), to: session)
            let held = expectation(description: "offline refresh held")
            await backend.suspendObserve(held)
            await session.receive(.sampleChanged)
            await fulfillment(of: [held], timeout: 2)
            var lost = BatteryCareTestBackend.context(externalPower: false)
            switch missing {
            case 0: lost.authorization = .notAuthorized
            case 1: lost.capabilities[.regularLimit] = .unverified
            case 2: lost.capabilities[.releaseOwnedControls] = .unverified
            case 3: lost.recoveryStatus = .unknown
            case 4: lost.recoveryStatus = .conflict
            default: lost.safetyLimits = nil
            }
            await backend.configure(context: lost)
            let enable = await enqueue(.setManagement(true), session: session)
            let pending = await session.snapshot()
            XCTAssertFalse(pending.settings.isEnabled, "Cached offline admission is not this generation's admission")
            await backend.resumeObserve()
            let response = await enable.value
            guard case .rejected = response.outcome else { XCTFail("Current offline admission must reject \(missing)"); continue }
            let value = await session.snapshot()
            XCTAssertFalse(value.settings.isEnabled)
            let calls = await backend.recorded()
            if missing == 4 {
                XCTAssertTrue(calls.allSatisfy { $0 == .releaseOwnedControls }) // Preserve Policy's conflict cleanup.
            } else {
                XCTAssertEqual(calls, [])
            }
        }
    }

    func testQueuedNewLimitKeepsItsThresholdRebuildWhenLatestSampleIsInBand() async {
        let (session, backend, clock) = await enabled()
        clock.set(101)
        await backend.configure(context: BatteryCareTestBackend.context(time: 101, sequence: 11, percentage: 85))
        let refreshed = await session.updates()
        await session.receive(.sampleChanged)
        for await value in refreshed where value.sample?.sequence == 11 { break }
        let held = expectation(description: "new-L allow pre-write observe")
        await backend.suspendObserve(held)
        let limit = Task { await self.send(.setLimit(90), to: session) }
        await fulfillment(of: [held], timeout: 2)
        clock.set(102)
        await backend.configure(context: BatteryCareTestBackend.context(time: 102, sequence: 12, percentage: 87))
        await backend.resumeObserve()
        let response = await limit.value
        XCTAssertEqual(response.outcome, .accepted)
        let value = await session.snapshot()
        XCTAssertEqual(value.settings.limit, 90)
        XCTAssertEqual(value.confirmedPhase, .allowed) // New L uses p<L, not the old inhibited L−5 band.
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging, .allowCharging])
    }

    func testSupersededAdmittedEnableReturnsAcceptedBeforeItsQueuedWrite() async {
        for (latest, wanted) in [(90.0, BatteryCareEffect.inhibitCharging), (70.0, .allowCharging)] {
            let backend = BatteryCareTestBackend()
            let clock = BatteryCareTestClock()
            let session = BatteryCareSession(backend: backend, now: clock.now)
            _ = await send(.setLimit(80), to: session)
            let held = expectation(description: "admitted enable pre-write observe")
            await backend.suspendObserve(held, after: 1) // Let this generation's admission observation complete.
            let enable = Task { await self.send(.setManagement(true), to: session) }
            await fulfillment(of: [held], timeout: 2)
            let admitted = await session.snapshot()
            XCTAssertTrue(admitted.settings.isEnabled)
            let limit = await enqueue(.setLimit(80), session: session)
            let accepted = await enable.value
            XCTAssertEqual(accepted.outcome, .accepted)
            clock.set(101)
            await backend.configure(context: BatteryCareTestBackend.context(time: 101, sequence: 11, percentage: latest))
            await backend.resumeObserve()
            _ = await limit.value
            let value = await session.snapshot()
            XCTAssertTrue(value.settings.isEnabled)
            let calls = await backend.recorded()
            XCTAssertEqual(calls, [wanted]) // Unknown prior phase may require replacing, not merely dropping, a queued effect.
        }
    }

    func testActualRegularApplyRetainsSingleWriterAndReleaseResponsibility() async {
        let (session, backend, clock) = await enabled()
        let held = expectation(description: "actual regular allow held")
        await backend.suspendApply(held)
        clock.set(101)
        await backend.configure(context: BatteryCareTestBackend.context(time: 101, sequence: 11, percentage: 75))
        await session.receive(.sampleChanged)
        await fulfillment(of: [held], timeout: 2)
        let stop = await enqueue(.setManagement(false), session: session)
        let pending = await session.snapshot()
        XCTAssertFalse(pending.settings.isEnabled)
        XCTAssertEqual(pending.confirmedPhase, .unknown)
        XCTAssertEqual(pending.recoveryStatus, .unconfirmed)
        let before = await backend.recorded()
        XCTAssertEqual(before, [.inhibitCharging, .allowCharging])
        await backend.resumeApply(BatteryCareTestBackend.execution(.allowCharging))
        _ = await stop.value
        let calls = await backend.recorded()
        XCTAssertEqual(calls, [.inhibitCharging, .allowCharging, .releaseOwnedControls])
        let value = await session.snapshot()
        XCTAssertEqual(value.confirmedPhase, .unknown)
        XCTAssertEqual(value.recoveryStatus, .released)
    }

    private func enabled(sampleAge: UInt64 = 50, lease: UInt64 = 100, percentage: Double = 90) async
        -> (BatteryCareSession, BatteryCareTestBackend, BatteryCareTestClock) {
        let backend = BatteryCareTestBackend()
        await backend.configure(context: BatteryCareTestBackend.context(percentage: percentage, sampleAge: sampleAge, lease: lease))
        let clock = BatteryCareTestClock()
        let session = BatteryCareSession(backend: backend, now: clock.now)
        let reply = await send(.setManagement(true), to: session)
        XCTAssertEqual(reply.outcome, .accepted)
        return (session, backend, clock)
    }

    private func send(_ intent: BatteryCareIntent, to session: BatteryCareSession) async -> BatteryCareReply {
        let generation = await session.snapshot().generation + 1
        return await session.send(.init(requestID: UUID(), generation: generation, intent: intent))
    }

    private func enqueue(_ intent: BatteryCareIntent, session: BatteryCareSession) async -> Task<BatteryCareReply, Never> {
        let generation = await session.snapshot().generation + 1
        let stream = await session.updates()
        let task = Task { await session.send(.init(requestID: UUID(), generation: generation, intent: intent)) }
        for await value in stream where value.generation >= generation { break }
        return task
    }
}
