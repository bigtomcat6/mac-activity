import CoreAudio
import Foundation
import XCTest

@testable import MacActivityCore

final class ProcessTapVolumeEngineTests: XCTestCase {
    func testCallbackProgressAtGlobalDeadlineIsNeverAccepted() {
        let deadline = DispatchTime(uptimeNanoseconds: 1_000_000)
        XCTAssertFalse(ProcessTapVolumeEngine.callbackProgressIsReady(
            now: deadline,
            deadline: deadline,
            countBeforeObservation: 1,
            currentCount: 2
        ))
        XCTAssertTrue(ProcessTapVolumeEngine.callbackProgressIsReady(
            now: DispatchTime(uptimeNanoseconds: 999_000),
            deadline: deadline,
            countBeforeObservation: 1,
            currentCount: 2
        ))
    }

    func testPreparationOrderKeepsOriginalAudioUntilOutputIsReady() async throws {
        let fixture = EngineFixture()

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.6)
        )

        XCTAssertEqual(snapshot.state, .running)
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(fixture.hardware.calls, [
            .createTap(sourceIndex: 0, initiallyMuted: false),
            .readTapFormat(sourceIndex: 0),
            .createAggregate(tapAutoStart: false),
            .waitForAggregateReadiness,
            .createIOProc,
            .configureInputStreamUsage([1]),
            .startDevice,
            .observeSustainedCallbacks,
            .setTapMutedWhenTapped(sourceIndex: 0),
        ])

        let context = try XCTUnwrap(fixture.hardware.lastContext)
        let storage = AudioBufferListTestStorage.interleavedStereo(
            input: [1, -1],
            outputFrameCount: 1
        )
        storage.process(with: context)
        XCTAssertEqualFloatArrays(
            storage.outputSamples,
            [0.6, -0.6],
            accuracy: 0.000_001
        )
    }

    func testSingleCallbackDoesNotQualifyAsSustainedPlayback() async throws {
        let fixture = EngineFixture()
        fixture.hardware.singleCallbackOnly = true
        let task = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 1),
                gain: ProcessGainState(volume: 0.6)
            )
        }
        await fixture.hardware.waitUntilCall(.observeSustainedCallbacks)
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        let snapshot = await task.value
        XCTAssertEqual(snapshot.error, .routeSuperseded)
        XCTAssertFalse(
            fixture.hardware.calls.contains(.setTapMutedWhenTapped(sourceIndex: 0))
        )
    }

    func testStrictStartupMuteFailureUsesReverseTeardown() async {
        let fixture = EngineFixture()
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .setTapMuted(0)
        )

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.6)
        )

        XCTAssertEqual(
            snapshot.error,
            .operationFailed(
                operation: .setData,
                status: kAudioHardwareUnspecifiedError
            )
        )
        XCTAssertEqual(Array(fixture.hardware.calls.suffix(5)), [
            .stopDevice,
            .destroyIOProc,
            .destroyAggregate,
            .ownedObjects,
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testNewerGenerationSupersedesPreparationWithoutPublishingStaleState() async {
        let recorder = SnapshotRecorder()
        let fixture = EngineFixture(
            readinessInitiallyBlocked: true,
            recorder: recorder
        )
        let oldTask = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 1),
                gain: ProcessGainState(volume: 0.5)
            )
        }
        await fixture.hardware.waitUntilReadinessPolling()
        recorder.clear()

        let newest = await fixture.engine.apply(
            plan: fixture.plan(generation: 2),
            gain: ProcessGainState(volume: 0.8)
        )
        let old = await oldTask.value

        XCTAssertEqual(old.error, .routeSuperseded)
        XCTAssertEqual(newest.generation, 2)
        XCTAssertEqual(newest.state, .running)
        XCTAssertTrue(recorder.snapshots.allSatisfy { $0.generation == 2 })
    }

    func testTaskCancellationSupersedesPreparationAndTearsDownStartedIOProc() async {
        let fixture = EngineFixture(firstCallbackInitiallyBlocked: true)
        let task = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 1),
                gain: ProcessGainState(volume: 0.5)
            )
        }
        await fixture.hardware.waitUntilCall(.startDevice)

        task.cancel()
        let snapshot = await task.value

        XCTAssertEqual(snapshot.error, .routeSuperseded)
        XCTAssertEqual(Array(fixture.hardware.calls.suffix(5)), [
            .stopDevice,
            .destroyIOProc,
            .destroyAggregate,
            .ownedObjects,
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testEveryPartialAcquisitionFailureUsesCheckedReverseTeardown() async {
        struct Scenario {
            let point: FakeAudioTapHardware.FailurePoint
            let sourceCount: Int
            let expectedCalls: [FakeAudioTapHardware.Call]
        }

        let scenarios = [
            Scenario(
                point: .createTap(0),
                sourceCount: 2,
                expectedCalls: [
                    .createTap(sourceIndex: 0, initiallyMuted: false),
                ]
            ),
            Scenario(
                point: .createTap(1),
                sourceCount: 2,
                expectedCalls: [
                    .createTap(sourceIndex: 0, initiallyMuted: false),
                    .createTap(sourceIndex: 1, initiallyMuted: false),
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .readTapFormat(1),
                sourceCount: 2,
                expectedCalls: [
                    .createTap(sourceIndex: 0, initiallyMuted: false),
                    .createTap(sourceIndex: 1, initiallyMuted: false),
                    .readTapFormat(sourceIndex: 0),
                    .readTapFormat(sourceIndex: 1),
                    .destroyTap(sourceIndex: 1),
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .createAggregate,
                sourceCount: 1,
                expectedCalls: callsThroughTapFormat + [
                    .createAggregate(tapAutoStart: false),
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .waitForAggregateReadiness,
                sourceCount: 1,
                expectedCalls: callsThroughAggregate + [
                    .waitForAggregateReadiness,
                    .destroyAggregate,
                    .ownedObjects,
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .createIOProc,
                sourceCount: 1,
                expectedCalls: callsThroughStableTopology + [
                    .createIOProc,
                    .destroyAggregate,
                    .ownedObjects,
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .startDevice,
                sourceCount: 1,
                expectedCalls: callsThroughStableTopology + [
                    .createIOProc,
                    .configureInputStreamUsage([1]),
                    .startDevice,
                    .destroyIOProc,
                    .destroyAggregate,
                    .ownedObjects,
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .configureInputStreamUsage,
                sourceCount: 1,
                expectedCalls: callsThroughStableTopology + [
                    .createIOProc,
                    .configureInputStreamUsage([1]),
                    .destroyIOProc,
                    .destroyAggregate,
                    .ownedObjects,
                    .destroyTap(sourceIndex: 0),
                ]
            ),
        ]

        for scenario in scenarios {
            let fixture = EngineFixture()
            fixture.hardware.enqueueStatus(
                kAudioHardwareUnspecifiedError,
                at: scenario.point
            )

            let snapshot = await fixture.engine.apply(
                plan: fixture.plan(
                    generation: 1,
                    sourceCount: scenario.sourceCount
                ),
                gain: ProcessGainState(volume: 0.5)
            )

            XCTAssertEqual(snapshot.state, .failed, "\(scenario.point)")
            XCTAssertEqual(
                fixture.hardware.calls,
                scenario.expectedCalls,
                "\(scenario.point)"
            )
        }
    }

    func testUnsupportedTapFormatFailsBeforeAggregateCreation() async {
        let fixture = EngineFixture()
        fixture.hardware.tapFormatOverrides[0] = ProcessTapAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            bitsPerChannel: 32,
            interleaving: .interleaved
        )

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.error, .unsupportedFormat)
        XCTAssertEqual(fixture.hardware.calls, [
            .createTap(sourceIndex: 0, initiallyMuted: false),
            .readTapFormat(sourceIndex: 0),
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testInvalidActualAggregateMappingFailsBeforeIOProcCreation() async {
        let fixture = EngineFixture()
        let format = fixture.format
        fixture.hardware.aggregateTopologySnapshotOverride = AudioAggregateTopologySnapshot(
            isAlive: true,
            inputStreamIDs: [10],
            inputFormats: [format],
            outputStreamIDs: [],
            outputFormats: [],
            tapUUIDs: fixture.hardware.createdTapResources.map(\.uuid),
            activeSubTapIDs: [30]
        )

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.error, .unsupportedFormat)
        XCTAssertFalse(fixture.hardware.calls.contains(.createIOProc))
    }

    func testAggregateTopologyErrorMapsToUnsupportedFormatBeforeIOProc() async {
        let fixture = EngineFixture()
        fixture.hardware.aggregateTopologyError = .unsupportedTopology

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.error, .unsupportedFormat)
        XCTAssertFalse(fixture.hardware.calls.contains(.createIOProc))
    }

    @available(macOS 14.2, *)
    func testProcessTapsUnavailableHALErrorMapsTruthfullyBeforeMutableHAL() async {
        let backend = FakeAudioHALBackend()
        let hardware = CoreAudioTapHardware(
            hal: AudioHALClient(
                backend: backend,
                processTapsAvailable: false
            )
        )
        let fixture = EngineFixture()
        let engine = ProcessTapVolumeEngine(
            hardware: hardware,
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                )
            ),
            queue: DispatchQueue(
                label: "ProcessTapVolumeEngineTests.process-taps-unavailable"
            )
        )

        let snapshot = await engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.error, .processTapsUnavailable)
        XCTAssertTrue(backend.mutableOperations.isEmpty)
    }

    func testLifecycleHardwareCallsNeverRunOnMainThread() async {
        let fixture = EngineFixture()
        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.4)
        )
        _ = await fixture.engine.stop(
            processObjectID: snapshot.processObjectID,
            generation: snapshot.generation
        )
        _ = await fixture.engine.cleanupOrphans()

        XCTAssertEqual(fixture.hardware.mainThreadCallCount, 0)
    }

    func testDistinctProcessObjectIDsOwnIndependentSessions() async {
        let fixture = EngineFixture()
        let firstEntry = AudioProcessEntry(
            processObjectID: 41,
            processIdentifier: 101,
            name: "First",
            bundleIdentifier: nil,
            bundleURL: nil
        )
        let secondEntry = AudioProcessEntry(
            processObjectID: 42,
            processIdentifier: 101,
            name: "Second",
            bundleIdentifier: nil,
            bundleURL: nil
        )

        let first = await fixture.engine.apply(
            plan: fixture.plan(
                processObjectID: firstEntry.processObjectID,
                generation: 1
            ),
            gain: ProcessGainState(volume: 0.3)
        )
        let second = await fixture.engine.apply(
            plan: fixture.plan(
                processObjectID: secondEntry.processObjectID,
                generation: 1
            ),
            gain: ProcessGainState(volume: 0.7)
        )

        XCTAssertEqual(
            firstEntry.processIdentifier,
            secondEntry.processIdentifier
        )
        XCTAssertEqual(first.state, .running)
        XCTAssertEqual(second.state, .running)
        XCTAssertEqual(fixture.hardware.createdProcessObjectIDs, [41, 42])

        await fixture.engine.stopAll()
    }

    func testGainOnlyUpdateTouchesDSPContextWithoutHardwareRebuild() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.6)
        )
        let context = try XCTUnwrap(fixture.hardware.lastContext)
        fixture.hardware.clearCalls()

        await fixture.engine.updateGain(
            ProcessGainState(volume: 0.2),
            for: 77
        )

        XCTAssertTrue(fixture.hardware.calls.isEmpty)
        let frameCount = 1_440
        let storage = AudioBufferListTestStorage.interleavedStereo(
            input: Array(repeating: 1, count: frameCount * 2),
            outputFrameCount: frameCount
        )
        storage.process(with: context)
        let lastSample = try XCTUnwrap(storage.outputSamples.last)
        XCTAssertEqual(lastSample, 0.2, accuracy: 0.000_001)
    }

    func testMacOS141ReturnsUnavailableWithoutTouchingHardware() async {
        let fixture = EngineFixture(macOS: (14, 1))

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertEqual(snapshot.error, .processTapsUnavailable)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
    }

    func testOnlyDocumentedPermissionStatusMapsToPermissionDenied() async {
        let permissionFixture = EngineFixture()
        permissionFixture.hardware.enqueueStatus(
            kAudioDevicePermissionsError,
            at: .createTap(0)
        )

        let permissionSnapshot = await permissionFixture.engine.apply(
            plan: permissionFixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(
            permissionSnapshot.error,
            .permissionDenied(kAudioDevicePermissionsError)
        )

        let ambiguousFixture = EngineFixture()
        ambiguousFixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .createTap(0)
        )
        let ambiguousSnapshot = await ambiguousFixture.engine.apply(
            plan: ambiguousFixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        XCTAssertEqual(
            ambiguousSnapshot.error,
            .operationFailed(
                operation: .createTap,
                status: kAudioHardwareUnspecifiedError
            )
        )
    }

    func testRebuildTearsDownOldAudibleSessionBeforeCreatingReplacement() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.4)
        )
        let oldContext = WeakReference(fixture.hardware.lastContext)
        fixture.hardware.clearCalls()

        let replacement = await fixture.engine.apply(
            plan: fixture.plan(generation: 2),
            gain: ProcessGainState(volume: 0.8)
        )

        XCTAssertEqual(replacement.state, .running)
        let calls = fixture.hardware.calls
        let stopIndex = calls.firstIndex(of: .stopDevice)
        let createIndex = calls.firstIndex(of: .createTap(
            sourceIndex: 0,
            initiallyMuted: false
        ))
        XCTAssertNotNil(stopIndex)
        XCTAssertNotNil(createIndex)
        if let stopIndex, let createIndex {
            XCTAssertLessThan(stopIndex, createIndex)
        }
        XCTAssertNil(oldContext.value)
    }

    func testStaleStopCannotTearDownNewerGeneration() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 2),
            gain: ProcessGainState()
        )
        fixture.hardware.clearCalls()

        let stale = await fixture.engine.stop(
            processObjectID: 77,
            generation: 1
        )

        XCTAssertEqual(stale.error, .routeSuperseded)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
        _ = await fixture.engine.stop(processObjectID: 77, generation: 2)
    }

    func testTeardownStopsAtFailedIOProcDestroyAndRetainsParentResources() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .stopDevice
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyAggregate
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyTap(0)
        )
        fixture.hardware.clearCalls()

        let stopped = await fixture.engine.stop(
            processObjectID: 77,
            generation: 1
        )

        XCTAssertEqual(stopped.state, .failed)
        XCTAssertEqual(fixture.hardware.calls, [
            .setTapUnmuted(sourceIndex: 0),
            .stopDevice,
            .destroyIOProc,
        ])
        let failures = await fixture.engine.cleanupOrphans()
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(Set(failures.map(\.operation.rawValue)), Set([
            AudioHALOperation.stopDevice.rawValue,
            AudioHALOperation.destroyIOProc.rawValue,
        ]))
        XCTAssertTrue(fixture.hardware.liveOwnedObjects.contains {
            $0.classID == kAudioAggregateDeviceClassID
        })
    }

    func testFailedStopAndIOProcDestroyRetainDSPContextUntilBothRetry() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        var strongContext: ProcessTapDSPContext? = try XCTUnwrap(
            fixture.hardware.lastContext
        )
        let weakContext = WeakReference(strongContext)
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .stopDevice
        )
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc
        )

        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)
        strongContext = nil

        XCTAssertNotNil(weakContext.value)
        let remaining = await fixture.engine.cleanupOrphans()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(weakContext.value)
    }

    func testCleanupRetriesLedgerBeforeStartingNewPreparation() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 77, generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyTap(0)
        )
        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)
        fixture.hardware.clearCalls()

        let next = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 88, generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(next.state, .running)
        XCTAssertEqual(fixture.hardware.calls.first, .destroyTap(sourceIndex: 0))
        XCTAssertEqual(
            fixture.hardware.calls.dropFirst().first,
            .createTap(sourceIndex: 0, initiallyMuted: false)
        )
    }

    @available(macOS 14.2, *)
    func testCleanupDestroysOnlyExactOwnedClassesInDeterministicOrder() async {
        let fixture = EngineFixture()
        fixture.hardware.ownedObjectValues = [
            ownedTap(id: 30),
            ownedAggregate(id: 20),
            AudioOwnedObject(
                id: 5,
                classID: kAudioDeviceClassID,
                uid: AudioRoutePlanner.aggregateUIDPrefix + "foreign-class",
                name: "MacActivity"
            ),
            AudioOwnedObject(
                id: 6,
                classID: kAudioTapClassID,
                uid: "11111111-0000-4000-8000-000000000006",
                name: "MacActivity"
            ),
            ownedAggregate(id: 10),
            ownedTap(id: 25),
        ]

        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .ownedObjects,
            .destroyOwnedObject(object: ownedAggregate(id: 10)),
            .destroyOwnedObject(object: ownedAggregate(id: 20)),
            .destroyOwnedObject(object: ownedTap(id: 25)),
            .destroyOwnedObject(object: ownedTap(id: 30)),
        ])
    }

    @available(macOS 14.2, *)
    func testFailedStartupDeleteRetriesAndSuccessfulRetrySuppressesAsyncEnumeration() async {
        let fixture = EngineFixture()
        fixture.hardware.ownedObjectValues = [ownedAggregate(id: 40)]
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyOwnedObject(40)
        )

        let firstFailures = await fixture.engine.cleanupOrphans()

        XCTAssertEqual(firstFailures, [
            AudioTeardownFailure(
                processObjectID: nil,
                operation: .destroyAggregate,
                objectID: 40,
                status: kAudioHardwareUnspecifiedError
            ),
        ])
        fixture.hardware.clearCalls()

        let retryFailures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(retryFailures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .ownedObjects,
            .destroyOwnedObject(object: ownedAggregate(id: 40)),
        ])
    }

    @available(macOS 14.2, *)
    func testSuccessfulStartupDeleteIsNotRepeatedWhileHALStillEnumeratesObject() async {
        let fixture = EngineFixture()
        fixture.hardware.ownedObjectValues = [ownedTap(id: 50)]

        _ = await fixture.engine.cleanupOrphans()
        fixture.hardware.clearCalls()
        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [.ownedObjects])
    }

    @available(macOS 14.2, *)
    func testDisappearedStartupObjectPrunesSuccessSuppressionForReusedIdentity() async {
        let fixture = EngineFixture()
        fixture.hardware.ownedObjectValues = [ownedAggregate(id: 60)]
        _ = await fixture.engine.cleanupOrphans()

        fixture.hardware.ownedObjectValues = []
        _ = await fixture.engine.cleanupOrphans()

        fixture.hardware.ownedObjectValues = [ownedAggregate(id: 60)]
        fixture.hardware.clearCalls()
        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .ownedObjects,
            .destroyOwnedObject(object: ownedAggregate(id: 60)),
        ])
    }

    @available(macOS 14.2, *)
    func testReenumeratedOwnedIdentityAtNewObjectIDReplacesStaleRetry() async {
        let fixture = EngineFixture()
        fixture.hardware.ownedObjectValues = [ownedAggregate(id: 70)]
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyOwnedObject(70)
        )
        _ = await fixture.engine.cleanupOrphans()

        fixture.hardware.ownedObjectValues = [ownedAggregate(id: 71)]
        fixture.hardware.clearCalls()
        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .ownedObjects,
            .destroyOwnedObject(object: ownedAggregate(id: 71)),
        ])

        fixture.hardware.clearCalls()
        _ = await fixture.engine.cleanupOrphans()
        XCTAssertEqual(fixture.hardware.calls, [.ownedObjects])
    }

    @available(macOS 14.2, *)
    func testSuccessfulOldObjectRetryDoesNotSuppressNewObjectIDWithSameIdentity() async {
        let fixture = EngineFixture()
        fixture.hardware.ownedObjectValues = [ownedAggregate(id: 80)]
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyOwnedObject(80)
        )
        _ = await fixture.engine.cleanupOrphans()

        fixture.hardware.ownedObjectValues = [ownedAggregate(id: 81)]
        fixture.hardware.clearCalls()
        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .ownedObjects,
            .destroyOwnedObject(object: ownedAggregate(id: 81)),
        ])
    }

    @available(macOS 14.2, *)
    func testSameObjectIDWithDifferentOwnedUIDNeverRunsStaleRetry() async {
        let fixture = EngineFixture()
        fixture.hardware.ownedObjectValues = [ownedAggregate(id: 90)]
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyOwnedObject(90)
        )
        _ = await fixture.engine.cleanupOrphans()

        let replacement = AudioOwnedObject(
            id: 90,
            classID: kAudioAggregateDeviceClassID,
            uid: AudioRoutePlanner.aggregateUIDPrefix + "replacement",
            name: "Replacement aggregate"
        )
        fixture.hardware.ownedObjectValues = [replacement]
        fixture.hardware.clearCalls()
        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .ownedObjects,
            .destroyOwnedObject(object: replacement),
        ])
    }

    @available(macOS 14.2, *)
    func testOwnedRetryAndFreshDiscoveryStillDestroyAggregatesBeforeTaps() async {
        let fixture = EngineFixture()
        fixture.hardware.ownedObjectValues = [ownedTap(id: 100)]
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyOwnedObject(100)
        )
        _ = await fixture.engine.cleanupOrphans()

        fixture.hardware.ownedObjectValues = [
            ownedTap(id: 100),
            ownedAggregate(id: 50),
        ]
        fixture.hardware.clearCalls()
        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .ownedObjects,
            .destroyOwnedObject(object: ownedAggregate(id: 50)),
            .destroyOwnedObject(object: ownedTap(id: 100)),
        ])
    }

    @available(macOS 14.2, *)
    func testFreshScanDoesNotDuplicateNormalAggregateDestroyRetry() async {
        let fixture = EngineFixture()
        let plan = fixture.plan(generation: 1)
        _ = await fixture.engine.apply(plan: plan, gain: ProcessGainState())
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyAggregate
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyOwnedObject(2_000)
        )
        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)
        fixture.hardware.ownedObjectValues = [
            AudioOwnedObject(
                id: 2_000,
                classID: kAudioAggregateDeviceClassID,
                uid: plan.aggregateUID,
                name: "Pending aggregate"
            ),
        ]
        fixture.hardware.clearCalls()

        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertEqual(fixture.hardware.calls, [
            .destroyAggregate,
            .ownedObjects,
        ])
        XCTAssertEqual(failures, [
            AudioTeardownFailure(
                processObjectID: 77,
                operation: .destroyAggregate,
                objectID: 2_000,
                status: kAudioHardwareUnspecifiedError
            ),
        ])
    }

    @available(macOS 14.2, *)
    func testSuccessfulNormalTeardownSuppressesAsynchronouslyEnumeratedObjects() async throws {
        let fixture = EngineFixture()
        let plan = fixture.plan(generation: 1)
        _ = await fixture.engine.apply(plan: plan, gain: ProcessGainState())
        let tap = try XCTUnwrap(fixture.hardware.createdTapResources.last)

        let stopped = await fixture.engine.stop(
            processObjectID: plan.processObjectID,
            generation: plan.generation
        )
        XCTAssertEqual(stopped.state, .idle)
        fixture.hardware.ownedObjectValues = [
            AudioOwnedObject(
                id: 2_000,
                classID: kAudioAggregateDeviceClassID,
                uid: plan.aggregateUID,
                name: "Asynchronously enumerated aggregate"
            ),
            AudioOwnedObject(
                id: tap.objectID,
                classID: kAudioTapClassID,
                uid: tap.uuid.uuidString,
                name: "Asynchronously enumerated tap"
            ),
        ]
        fixture.hardware.clearCalls()

        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [.ownedObjects])
    }

    @available(macOS 14.2, *)
    func testLateCleanupNeverTreatsActiveSessionObjectIDsAsStartupOrphans() async {
        let fixture = EngineFixture()
        let plan = fixture.plan(generation: 1)
        let running = await fixture.engine.apply(
            plan: plan,
            gain: ProcessGainState()
        )
        XCTAssertEqual(running.state, .running)
        fixture.hardware.ownedObjectValues = [
            ownedTap(id: 1_000),
            AudioOwnedObject(
                id: 2_000,
                classID: kAudioAggregateDeviceClassID,
                uid: plan.aggregateUID,
                name: "Active aggregate"
            ),
            ownedTap(id: 3_000),
        ]
        fixture.hardware.clearCalls()

        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .ownedObjects,
            .destroyOwnedObject(object: ownedTap(id: 3_000)),
        ])
        await fixture.engine.stopAll()
    }

    @available(macOS 14.2, *)
    func testCleanupRetiresStartupRetryWhoseObjectIDIsNowAnActiveSessionResource() async {
        let fixture = EngineFixture()
        fixture.hardware.ownedObjectValues = [ownedAggregate(id: 2_000)]
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyOwnedObject(2_000)
        )
        _ = await fixture.engine.cleanupOrphans()

        fixture.hardware.forcedAggregateObjectID = 2_000
        let running = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        XCTAssertEqual(running.state, .running)
        fixture.hardware.setPersistentStatus(nil, at: .destroyOwnedObject(2_000))
        fixture.hardware.clearCalls()

        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [.ownedObjects])
        await fixture.engine.stopAll()
    }

    @available(macOS 14.2, *)
    func testRetainedAcquisitionFailsClosedForSameRouteReuse() async {
        let fixture = EngineFixture()
        fixture.hardware.forcedTapObjectID = 1_400
        fixture.hardware.forcedAggregateObjectID = 2_400
        let plan = fixture.plan(generation: 1)
        _ = await fixture.engine.apply(plan: plan, gain: ProcessGainState())

        for point: FakeAudioTapHardware.FailurePoint in [
            .stopDevice,
            .destroyIOProc,
            .destroyAggregate,
            .destroyTap(0),
        ] {
            fixture.hardware.setPersistentStatus(
                kAudioHardwareUnspecifiedError,
                at: point
            )
        }
        let stopped = await fixture.engine.stop(
            processObjectID: plan.processObjectID,
            generation: plan.generation
        )
        XCTAssertEqual(stopped.state, .failed)

        let replacement = await fixture.engine.apply(
            plan: plan,
            gain: ProcessGainState()
        )
        XCTAssertEqual(replacement.error, .cleanupBacklogFull)
        for point: FakeAudioTapHardware.FailurePoint in [
            .stopDevice,
            .destroyIOProc,
            .destroyAggregate,
            .destroyTap(0),
        ] {
            fixture.hardware.setPersistentStatus(nil, at: point)
        }
        fixture.hardware.clearCalls()

        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .destroyIOProc,
            .destroyAggregate,
            .ownedObjects,
            .destroyTap(sourceIndex: 0),
            .ownedObjects,
        ])
        await fixture.engine.stopAll()
    }

    func testOwnedObjectDiscoveryFailureReturnsTruthfulTypedFailure() async {
        let fixture = EngineFixture()
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .ownedObjects
        )

        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertEqual(failures, [
            AudioTeardownFailure(
                processObjectID: nil,
                operation: .getData,
                objectID: AudioObjectID(kAudioObjectSystemObject),
                status: kAudioHardwareUnspecifiedError
            ),
        ])
        XCTAssertEqual(fixture.hardware.calls, [.ownedObjects])
    }

    func testRetryLedgerAtCapacityRejectsPreparationWithoutDroppingFailure() async {
        let fixture = EngineFixture(retryLedgerLimit: 1)
        _ = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 77, generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyTap(0)
        )
        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)
        fixture.hardware.clearCalls()

        let rejected = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 88, generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(rejected.error, .cleanupBacklogFull)
        XCTAssertEqual(fixture.hardware.calls, [.destroyTap(sourceIndex: 0)])
        let remaining = await fixture.engine.cleanupOrphans()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.operation, .destroyTap)
    }

    func testStartFailureNeverStopsUnstartedIOProc() async {
        let fixture = EngineFixture()
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .startDevice
        )

        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertFalse(fixture.hardware.calls.contains(.stopDevice))
        XCTAssertTrue(fixture.hardware.calls.contains(.destroyIOProc))
    }

    func testDestroyIOProcSuccessRetiresFailedStop() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .stopDevice
        )

        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)
        fixture.hardware.clearCalls()
        let remaining = await fixture.engine.cleanupOrphans()

        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(fixture.hardware.calls.contains(.stopDevice))
        XCTAssertNil(fixture.hardware.lastContext)
    }

    func testDestroyIOProcFailureRetainsParentTapAndContext() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        let weakContext = WeakReference(fixture.hardware.lastContext)
        XCTAssertNotNil(weakContext.value)
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc
        )
        fixture.hardware.clearCalls()

        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)

        XCTAssertFalse(fixture.hardware.calls.contains(.destroyAggregate))
        XCTAssertFalse(
            fixture.hardware.calls.contains(.destroyTap(sourceIndex: 0))
        )
        XCTAssertNotNil(weakContext.value)
    }

    func testAggregateIdentityReadFailureRetainsTapUntilDisappearanceIsConfirmed() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.ownedDiscoveryFailures = [
            AudioTeardownFailure(
                processObjectID: nil,
                operation: .getData,
                objectID: 2_000,
                status: kAudioHardwareUnspecifiedError
            ),
        ]
        fixture.hardware.clearCalls()

        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)

        XCTAssertFalse(
            fixture.hardware.calls.contains(.destroyTap(sourceIndex: 0))
        )
        let remaining = await fixture.engine.cleanupOrphans()
        XCTAssertEqual(remaining.first?.operation, .getData)

        fixture.hardware.ownedDiscoveryFailures = []
        let released = await fixture.engine.cleanupOrphans()
        XCTAssertTrue(released.isEmpty)
        XCTAssertTrue(fixture.hardware.liveOwnedObjects.isEmpty)
    }

    func testSuccessfulIOProcDestroyReleasesBundleContext() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        let weakContext = WeakReference(fixture.hardware.lastContext)
        XCTAssertNotNil(weakContext.value)

        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)

        XCTAssertNil(weakContext.value)
    }

    func testAcquisitionCapacityCountsPreparingActiveAndRetainedExactlyOnce() async {
        let fixture = EngineFixture(retryLedgerLimit: 2)
        _ = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 1, generation: 1),
            gain: ProcessGainState()
        )
        _ = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 2, generation: 1),
            gain: ProcessGainState()
        )

        let rejected = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 3, generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(rejected.error, .cleanupBacklogFull)
    }

    func testRebuildFailsClosedUntilOldAcquisitionIsReleased() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc
        )
        fixture.hardware.clearCalls()

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 2),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .cleanupBacklogFull)
        XCTAssertFalse(
            fixture.hardware.calls.contains(
                .createTap(sourceIndex: 0, initiallyMuted: false)
            )
        )
    }

    func testTopologyFailureReleasesEveryPartialResource() async {
        let fixture = EngineFixture()
        fixture.hardware.aggregateTopologyError = .unsupportedTopology

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .unsupportedFormat)
        XCTAssertEqual(fixture.hardware.currentMuteState, .unmuted)
        XCTAssertNil(fixture.hardware.lastContext)
        XCTAssertTrue(fixture.hardware.liveOwnedObjects.isEmpty)
        XCTAssertEqual(Array(fixture.hardware.calls.suffix(3)), [
            .destroyAggregate,
            .ownedObjects,
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testMacOS141GateReturnsBeforeAnyHALCall() async {
        let fixture = EngineFixture(macOS: (14, 1))

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .processTapsUnavailable)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
    }

    func testStopAllTearsDownEveryObjectIDSession() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 41, generation: 1),
            gain: ProcessGainState()
        )
        _ = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 42, generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.clearCalls()

        await fixture.engine.stopAll()

        XCTAssertEqual(fixture.hardware.calls.filter { $0 == .stopDevice }.count, 2)
        XCTAssertEqual(fixture.hardware.calls.filter { $0 == .destroyIOProc }.count, 2)
        XCTAssertEqual(fixture.hardware.calls.filter { $0 == .destroyAggregate }.count, 2)
        XCTAssertEqual(
            fixture.hardware.calls.filter { $0 == .destroyTap(sourceIndex: 0) }.count,
            2
        )
    }

    func testActiveIOProcLeaseOutlivesOrdinaryOwnerUntilStopAll() async throws {
        let hardware = FakeAudioTapHardware()
        let plan = EngineFixture().plan(generation: 1)
        var owner: EngineOwner? = EngineOwner(
            engine: makeInjectedEngine(hardware: hardware)
        )
        let weakEngine = WeakReference(owner?.engine)

        let snapshot = await owner?.engine.apply(
            plan: plan,
            gain: ProcessGainState()
        )
        XCTAssertEqual(snapshot?.state, .running)
        let weakContext = WeakReference(hardware.lastContext)

        owner = nil
        await Task.yield()

        XCTAssertNotNil(weakEngine.value)
        XCTAssertNotNil(weakContext.value)
        var leasedEngine: ProcessTapVolumeEngine? = try XCTUnwrap(
            weakEngine.value
        )
        await leasedEngine?.stopAll()
        leasedEngine = nil
        await waitForDeallocation { weakEngine.value == nil }

        XCTAssertNil(weakEngine.value)
        XCTAssertNil(weakContext.value)
    }

    func testFailedIOProcDestroyLeaseSurvivesUntilSuccessfulCleanup() async throws {
        let hardware = FakeAudioTapHardware()
        let plan = EngineFixture().plan(generation: 1)
        var owner: EngineOwner? = EngineOwner(
            engine: makeInjectedEngine(hardware: hardware)
        )
        let weakEngine = WeakReference(owner?.engine)

        _ = await owner?.engine.apply(
            plan: plan,
            gain: ProcessGainState()
        )
        let weakContext = WeakReference(hardware.lastContext)
        hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc
        )
        owner = nil

        var leasedEngine: ProcessTapVolumeEngine? = try XCTUnwrap(
            weakEngine.value
        )
        await leasedEngine?.stopAll()
        leasedEngine = nil
        await Task.yield()

        XCTAssertNotNil(weakEngine.value)
        XCTAssertNotNil(weakContext.value)

        hardware.setPersistentStatus(nil, at: .destroyIOProc)
        var retryingEngine: ProcessTapVolumeEngine? = try XCTUnwrap(
            weakEngine.value
        )
        let remaining = (await retryingEngine?.cleanupOrphans()) ?? []
        XCTAssertTrue(remaining.isEmpty)
        retryingEngine = nil
        await waitForDeallocation { weakEngine.value == nil }

        XCTAssertNil(weakEngine.value)
        XCTAssertNil(weakContext.value)
    }

    func testReusedAggregateObjectIDRetiresOldIOProcRetryAndKeepsLatestContext() async throws {
        let fixture = EngineFixture(retryLedgerLimit: 4)
        fixture.hardware.forcedAggregateObjectID = 2_400

        _ = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 77, generation: 1),
            gain: ProcessGainState()
        )
        let firstIOProcKey = try XCTUnwrap(
            fixture.hardware.createdIOProcKeys.last
        )
        var firstContext: ProcessTapDSPContext? = try XCTUnwrap(
            fixture.hardware.lastContext
        )
        let weakFirstContext = WeakReference(firstContext)
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc,
            ioProcKey: firstIOProcKey
        )
        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)
        firstContext = nil

        _ = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 88, generation: 1),
            gain: ProcessGainState()
        )
        let secondIOProcKey = try XCTUnwrap(
            fixture.hardware.createdIOProcKeys.last
        )
        XCTAssertNotEqual(firstIOProcKey, secondIOProcKey)
        var secondContext: ProcessTapDSPContext? = try XCTUnwrap(
            fixture.hardware.lastContext
        )
        let weakSecondContext = WeakReference(secondContext)
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc,
            ioProcKey: secondIOProcKey
        )
        _ = await fixture.engine.stop(processObjectID: 88, generation: 1)
        secondContext = nil

        await waitForDeallocation { weakFirstContext.value == nil }
        XCTAssertNil(weakFirstContext.value)
        XCTAssertNotNil(weakSecondContext.value)

        fixture.hardware.setPersistentStatus(
            nil,
            at: .destroyIOProc,
            ioProcKey: firstIOProcKey
        )
        let firstCleanup = await fixture.engine.cleanupOrphans()
        await waitForDeallocation { weakFirstContext.value == nil }

        XCTAssertEqual(firstCleanup.count, 1)
        XCTAssertNil(weakFirstContext.value)
        XCTAssertNotNil(weakSecondContext.value)

        fixture.hardware.setPersistentStatus(
            nil,
            at: .destroyIOProc,
            ioProcKey: secondIOProcKey
        )
        let finalCleanup = await fixture.engine.cleanupOrphans()
        await waitForDeallocation { weakSecondContext.value == nil }

        XCTAssertTrue(finalCleanup.isEmpty)
        XCTAssertNil(weakSecondContext.value)
    }

    func testAcquisitionCapacityDoesNotCountReleasedReusedObjectIDBundles() async throws {
        let fixture = EngineFixture(retryLedgerLimit: 2)
        fixture.hardware.forcedAggregateObjectID = 2_400

        for processObjectID: AudioObjectID in [77, 88] {
            _ = await fixture.engine.apply(
                plan: fixture.plan(
                    processObjectID: processObjectID,
                    generation: 1
                ),
                gain: ProcessGainState()
            )
            let ioProcKey = try XCTUnwrap(
                fixture.hardware.createdIOProcKeys.last
            )
            fixture.hardware.setPersistentStatus(
                kAudioHardwareUnspecifiedError,
                at: .destroyIOProc,
                ioProcKey: ioProcKey
            )
            _ = await fixture.engine.stop(
                processObjectID: processObjectID,
                generation: 1
            )
        }

        let replacement = await fixture.engine.apply(
            plan: fixture.plan(processObjectID: 99, generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(replacement.state, .running)
        XCTAssertEqual(fixture.hardware.createdIOProcKeys.count, 3)

        for ioProcKey in fixture.hardware.createdIOProcKeys {
            fixture.hardware.setPersistentStatus(
                nil,
                at: .destroyIOProc,
                ioProcKey: ioProcKey
            )
        }
        await fixture.engine.stopAll()
        _ = await fixture.engine.cleanupOrphans()
    }

    func testBundleFailuresRemainAcquisitionScoped() async {
        let fixture = EngineFixture()
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyTap(0)
        )
        let processObjectIDs = (200..<205).map(AudioObjectID.init)

        for processObjectID in processObjectIDs {
            _ = await fixture.engine.apply(
                plan: fixture.plan(
                    processObjectID: processObjectID,
                    generation: 1
                ),
                gain: ProcessGainState()
            )
        }
        await fixture.engine.stopAll()
        let failures = await fixture.engine.cleanupOrphans()

        XCTAssertEqual(
            Set(failures.compactMap(\.processObjectID)),
            Set(processObjectIDs)
        )
        XCTAssertEqual(failures.count, processObjectIDs.count)
        XCTAssertTrue(failures.allSatisfy {
            $0.operation == .destroyTap
        })
    }

    func testLatestStopTearsDownOlderActiveSessionWhileApplyIsQueued() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.clearCalls()
        fixture.queue.suspend()

        let applying = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 2),
                gain: ProcessGainState(volume: 0.8)
            )
        }
        let applyRegistered = await waitUntilCondition {
            fixture.hardware.invokeLatestReadinessCancellationProbe() == true
        }
        XCTAssertTrue(applyRegistered)

        let stopping = Task {
            await fixture.engine.stop(
                processObjectID: 77,
                generation: 2
            )
        }
        for _ in 0..<100 {
            await Task.yield()
        }
        fixture.queue.resume()

        let applySnapshot = await applying.value
        let stopSnapshot = await stopping.value

        XCTAssertEqual(applySnapshot.error, .routeSuperseded)
        XCTAssertEqual(stopSnapshot.state, .idle)
        XCTAssertNil(stopSnapshot.error)
        XCTAssertEqual(fixture.hardware.calls, [
            .setTapUnmuted(sourceIndex: 0),
            .stopDevice,
            .destroyIOProc,
            .destroyAggregate,
            .ownedObjects,
            .destroyTap(sourceIndex: 0),
        ])
        await fixture.engine.stopAll()
    }

    func testSnapshotObserverRunsOutsideGenerationLock() async {
        let hardware = FakeAudioTapHardware()
        let result = GenerationLockProbeResult()
        let fixture = EngineFixture(
            hardware: hardware,
            onSessionSnapshot: { snapshot in
                guard snapshot.state == .running else { return }
                let finished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    result.recordProbe(
                        hardware.invokeLatestReadinessCancellationProbe()
                    )
                    finished.signal()
                }
                result.recordTimeout(
                    finished.wait(timeout: .now() + .milliseconds(200))
                        == .timedOut
                )
            }
        )

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.state, .running)
        XCTAssertFalse(result.didTimeOut)
        XCTAssertEqual(result.probeValue, false)
        await fixture.engine.stopAll()
    }

    func testCancellationDuringThrowingNativeCallReturnsRouteSuperseded() async {
        let fixture = EngineFixture()
        fixture.hardware.blockCalls(at: .createTap(1))
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .createTap(1)
        )
        let applying = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 1, sourceCount: 2),
                gain: ProcessGainState()
            )
        }
        await fixture.hardware.waitUntilBlocked(at: .createTap(1))

        applying.cancel()
        for _ in 0..<10 {
            await Task.yield()
        }
        fixture.hardware.releaseCalls(at: .createTap(1))
        let snapshot = await applying.value

        XCTAssertEqual(snapshot.error, .routeSuperseded)
        XCTAssertEqual(fixture.hardware.calls, [
            .createTap(sourceIndex: 0, initiallyMuted: false),
            .createTap(sourceIndex: 1, initiallyMuted: false),
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testSnapshotObserverDeallocationDoesNotCancelEngineWork() async {
        let hardware = FakeAudioTapHardware()
        let recorder = SnapshotRecorder()
        var observer: SnapshotObserver? = SnapshotObserver()
        let weakObserver = WeakReference(observer)
        let fixture = EngineFixture(
            hardware: hardware,
            onSessionSnapshot: { [weak observer] snapshot in
                observer?.record(snapshot)
                recorder.record(snapshot)
            }
        )
        observer = nil

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertNil(weakObserver.value)
        XCTAssertEqual(snapshot.state, .running)
        XCTAssertTrue(recorder.snapshots.contains { $0.state == .running })
    }

    func testProductionInitializerStaysUnavailableOnMacOS141WithoutTouchingSystemHardware() async {
        let engine = ProcessTapVolumeEngine(
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 1,
                    patchVersion: 0
                )
            )
        )
        let plan = EngineFixture().plan(generation: 1)

        let snapshot = await engine.apply(
            plan: plan,
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.error, .processTapsUnavailable)
    }
}

