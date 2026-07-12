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
        let marker = fixture.coordinator.testingEngineSnapshotMarker

        fixture.coordinator.setProcessVolume(0.4, for: 11)
        await fixture.engine.waitUntilApplyReturnCount(1)
        await fixture.coordinator.testingWaitForEngineSnapshot(after: marker)

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
        let marker = fixture.coordinator.testingEngineSnapshotMarker
        fixture.engine.deliverDeferredObservers()
        await fixture.coordinator.testingWaitForEngineSnapshot(after: marker)

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
        await fulfillment(of: [terminated], timeout: 0.05)

        XCTAssertNil(cancellable)
        XCTAssertNil(weakCoordinator)
    }
}

private enum FixtureError: Error {
    case writeFailed
}

@MainActor
private final class CoordinatorFixture {
    let deviceProvider = DeviceProviderFake()
    let processProvider = ProcessProviderFake()
    let monitor = MonitorFake()
    let engine: EngineFake
    let store = PreferencesStoreFake()
    let lifecycle = LifecycleRecorder()
    let coordinator: AudioControlCoordinator

    init(
        availability: AudioFeatureAvailability,
        bundleIdentifier: String? = "com.example.music",
        savedProfiles: [String: AudioProcessProfile] = [:],
        engine: EngineFake = EngineFake(),
        delay: @escaping AudioControlDelay = { _ in }
    ) {
        self.engine = engine
        processProvider.bundleIdentifier = bundleIdentifier
        store.savedPreferences.audioProcessProfiles = savedProfiles
        monitor.lifecycle = lifecycle
        engine.lifecycle = lifecycle
        let preferences = PreferencesController(
            store: store,
            launchService: NoopLaunchAtLoginService()
        )
        let planner = Self.validatedPlanner(devices: deviceProvider.routeDescriptors)
        coordinator = AudioControlCoordinator(
            availability: availability,
            deviceProvider: deviceProvider,
            processProvider: processProvider,
            routeDeviceProvider: deviceProvider,
            monitor: monitor,
            planner: planner,
            engine: engine,
            preferences: preferences,
            delay: delay
        )
    }

    func emit(_ changes: Set<AudioSystemChange>) async {
        let marker = coordinator.testingReconciliationMarker
        monitor.emit(changes)
        await coordinator.testingWaitForReconciliation(after: marker)
    }

    func emitEngine(_ snapshot: ProcessTapSessionSnapshot) async {
        let marker = coordinator.testingEngineSnapshotMarker
        engine.emit(snapshot)
        await coordinator.testingWaitForEngineSnapshot(after: marker)
    }

    private static func validatedPlanner(devices: [AudioRouteDevice]) -> AudioRoutePlanner {
        let fingerprintPlanner = AudioRoutePlanner()
        let requests: [([String], AudioRouteMode)] = [
            (["BuiltIn"], .followOriginal),
            (["USB"], .followOriginal),
            (["BuiltIn"], .explicit(targetDeviceUIDs: ["USB"])),
            (["BuiltIn"], .explicit(targetDeviceUIDs: ["BuiltIn", "USB"])),
        ]
        let fingerprints = requests.compactMap { sourceUIDs, mode in
            try? fingerprintPlanner.topologyFingerprint(for: .init(
                processObjectID: 11,
                generation: 1,
                sourceDeviceUIDs: sourceUIDs,
                systemDefaultOutputDeviceUID: nil,
                mode: mode,
                devices: devices
            ))
        }
        return AudioRoutePlanner(
            policy: .init(validatedFingerprints: Set(fingerprints))
        )
    }
}

private extension AudioFeatureAvailability {
    static let unsupported = AudioFeatureAvailability(
        operatingSystemVersion: .init(majorVersion: 14, minorVersion: 1, patchVersion: 0)
    )
    static let supported = AudioFeatureAvailability(
        operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0)
    )
}

@MainActor
private final class DeviceProviderFake: AudioDeviceControlProviding, AudioRouteDeviceProviding {
    var volumeWriteError: Error?
    var muteWriteError: Error?
    var confirmedMute = false
    var confirmedVolume = 0.5
    var snapshotVolume = 0.5
    private(set) var volumeWrites: [Double] = []
    private(set) var muteWrites: [Bool] = []

