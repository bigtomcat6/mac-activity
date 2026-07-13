import CoreAudio
import Combine
import MacActivityCore
import XCTest

@testable import MacActivityApp

@MainActor
final class AudioControlCoordinatorTests: XCTestCase {
    func testDefaultBrowsingStateStartsEmptyWithoutProcessTapState() {
        let snapshot: AudioControlSnapshot = .empty

        XCTAssertEqual(snapshot.devices, [])
        XCTAssertEqual(snapshot.processes, [])
    }

    func testUnsupportedStartupShowsDevicesWithoutEnumeratingProcessesOrApplying() async {
        let fixture = CoordinatorFixture(availability: .unsupported)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.devices.map(\.id), ["BuiltIn"])
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertEqual(fixture.engine.applyCount, 0)
    }

    func testSupportedStartupCleansOrphansAndStartsMonitoring() async {
        let fixture = CoordinatorFixture(availability: .supported)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.engine.cleanupCount, 1)
        XCTAssertEqual(fixture.monitor.startCount, 1)
        XCTAssertEqual(fixture.monitor.observedDeviceIDs, [10])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [11])
    }

    func testSupportedDefaultBrowsingDoesNotApplyOrAttemptAuthorization() async {
        let fixture = CoordinatorFixture(availability: .supported)

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.engine.applyCount, 0)
        XCTAssertEqual(fixture.engine.authorizationAttemptCount, 0)
    }

    func testRapidDeviceSliderIntentsCoalesceAndRollbackWithoutProcessEnumeration() async {
        let delay = ControlledAudioDelay()
        let fixture = CoordinatorFixture(
            availability: .supported,
            delay: delay.callAsFunction
        )
        await fixture.coordinator.start()
        fixture.deviceProvider.volumeWriteError = FixtureError.writeFailed

        fixture.coordinator.setDeviceVolume(0.6, for: "BuiltIn")
        fixture.coordinator.setDeviceVolume(0.7, for: "BuiltIn")
        fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.8)

        for _ in 0..<12 { await Task.yield() }
        let delayCallCount = await delay.callCount
        XCTAssertEqual(delayCallCount, 1)
        await delay.resumeAll()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.deviceProvider.volumeWrites, [0.8])
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.5)
        XCTAssertEqual(fixture.processProvider.callCount, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].error, .deviceWrite)
    }

    func testBundlelessProcessIntentIsSessionOnly() async {
        let fixture = CoordinatorFixture(
            availability: .supported,
            bundleIdentifier: nil
        )
        await fixture.coordinator.start()

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.count, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.store.saveCount, 0)
    }

    func testExplicitRouteUsesExactlySelectedTargetsWithoutDefaultInjection() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB"]),
            for: 11
        )
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["USB"])
        XCTAssertFalse(fixture.engine.plans.last?.selectedTargetUIDs.contains("BuiltIn") ?? true)
    }

    func testSavedNonDefaultProfileRestoresButSavedDefaultDoesNotApply() async {
        let saved = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.35
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [saved.bundleIdentifier: saved]
        )

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.count, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.35)

        let defaultProfile = AudioProcessProfile(bundleIdentifier: "com.example.music")
        let defaultFixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [defaultProfile.bundleIdentifier: defaultProfile]
        )
        await defaultFixture.coordinator.start()
        await defaultFixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(defaultFixture.engine.plans.count, 0)
    }

    func testPermissionFailureRetainsPendingRequestAndRetrySucceeds() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.engine.nextError = .permissionDenied(-1)

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .permissionDenied)

        fixture.engine.nextError = nil
        fixture.coordinator.retry(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
    }

    func testResetStopsNonDefaultSessionWithoutApplyingDefaultProfile() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.engine.plans.count, 1)

        fixture.coordinator.reset(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans.count, 1)
        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 1)
        XCTAssertNil(fixture.store.savedPreferences.audioProcessProfiles["com.example.music"])
    }

    func testPersistenceFailureStopsNewSessionAndRollsBackVisibleState() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.store.saveError = FixtureError.writeFailed

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .persistenceFailed)
    }

    func testPersistenceFailureRestoresPreviousNonDefaultEngineRuleWithoutRepersistingIt() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.store.saveFailuresRemaining = 2

        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.gains.map(\.volume), [0.4, 0.6, 0.4])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.volume, 0.6)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .persistenceFailed)
    }

    func testSamePIDNewObjectStopsOldSessionAndPublishesNewIdentity() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.processProvider.processes = [.music(objectID: 22)]

        await fixture.emit([.processList])

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [22])
    }

    func testExactObjectRefreshPreservesSessionPendingValuesAndError() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.engine.nextError = .unsupportedFormat
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let before = fixture.coordinator.snapshot.processes[0]

        await fixture.emit([.processList])

        let after = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(after.session, before.session)
        XCTAssertEqual(after.pendingValues, before.pendingValues)
        XCTAssertEqual(after.error, before.error)
    }

    func testEveryDisappearingProcessObjectIsStoppedFailClosed() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.processProvider.processes = []

        await fixture.emit([.processList])

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
    }

    func testDisappearingObjectRetiresBeforeStopAndReuseStartsAfterTombstone() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        await fixture.engine.blockApplyReturn(1)
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.engine.waitUntilApplyReturnCount(1)
        await fixture.engine.blockStops()
        fixture.processProvider.processes = []
        let token = fixture.monitor.emit([.processList])
        await fixture.engine.waitUntilStopCount(1)

        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        fixture.coordinator.setProcessVolume(0.8, for: 11)
        await fixture.engine.resumeApplyReturns()
        await fixture.engine.resumeStops()
        await fixture.coordinator.testingWaitForReconciliation(token: token)
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.engine.applyCount, 1)
        XCTAssertNil(fixture.store.savedPreferences.audioProcessProfiles["com.example.music"])

        fixture.processProvider.processes = [.music(objectID: 11)]
        await fixture.emit([.processList])
        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.applyCount, 2)
        XCTAssertGreaterThan(
            fixture.engine.plans.last!.generation,
            fixture.engine.stoppedGenerations.last!
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.6)
    }

    func testReplacementObjectRestoresSavedBundleProfile() async {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.35
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile]
        )
        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.processProvider.processes = [.music(objectID: 22)]

        await fixture.emit([.processList])

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(fixture.engine.plans.last?.processObjectID, 22)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.35)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
    }

    func testEngineSnapshotsUseStrictLexicographicOrderAndIgnoreDuplicates() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        let newest = ProcessTapSessionSnapshot(
            processObjectID: 11,
            generation: 2,
            state: .running,
            error: nil,
            commandSequence: 2,
            emissionOrdinal: 2
        )
        await fixture.emitEngine(newest)
        await fixture.emitEngine(.init(
            processObjectID: 11,
            generation: 1,
            state: .failed,
            error: .unsupportedFormat,
            commandSequence: 1,
            emissionOrdinal: 9
        ))
        await fixture.emitEngine(.init(
            processObjectID: 11,
            generation: 2,
            state: .failed,
            error: .unsupportedFormat,
            commandSequence: 2,
            emissionOrdinal: 1
        ))
        await fixture.emitEngine(newest)

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, newest)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
    }

    func testEngineSnapshotAckWaitsForExactSnapshotOrder() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        let unrelated = ProcessTapSessionSnapshot(
            processObjectID: 11,
            generation: 1,
            state: .preparing,
            error: nil,
            commandSequence: 10,
            emissionOrdinal: 0
        )
        let target = ProcessTapSessionSnapshot(
            processObjectID: 11,
            generation: 1,
            state: .running,
            error: nil,
            commandSequence: 20,
            emissionOrdinal: 0
        )
        var acknowledged = false
        let started = expectation(description: "exact snapshot waiter started")
        let waiter = Task { @MainActor in
            started.fulfill()
            await fixture.coordinator.testingWaitForEngineSnapshot(
                processObjectID: target.processObjectID,
                order: target.order
            )
            acknowledged = true
        }
        await fulfillment(of: [started], timeout: 1)

        await fixture.emitEngine(unrelated)
        XCTAssertFalse(acknowledged)
        await fixture.emitEngine(target)
        await waiter.value
        XCTAssertTrue(acknowledged)
    }

    func testReconciliationAckWaitsForTargetTokenBehindQueuedEvent() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        _ = fixture.monitor.emit([.defaultOutputDevice])
        fixture.processProvider.processes = []
        await fixture.engine.blockStops()
        let targetToken = fixture.monitor.emit([.processList])
        await fixture.engine.waitUntilStopCount(1)
        var acknowledged = false
        let started = expectation(description: "target token waiter started")
        let waiter = Task { @MainActor in
            started.fulfill()
            await fixture.coordinator.testingWaitForReconciliation(token: targetToken)
            acknowledged = true
        }
        await fulfillment(of: [started], timeout: 1)

        XCTAssertFalse(acknowledged)
        await fixture.engine.resumeStops()
        await waiter.value
        XCTAssertTrue(acknowledged)
    }

    func testHigherOrderSnapshotFromLowerGenerationIsRejected() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let accepted = fixture.coordinator.snapshot.processes[0].session

        await fixture.emitEngine(.init(
            processObjectID: 11,
            generation: 0,
            state: .failed,
            error: .unsupportedFormat,
            commandSequence: accepted.commandSequence + 100,
            emissionOrdinal: 0
        ))

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, accepted)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
    }

    func testObserverSnapshotIsAcceptedBeforeAsyncCommandReturns() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        await fixture.engine.blockApplyReturn(1)

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.engine.waitUntilApplyReturnCount(1)
        let emitted = fixture.engine.lastProducedSnapshot!
        await fixture.coordinator.testingWaitForEngineSnapshot(
            processObjectID: emitted.processObjectID,
            order: emitted.order
        )

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        await fixture.engine.resumeApplyReturns()
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
    }

    func testAsyncCommandReturnIsAcceptedBeforeDuplicateObserverSnapshot() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.engine.deferApplyObserver(1)

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let accepted = fixture.coordinator.snapshot.processes[0].session
        fixture.engine.deliverDeferredObservers()
        await fixture.coordinator.testingWaitForEngineSnapshot(
            processObjectID: accepted.processObjectID,
            order: accepted.order
        )

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session, accepted)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
    }

    func testResetCommitsOnlyAfterAcceptedIdleStop() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let stopError = ProcessTapEngineError.operationFailed(operation: .stopDevice, status: -1)
        fixture.engine.scriptedStopResults = [(.failed, stopError)]

        fixture.coordinator.reset(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues, .default)
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .operationFailed(stopError)
        )
    }

    func testCanceledResetCannotOverwriteNewerRunningIntent() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        await fixture.engine.blockStops()

        fixture.coordinator.reset(processObjectID: 11)
        await fixture.engine.waitUntilStopCount(1)
        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitForProcessTask(11)
        await fixture.engine.resumeStops()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.6)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
    }

    func testFailedPreviousRuleRollbackStopsAndProvesIdle() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.store.saveFailuresRemaining = 1
        fixture.engine.scriptedApplyResults = [
            (.running, nil),
            (.failed, .unsupportedFormat),
        ]

        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs.last, 11)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .idle)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.4)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.volume, 0.6)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .persistenceFailed)
    }

    func testSupersededPersistenceRollbackCannotOverwriteNewerRule() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.store.saveFailuresRemaining = 1
        await fixture.engine.blockApplyCall(3)

        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.engine.waitUntilApplyCount(3)
        fixture.coordinator.setProcessVolume(0.7, for: 11)
        await fixture.coordinator.testingWaitForProcessTask(11)
        await fixture.engine.resumeApplies()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].volume, 0.7)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].pendingValues)
        XCTAssertNil(fixture.coordinator.snapshot.processes[0].error)
    }

    func testShutdownStopsMonitorBeforeAwaitedStopAll() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        await fixture.coordinator.shutdown()

        XCTAssertEqual(fixture.lifecycle.events.suffix(2), ["monitor.stop", "engine.stopAll"])
    }

    func testExplicitTargetDisconnectRebuildsWithRemainingTargetsWithoutRewritingSelection() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["BuiltIn", "USB"]),
            for: 11
        )
        await fixture.coordinator.testingWaitUntilIdle()

        fixture.deviceProvider.setAlive(false, uid: "USB")
        await fixture.emit([.device(20, .liveness)])

        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["BuiltIn"])
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].route,
            .explicit(targetDeviceUIDs: ["BuiltIn", "USB"])
        )

        fixture.deviceProvider.setAlive(true, uid: "USB")
        await fixture.emit([.device(20, .liveness)])
        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["BuiltIn", "USB"])
    }

    func testUnavailableSavedExplicitRouteDoesNotApplyOrInjectDefaultAndRetriesOnReconnect() async {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.5,
            route: .explicit(targetDeviceUIDs: ["USB"])
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile]
        )
        fixture.deviceProvider.setAlive(false, uid: "USB")

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.engine.plans, [])
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .targetUnavailable(["USB"]))
        XCTAssertEqual(
            fixture.store.savedPreferences.audioProcessProfiles[profile.bundleIdentifier]?.route,
            .explicit(targetDeviceUIDs: ["USB"])
        )

        fixture.deviceProvider.setAlive(true, uid: "USB")
        await fixture.emit([.device(20, .liveness)])
        XCTAssertEqual(fixture.engine.plans.last?.selectedTargetUIDs, ["USB"])
    }

    func testSavedMissingRouteImmediatelyBuildsSelectedUnavailableOption() async {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.5,
            route: .explicit(targetDeviceUIDs: ["Missing"])
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile]
        )

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].routeOptions.first(where: {
                $0.uid == "Missing"
            }),
            AudioRouteDeviceOption(
                uid: "Missing",
                name: "Missing",
                isAvailable: false,
                isSelected: true
            )
        )
    }

    func testUserRouteIntentImmediatelyRebuildsAvailableAndMissingSelections() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        fixture.coordinator.setProcessRoute(
            .explicit(targetDeviceUIDs: ["USB", "Missing"]),
            for: 11
        )

        let options = fixture.coordinator.snapshot.processes[0].routeOptions
        XCTAssertEqual(options.first(where: { $0.uid == "USB" })?.isSelected, true)
        XCTAssertEqual(
            options.first(where: { $0.uid == "Missing" }),
            AudioRouteDeviceOption(
                uid: "Missing",
                name: "Missing",
                isAvailable: false,
                isSelected: true
            )
        )
        await fixture.coordinator.testingWaitUntilIdle()
    }

    func testFailedAndResetRouteWritesRebuildConfirmedRouteOptions() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.engine.nextError = .unsupportedFormat

        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["BuiltIn"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        var row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(row.route, .explicit(targetDeviceUIDs: ["USB"]))
        XCTAssertEqual(row.routeOptions.first(where: { $0.uid == "USB" })?.isSelected, true)
        XCTAssertEqual(row.routeOptions.first(where: { $0.uid == "BuiltIn" })?.isSelected, false)

        fixture.engine.nextError = nil
        fixture.coordinator.reset(processObjectID: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        row = fixture.coordinator.snapshot.processes[0]
        XCTAssertEqual(row.route, .followOriginal)
        XCTAssertEqual(row.routeOptions.first(where: { $0.uid == "BuiltIn" })?.isSelected, true)
        XCTAssertEqual(row.routeOptions.first(where: { $0.uid == "USB" })?.isSelected, false)
    }

    func testLossOfAllExplicitTargetsStopsTapAndRetainsUnavailableRoute() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        fixture.deviceProvider.setAlive(false, uid: "USB")
        await fixture.emit([.deviceList])

        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].route,
            .explicit(targetDeviceUIDs: ["USB"])
        )
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .targetUnavailable(["USB"])
        )
    }

    func testLossOfAllTargetsCommitsUnavailableOnlyAfterAcceptedIdleStop() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let stopError = ProcessTapEngineError.operationFailed(operation: .stopDevice, status: -1)
        fixture.engine.scriptedStopResults = [(.failed, stopError)]

        fixture.deviceProvider.setAlive(false, uid: "USB")
        await fixture.emit([.deviceList])

        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .failed)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].error, .operationFailed(stopError))
    }

    func testSourceOutputChangeRebuildsFollowOriginalButDefaultChangeDoesNotRebuildExplicit() async {
        let followFixture = CoordinatorFixture(availability: .supported)
        await followFixture.coordinator.start()
        followFixture.coordinator.setProcessVolume(0.5, for: 11)
        await followFixture.coordinator.testingWaitUntilIdle()
        followFixture.processProvider.processes = [.music(objectID: 11, outputDeviceIDs: [20])]
        await followFixture.emit([.process(11, .outputDevices)])
        XCTAssertEqual(followFixture.engine.plans.last?.selectedTargetUIDs, ["USB"])

        followFixture.processProvider.processes = [.music(objectID: 11, outputDeviceIDs: [10])]
        await followFixture.emit([.defaultOutputDevice])
        XCTAssertEqual(followFixture.engine.plans.last?.selectedTargetUIDs, ["BuiltIn"])

        let explicitFixture = CoordinatorFixture(availability: .supported)
        await explicitFixture.coordinator.start()
        explicitFixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await explicitFixture.coordinator.testingWaitUntilIdle()
        let applyCount = explicitFixture.engine.plans.count
        await explicitFixture.emit([.defaultOutputDevice])
        XCTAssertEqual(explicitFixture.engine.plans.count, applyCount)
        XCTAssertEqual(explicitFixture.engine.plans.last?.selectedTargetUIDs, ["USB"])
    }

    func testSampleRateChangeRebuildsOnlySessionUsingDevice() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let applyCount = fixture.engine.plans.count

        await fixture.emit([.device(10, .nominalSampleRate)])
        XCTAssertEqual(fixture.engine.plans.count, applyCount + 1)

        await fixture.emit([.device(20, .nominalSampleRate)])
        XCTAssertEqual(fixture.engine.plans.count, applyCount + 1)
    }

    func testServiceRestartStopsRefreshesCleansAndRestores() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let initialApplyCount = fixture.engine.plans.count

        await fixture.emit([.serviceRestarted])

        XCTAssertTrue(fixture.lifecycle.events.contains("engine.stopAll"))
        XCTAssertEqual(fixture.engine.cleanupCount, 2)
        XCTAssertGreaterThan(fixture.engine.plans.count, initialApplyCount)
    }

    func testServiceRestartRestoresBundlelessConfirmedRule() async {
        let fixture = CoordinatorFixture(
            availability: .supported,
            bundleIdentifier: nil
        )
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let initialApplyCount = fixture.engine.plans.count

        await fixture.emit([.serviceRestarted])

        XCTAssertEqual(fixture.engine.plans.count, initialApplyCount + 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
    }

    func testUnsupportedServiceRestartNeverEnumeratesProcesses() async {
        let fixture = CoordinatorFixture(availability: .unsupported)
        await fixture.coordinator.start()

        await fixture.emit([.serviceRestarted])

        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.engine.applyCount, 0)
    }

    func testUnsupportedOrdinaryMonitorChangesNeverEnumerateOrObserveProcesses() async {
        let fixture = CoordinatorFixture(availability: .unsupported)
        await fixture.coordinator.start()

        await fixture.emit([
            .processList,
            .defaultOutputDevice,
            .process(11, .outputDevices),
        ])

        XCTAssertEqual(fixture.processProvider.callCount, 0)
        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.monitor.observedProcessObjectIDs, [])
        XCTAssertEqual(fixture.engine.applyCount, 0)
    }

    func testStartUsesCleanupMonitorRefreshObserveRestoreOrder() async {
        let profile = AudioProcessProfile(
            bundleIdentifier: "com.example.music",
            volume: 0.5
        )
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [profile.bundleIdentifier: profile]
        )

        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(
            fixture.lifecycle.events.prefix(7),
            [
                "engine.cleanup",
                "monitor.start",
                "routes.read",
                "devices.read",
                "processes.read",
                "monitor.observe",
                "engine.apply",
            ]
        )
    }

    func testCanceledStartFinishingCleanupAfterShutdownDoesNotStartRuntimeWork() async {
        let fixture = CoordinatorFixture(
            availability: .supported,
            savedProfiles: [
                "com.example.music": AudioProcessProfile(
                    bundleIdentifier: "com.example.music",
                    volume: 0.5
                ),
            ]
        )
        await fixture.engine.blockCleanup()
        let startTask = Task { @MainActor in
            await fixture.coordinator.start()
        }
        await fixture.engine.waitUntilCleanupCount(1)

        startTask.cancel()
        await fixture.coordinator.shutdown()
        await fixture.engine.resumeCleanup()
        await startTask.value

        XCTAssertEqual(fixture.monitor.startCount, 0)
        XCTAssertFalse(fixture.lifecycle.events.contains("monitor.observe"))
        XCTAssertFalse(fixture.lifecycle.events.contains("routes.read"))
        XCTAssertFalse(fixture.lifecycle.events.contains("devices.read"))
        XCTAssertFalse(fixture.lifecycle.events.contains("processes.read"))
        XCTAssertEqual(fixture.engine.applyCount, 0)
    }

    func testChangeBufferedWhileStartingMonitorIsReconciled() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.processProvider.scriptedProcesses = [
            [.music(objectID: 11)],
            [.music(objectID: 22)],
        ]
        fixture.deviceProvider.onRouteRead = {
            fixture.monitor.emit([.processList])
        }
        let reconciled = expectation(description: "startup change reconciled")
        let cancellable = fixture.coordinator.snapshotPublisher
            .filter { $0.processes.map(\.id) == [22] }
            .first()
            .sink { _ in reconciled.fulfill() }

        await fixture.coordinator.start()
        await fulfillment(of: [reconciled], timeout: 0.1)

        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [22])
        XCTAssertEqual(fixture.engine.stoppedProcessObjectIDs, [11])
        withExtendedLifetime(cancellable) {}
    }

    func testMissingSelectedRouteRemainsVisibleAsUnavailableOption() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.coordinator.setProcessRoute(.explicit(targetDeviceUIDs: ["USB"]), for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.deviceProvider.removeRouteDevice(uid: "USB")

        await fixture.emit([.deviceList])

        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].routeOptions.first(where: { $0.uid == "USB" }),
            AudioRouteDeviceOption(
                uid: "USB",
                name: "USB",
                isAvailable: false,
                isSelected: true
            )
        )
    }

    func testMonitorStartFailureFailsClosedAndStartCanRetry() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.monitor.startError = FixtureError.writeFailed

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.engine.applyCount, 0)
        fixture.monitor.startError = nil
        await fixture.coordinator.start()
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.monitor.startCount, 2)
    }

    func testMonitorObservationFailureFailsClosedAndStartCanRetry() async {
        let fixture = CoordinatorFixture(availability: .supported)
        fixture.monitor.observationError = FixtureError.writeFailed

        await fixture.coordinator.start()

        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertEqual(fixture.engine.applyCount, 0)
        fixture.monitor.observationError = nil
        await fixture.coordinator.start()
        XCTAssertEqual(fixture.coordinator.snapshot.processes.map(\.id), [11])
        XCTAssertEqual(fixture.monitor.startCount, 2)
    }

    func testRuntimeObservationFailureStopsRulesAndRetryRestoresBundlelessRule() async {
        let fixture = CoordinatorFixture(
            availability: .supported,
            bundleIdentifier: nil
        )
        await fixture.coordinator.start()
        fixture.coordinator.setProcessVolume(0.5, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        let applyCount = fixture.engine.applyCount
        fixture.monitor.observationError = FixtureError.writeFailed

        await fixture.emit([.processList])

        XCTAssertEqual(fixture.coordinator.snapshot.processes, [])
        XCTAssertTrue(fixture.lifecycle.events.contains("engine.stopAll"))
        fixture.monitor.observationError = nil
        await fixture.coordinator.start()
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.monitor.startCount, 2)
        XCTAssertEqual(fixture.engine.applyCount, applyCount + 1)
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].session.state, .running)
    }

    func testGenericEngineFailureIsTypedAndRetryable() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.engine.nextError = .unsupportedFormat

        fixture.coordinator.setProcessMuted(true, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(
            fixture.coordinator.snapshot.processes[0].error,
            .operationFailed(.unsupportedFormat)
        )
        XCTAssertEqual(fixture.coordinator.snapshot.processes[0].pendingValues?.isMuted, true)
    }

    func testDeviceMuteUsesConfirmedValueAndRollsBackOnFailure() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.deviceProvider.confirmedMute = true
        fixture.coordinator.setDeviceMuted(true, for: "BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.mute.value, true)

        fixture.deviceProvider.muteWriteError = FixtureError.writeFailed
        fixture.coordinator.setDeviceMuted(false, for: "BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.mute.value, true)
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].error, .deviceWrite)
    }

    func testDeviceVolumeUsesHardwareConfirmedValueAndRetryRefreshesOneRow() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()
        fixture.deviceProvider.confirmedVolume = 0.73
        fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.73)

        fixture.deviceProvider.volumeWriteError = FixtureError.writeFailed
        fixture.coordinator.setDeviceVolume(0.9, for: "BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        fixture.deviceProvider.snapshotVolume = 0.61
        fixture.coordinator.retryDevice("BuiltIn")
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.61)
        XCTAssertNil(fixture.coordinator.snapshot.devices[0].error)
        XCTAssertEqual(fixture.processProvider.callCount, 1)
    }

    func testDeviceVolumeAndMuteUseIndependentTasksAndMergeLatestConfirmation() async {
        let delay = ControlledAudioDelay()
        let fixture = CoordinatorFixture(availability: .supported, delay: delay.callAsFunction)
        await fixture.coordinator.start()
        fixture.deviceProvider.confirmedVolume = 0.73
        fixture.deviceProvider.confirmedMute = true

        fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
        await delay.waitUntilCallCount(1)
        fixture.coordinator.setDeviceMuted(true, for: "BuiltIn")
        await fixture.coordinator.testingWaitForDeviceMute("BuiltIn")
        await delay.resumeAll()
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.deviceProvider.volumeWrites, [0.8])
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.73)
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.mute.value, true)
    }

    func testFailedDeviceWritesRestoreLatestRefreshInsteadOfCapturedProperties() async {
        let delay = ControlledAudioDelay()
        let fixture = CoordinatorFixture(availability: .supported, delay: delay.callAsFunction)
        await fixture.coordinator.start()
        fixture.deviceProvider.volumeWriteError = FixtureError.writeFailed
        fixture.coordinator.setDeviceVolume(0.8, for: "BuiltIn")
        await delay.waitUntilCallCount(1)
        fixture.deviceProvider.snapshotVolume = 0.61
        fixture.coordinator.retryDevice("BuiltIn")
        await delay.resumeAll()
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.volume.value, 0.61)

        fixture.deviceProvider.muteWriteError = FixtureError.writeFailed
        fixture.coordinator.setDeviceMuted(true, for: "BuiltIn")
        fixture.deviceProvider.snapshotMute = true
        fixture.coordinator.retryDevice("BuiltIn")
        await fixture.coordinator.testingWaitUntilIdle()
        XCTAssertEqual(fixture.coordinator.snapshot.devices[0].device.mute.value, true)
    }

    func testRapidMuteAndProcessIntentsSkipCanceledWorkBeforeHAL() async {
        let fixture = CoordinatorFixture(availability: .supported)
        await fixture.coordinator.start()

        fixture.coordinator.setDeviceMuted(false, for: "BuiltIn")
        fixture.coordinator.setDeviceMuted(true, for: "BuiltIn")
        fixture.coordinator.setProcessVolume(0.4, for: 11)
        fixture.coordinator.setProcessVolume(0.6, for: 11)
        await fixture.coordinator.testingWaitUntilIdle()

        XCTAssertEqual(fixture.deviceProvider.muteWrites, [true])
        XCTAssertEqual(fixture.engine.gains.map(\.volume), [0.6])
    }

    func testShutdownCancelsPendingSliderWrite() async {
        let delay = ControlledAudioDelay()
        let fixture = CoordinatorFixture(availability: .supported, delay: delay.callAsFunction)
        await fixture.coordinator.start()
        fixture.coordinator.setDeviceVolume(0.9, for: "BuiltIn")
        await delay.waitUntilCallCount(1)

        let shutdown = Task { @MainActor in await fixture.coordinator.shutdown() }
        await delay.resumeAll()
        await shutdown.value

        XCTAssertEqual(fixture.deviceProvider.volumeWrites, [])
    }

    func testShutdownAwaitsCanceledDeviceTaskBeforeStoppingEngine() async {
        let delay = ControlledShutdownDelay()
        let fixture = CoordinatorFixture(availability: .supported, delay: delay.callAsFunction)
        await fixture.coordinator.start()
        fixture.coordinator.setDeviceVolume(0.9, for: "BuiltIn")
        await delay.waitUntilEntered()

        let shutdown = Task { @MainActor in await fixture.coordinator.shutdown() }
        await delay.waitUntilCanceled()

        XCTAssertFalse(fixture.lifecycle.events.contains("engine.stopAll"))
        await delay.release()
        await shutdown.value
        XCTAssertTrue(fixture.lifecycle.events.contains("engine.stopAll"))
    }

    func testCoordinatorDeallocatesAfterPopoverObservationEnds() async {
        weak var weakCoordinator: AudioControlCoordinator?
        let engine = EngineFake()
        let terminated = expectation(description: "engine snapshot consumer terminated")
        engine.onStreamTermination { terminated.fulfill() }
        var fixture: CoordinatorFixture? = CoordinatorFixture(
            availability: .supported,
            engine: engine
        )
        await fixture?.coordinator.start()
        weakCoordinator = fixture?.coordinator
        var cancellable = fixture?.coordinator.snapshotPublisher.sink { _ in }

        cancellable = nil
        fixture = nil
        await fulfillment(of: [terminated], timeout: 1)

        XCTAssertNil(cancellable)
        XCTAssertNil(weakCoordinator)
    }
}