private let callsThroughTapFormat: [FakeAudioTapHardware.Call] = [
    .createTap(sourceIndex: 0, initiallyMuted: false),
    .readTapFormat(sourceIndex: 0),
]

@available(macOS 14.2, *)
private func ownedAggregate(id: AudioObjectID) -> AudioOwnedObject {
    AudioOwnedObject(
        id: id,
        classID: kAudioAggregateDeviceClassID,
        uid: AudioRoutePlanner.aggregateUIDPrefix + "owned",
        name: "Owned aggregate"
    )
}

@available(macOS 14.2, *)
private func ownedTap(id: AudioObjectID) -> AudioOwnedObject {
    AudioOwnedObject(
        id: id,
        classID: kAudioTapClassID,
        uid: "4D414341-0000-4000-8000-\(String(format: "%012X", id))",
        name: "Owned tap"
    )
}

private let callsThroughAggregate = callsThroughTapFormat + [
    FakeAudioTapHardware.Call.createAggregate(tapAutoStart: false),
]

private let callsThroughStableTopology = callsThroughAggregate + [
    FakeAudioTapHardware.Call.waitForAggregateReadiness,
]

private final class EngineFixture: @unchecked Sendable {
    let hardware: FakeAudioTapHardware
    let queue: DispatchQueue
    let engine: ProcessTapVolumeEngine
    let format = ProcessTapAudioFormat(
        sampleRate: 48_000,
        channelCount: 2,
        formatID: kAudioFormatLinearPCM,
        formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        bitsPerChannel: 32,
        interleaving: .interleaved
    )