    var routeDescriptors: [AudioRouteDevice] = [
        makeRouteDevice(id: 10, uid: "BuiltIn"),
        makeRouteDevice(id: 20, uid: "USB"),
    ]

    func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot] {
        [.init(
            id: "BuiltIn",
            objectID: 10,
            name: "Speakers",
            volume: .value(snapshotVolume, isWritable: true),
            mute: .value(false, isWritable: true)
        )]
    }

    func outputDeviceSnapshot(forUID uid: String) throws -> AudioOutputDeviceSnapshot {
        try outputDeviceSnapshots()[0]
    }

    func writeVolume(_ volume: Double, forUID uid: String) throws -> Double {
        volumeWrites.append(volume)
        if let volumeWriteError { throw volumeWriteError }
        return confirmedVolume
    }
    func writeMute(_ isMuted: Bool, forUID uid: String) throws -> Bool {
        muteWrites.append(isMuted)
        if let muteWriteError { throw muteWriteError }
        return confirmedMute
    }
    func routeDevices() throws -> [AudioRouteDevice] { routeDescriptors }

    func setAlive(_ isAlive: Bool, uid: String) {
        routeDescriptors = routeDescriptors.map { device in
            guard device.uid == uid else { return device }
            return AudioRouteDevice(
                objectID: device.objectID,
                uid: device.uid,
                name: device.name,
                isAlive: isAlive,
                isAggregate: device.isAggregate,
                aggregateSubdeviceUIDs: device.aggregateSubdeviceUIDs,
                inputStreams: device.inputStreams,
                outputStreams: device.outputStreams,
                clockDomain: device.clockDomain,
                transportType: device.transportType,
                modelUID: device.modelUID,
                driverIdentity: device.driverIdentity,
                aggregateComposition: device.aggregateComposition
            )
        }
    }

    func removeRouteDevice(uid: String) {
        routeDescriptors.removeAll { $0.uid == uid }
    }

    private static func makeRouteDevice(id: AudioObjectID, uid: String) -> AudioRouteDevice {
        AudioRouteDevice(
            objectID: id,
            uid: uid,
            name: uid,
            isAlive: true,
            isAggregate: false,
            aggregateSubdeviceUIDs: [],
            outputStreams: [.init(
                streamObjectID: id * 100,
                streamIndex: 0,
                format: .init(
                    sampleRate: 48_000,
                    channelCount: 2,
                    formatID: kAudioFormatLinearPCM,
                    formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                    bitsPerChannel: 32,
                    interleaving: .interleaved
                )
            )],
            clockDomain: 100,
            transportType: kAudioDeviceTransportTypeBuiltIn,
            modelUID: "model.\(uid)",
            driverIdentity: .init(plugInBundleID: "driver.\(uid)", availableVersion: nil)
        )
    }
}

@MainActor
private final class ProcessProviderFake: AudioProcessProviding {
    private(set) var callCount = 0
    var bundleIdentifier: String? = "com.example.music"
    var processes: [AudioProcessEntry]?

    func audibleOutputProcesses() -> [AudioProcessEntry] {
        callCount += 1
        return processes ?? [.init(
            processObjectID: 11,
            processIdentifier: 101,
            name: "Music",
            bundleIdentifier: bundleIdentifier,
            bundleURL: nil,
            outputDeviceIDs: [10]
        )]
    }
}

private extension AudioProcessEntry {
    static func music(
        objectID: AudioObjectID,
        outputDeviceIDs: [AudioDeviceID] = [10]
    ) -> AudioProcessEntry {
        .init(
            processObjectID: objectID,
            processIdentifier: 101,
            name: "Music",
            bundleIdentifier: "com.example.music",
            bundleURL: nil,
            outputDeviceIDs: outputDeviceIDs
        )
    }
}