    init(
        macOS: (major: Int, minor: Int) = (14, 2),
        readinessInitiallyBlocked: Bool = false,
        firstCallbackInitiallyBlocked: Bool = false,
        retryLedgerLimit: Int = 32,
        recorder: SnapshotRecorder? = nil,
        hardware: FakeAudioTapHardware = FakeAudioTapHardware(),
        queue: DispatchQueue? = nil,
        onSessionSnapshot: (@Sendable (ProcessTapSessionSnapshot) -> Void)? = nil
    ) {
        self.hardware = hardware
        let engineQueue = queue ?? DispatchQueue(
            label: "ProcessTapVolumeEngineTests.\(UUID().uuidString)"
        )
        self.queue = engineQueue
        hardware.readinessInitiallyBlocked = readinessInitiallyBlocked
        hardware.firstCallbackInitiallyBlocked = firstCallbackInitiallyBlocked
        let snapshotHandler = onSessionSnapshot ?? { snapshot in
            recorder?.record(snapshot)
        }
        engine = ProcessTapVolumeEngine(
            hardware: hardware,
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: macOS.major,
                    minorVersion: macOS.minor,
                    patchVersion: 0
                )
            ),
            queue: engineQueue,
            retryLedgerLimit: retryLedgerLimit,
            onSessionSnapshot: snapshotHandler
        )
    }

    func plan(
        processObjectID: AudioObjectID = 77,
        generation: UInt64,
        sourceCount: Int = 1,
        fingerprint: AudioRouteTopologyFingerprint? = nil
    ) -> AudioRoutePlan {
        AudioRoutePlan(
            processObjectID: processObjectID,
            generation: generation,
            tapSources: (0..<sourceCount).map { index in
                AudioTapSource(
                    deviceUID: "source-\(index)",
                    streamIndex: UInt(index),
                    expectedFormat: format,
                    driftCompensation: .disabled
                )
            },
            selectedTargetUIDs: ["output"],
            subdevices: [
                AudioRouteSubdevice(
                    uid: "output",
                    driftCompensation: .disabled,
                    inputStreams: [],
                    outputStreams: [
                        AudioRouteStream(
                            streamObjectID: 1_000,
                            streamIndex: 0,
                            format: format
                        ),
                    ]
                ),
            ],
            mainDeviceUID: "output",
            isStacked: true,
            aggregateUID: AudioRoutePlanner.aggregateUIDPrefix
                + "\(processObjectID).\(generation)",
            topologyFingerprint: fingerprint ?? AudioRouteTopologyFingerprint(
                osBuild: "25A123",
                sourceDeviceUIDs: ["source-0"],
                selectedTargetUIDs: ["output"],
                devices: []
            )
        )
    }
}