private final class MonitorFake: AudioSystemMonitoring, @unchecked Sendable {
    let changes: AsyncStream<Set<AudioSystemChange>>
    private let continuation: AsyncStream<Set<AudioSystemChange>>.Continuation
    var lifecycle: LifecycleRecorder?
    private(set) var startCount = 0
    private(set) var observedDeviceIDs: Set<AudioDeviceID> = []
    private(set) var observedProcessObjectIDs: Set<AudioObjectID> = []
    var startError: Error?
    var observationError: Error?

    init() {
        let stream = AsyncStream<Set<AudioSystemChange>>.makeStream()
        changes = stream.stream
        continuation = stream.continuation
    }

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }
    func updateObservedObjects(
        deviceIDs: Set<AudioDeviceID>,
        processObjectIDs: Set<AudioObjectID>
    ) throws {
        if let observationError { throw observationError }
        observedDeviceIDs = deviceIDs
        observedProcessObjectIDs = processObjectIDs
    }
    func stop() { lifecycle?.events.append("monitor.stop") }
    func emit(_ changes: Set<AudioSystemChange>) { continuation.yield(changes) }
}

private final class EngineFake: ProcessTapVolumeControlling, @unchecked Sendable {
    let sessionSnapshots: AsyncStream<ProcessTapSessionSnapshot>
    private let continuation: AsyncStream<ProcessTapSessionSnapshot>.Continuation
    private(set) var applyCount = 0
    private(set) var cleanupCount = 0
    private(set) var authorizationAttemptCount = 0
    private(set) var plans: [AudioRoutePlan] = []
    private(set) var gains: [ProcessGainState] = []
    private(set) var stoppedProcessObjectIDs: [AudioObjectID] = []
    var nextError: ProcessTapEngineError?
    var scriptedApplyResults: [(ProcessTapSessionState, ProcessTapEngineError?)] = []
    var scriptedStopResults: [(ProcessTapSessionState, ProcessTapEngineError?)] = []
    var lifecycle: LifecycleRecorder?
    private var nextCommandSequence: UInt64 = 0
    private let stopGate = ControlledCallGate()
    private let applyGate = ControlledIndexedCallGate()
    private let applyReturnGate = ControlledIndexedCallGate()
    private var deferredObserverCalls: Set<Int> = []
    private var deferredObservers: [ProcessTapSessionSnapshot] = []

    init() {
        let stream = AsyncStream<ProcessTapSessionSnapshot>.makeStream()
        sessionSnapshots = stream.stream
        continuation = stream.continuation
    }

    func apply(plan: AudioRoutePlan, gain: ProcessGainState) async -> ProcessTapSessionSnapshot {
        applyCount += 1
        authorizationAttemptCount += 1
        plans.append(plan)
        gains.append(gain)
        await applyGate.enter()
        let scripted = scriptedApplyResults.isEmpty
            ? (nextError == nil ? ProcessTapSessionState.running : .failed, nextError)
            : scriptedApplyResults.removeFirst()
        nextCommandSequence += 1
        let snapshot = ProcessTapSessionSnapshot(
            processObjectID: plan.processObjectID,
            generation: plan.generation,
            state: scripted.0,
            error: scripted.1,
            commandSequence: nextCommandSequence,
            emissionOrdinal: 1
        )
        if deferredObserverCalls.contains(applyCount) {
            deferredObservers.append(snapshot)
        } else {
            continuation.yield(snapshot)
        }
        await applyReturnGate.enter()
        return snapshot
    }
    func updateGain(_ gain: ProcessGainState, for processObjectID: AudioObjectID) async {}
    func stop(processObjectID: AudioObjectID, generation: UInt64) async -> ProcessTapSessionSnapshot {
        stoppedProcessObjectIDs.append(processObjectID)
        await stopGate.enter()
        let scripted = scriptedStopResults.isEmpty
            ? (ProcessTapSessionState.idle, nil)
            : scriptedStopResults.removeFirst()
        nextCommandSequence += 1
        let snapshot = ProcessTapSessionSnapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: scripted.0,
            error: scripted.1,
            commandSequence: nextCommandSequence,
            emissionOrdinal: 1
        )
        continuation.yield(snapshot)
        return snapshot
    }
    func stopAll() async { lifecycle?.events.append("engine.stopAll") }
    func cleanupOrphans() async -> [AudioTeardownFailure] {
        cleanupCount += 1
        return []
    }
    func emit(_ snapshot: ProcessTapSessionSnapshot) { continuation.yield(snapshot) }
    func blockStops() async { await stopGate.block() }
    func resumeStops() async { await stopGate.resumeAll() }
    func waitUntilStopCount(_ count: Int) async { await stopGate.waitUntilEntered(count) }
    func blockApplyCall(_ call: Int) async { await applyGate.block(call) }
    func resumeApplies() async { await applyGate.resumeAll() }
    func waitUntilApplyCount(_ count: Int) async { await applyGate.waitUntilEntered(count) }
    func blockApplyReturn(_ call: Int) async { await applyReturnGate.block(call) }
    func resumeApplyReturns() async { await applyReturnGate.resumeAll() }
    func waitUntilApplyReturnCount(_ count: Int) async {
        await applyReturnGate.waitUntilEntered(count)
    }
    func deferApplyObserver(_ call: Int) { deferredObserverCalls.insert(call) }
    func deliverDeferredObservers() {
        let pending = deferredObservers
        deferredObservers.removeAll()
        pending.forEach { continuation.yield($0) }
    }
    func onStreamTermination(_ action: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in action() }
    }
}

private final class PreferencesStoreFake: PreferencesStoring, @unchecked Sendable {
    private(set) var saveCount = 0
    var savedPreferences: AppPreferences = .default
    var saveError: Error?
    var saveFailuresRemaining = 0
    func load() -> AppPreferences { savedPreferences }
    func save(_ preferences: AppPreferences) throws {
        saveCount += 1
        if saveFailuresRemaining > 0 {
            saveFailuresRemaining -= 1
            throw FixtureError.writeFailed
        }
        if let saveError { throw saveError }
        savedPreferences = preferences
    }
}

private final class LifecycleRecorder: @unchecked Sendable {
    var events: [String] = []
}

private actor ControlledAudioDelay {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func callAsFunction(_ duration: Duration) async {
        callCount += 1
        let ready = callCountWaiters.filter { callCount >= $0.0 }
        callCountWaiters.removeAll { callCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilCallCount(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { callCountWaiters.append((count, $0)) }
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor ControlledShutdownDelay {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var entered = false
    private var canceled = false
    private var released = false

    func callAsFunction(_ duration: Duration) async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withTaskCancellationHandler {
            await withCheckedContinuation { enteredContinuation = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
        guard released == false else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard entered == false else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitUntilCanceled() async {
        guard canceled == false else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func cancel() {
        canceled = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        cancellationWaiters.forEach { $0.resume() }
        cancellationWaiters.removeAll()
    }
}

private actor ControlledCallGate {
    private var isBlocked = false
    private var enteredCount = 0
    private var blockedCalls: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func block() {
        isBlocked = true
    }

    func enter() async {
        enteredCount += 1
        let ready = enteredWaiters.filter { enteredCount >= $0.0 }
        enteredWaiters.removeAll { enteredCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard isBlocked else { return }
        await withCheckedContinuation { blockedCalls.append($0) }
    }

    func waitUntilEntered(_ count: Int) async {
        guard enteredCount < count else { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    func resumeAll() {
        isBlocked = false
        let calls = blockedCalls
        blockedCalls.removeAll()
        calls.forEach { $0.resume() }
    }
}

private actor ControlledIndexedCallGate {
    private var blockedEntries: Set<Int> = []
    private var enteredCount = 0
    private var blockedCalls: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func block(_ entry: Int) {
        blockedEntries.insert(entry)
    }

    func enter() async {
        enteredCount += 1
        let current = enteredCount
        let ready = enteredWaiters.filter { enteredCount >= $0.0 }
        enteredWaiters.removeAll { enteredCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        guard blockedEntries.contains(current) else { return }
        await withCheckedContinuation { blockedCalls.append($0) }
    }

    func waitUntilEntered(_ count: Int) async {
        guard enteredCount < count else { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    func resumeAll() {
        blockedEntries.removeAll()
        let calls = blockedCalls
        blockedCalls.removeAll()
        calls.forEach { $0.resume() }
    }
}