private final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProcessTapSessionSnapshot] = []

    var snapshots: [ProcessTapSessionSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ snapshot: ProcessTapSessionSnapshot) {
        lock.lock()
        values.append(snapshot)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        values.removeAll()
        lock.unlock()
    }
}

private final class SnapshotObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ProcessTapSessionSnapshot] = []

    func record(_ snapshot: ProcessTapSessionSnapshot) {
        lock.lock()
        snapshots.append(snapshot)
        lock.unlock()
    }
}

private final class EngineOwner: @unchecked Sendable {
    let engine: ProcessTapVolumeEngine

    init(engine: ProcessTapVolumeEngine) {
        self.engine = engine
    }
}

private final class GenerationLockProbeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var timeoutStorage = false
    private var probeValueStorage: Bool?

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timeoutStorage
    }

    var probeValue: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return probeValueStorage
    }

    func recordTimeout(_ didTimeOut: Bool) {
        lock.lock()
        timeoutStorage = didTimeOut
        lock.unlock()
    }

    func recordProbe(_ value: Bool?) {
        lock.lock()
        probeValueStorage = value
        lock.unlock()
    }
}

private final class WeakReference<Object: AnyObject>: @unchecked Sendable {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}

private func makeInjectedEngine(
    hardware: FakeAudioTapHardware
) -> ProcessTapVolumeEngine {
    ProcessTapVolumeEngine(
        hardware: hardware,
        availability: AudioFeatureAvailability(
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            )
        ),
        queue: DispatchQueue(
            label: "ProcessTapVolumeEngineTests.lease.\(UUID().uuidString)"
        )
    )
}

private func waitForDeallocation(
    _ condition: @escaping @Sendable () -> Bool
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
}

private func waitUntilCondition(
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func XCTAssertEqualFloatArrays(
    _ expression1: @autoclosure () throws -> [Float32],
    _ expression2: @autoclosure () throws -> [Float32],
    accuracy: Float32,
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    let lhs = try expression1()
    let rhs = try expression2()
    XCTAssertTrue(
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            abs($0 - $1) <= accuracy
        },
        "\(lhs) is not equal to \(rhs) +/- \(accuracy)",
        file: file,
        line: line
    )
}
