import CoreAudio
import Foundation
import XCTest

@testable import MacActivityCore

final class ProcessTapVolumeEngineTests: XCTestCase {
    func testContendingEngineDirectApplyFailsBeforeAnyHardwareCall() async {
        let broker = FakeAudioProcessOwnershipLeaseBroker()
        let ownerHardware = FakeAudioTapHardware()
        let contenderHardware = FakeAudioTapHardware()
        let owner = makeInjectedEngine(
            hardware: ownerHardware,
            leaseAcquirer: broker.acquirer(owner: "A")
        )
        let contender = makeInjectedEngine(
            hardware: contenderHardware,
            leaseAcquirer: broker.acquirer(owner: "B")
        )
        let plan = EngineFixture().plan(generation: 1)
        _ = await owner.apply(plan: plan, gain: ProcessGainState())
        contenderHardware.clearCalls()

        let result = await contender.apply(plan: plan, gain: ProcessGainState())

        XCTAssertEqual(result.error, .leaseUnavailable)
        XCTAssertTrue(contenderHardware.calls.isEmpty)
    }

    func testContendingEnginePrepareNeverTouchesHardware() async {
        let broker = FakeAudioProcessOwnershipLeaseBroker()
        let owner = makeInjectedEngine(
            hardware: FakeAudioTapHardware(),
            leaseAcquirer: broker.acquirer(owner: "A")
        )
        let contenderHardware = FakeAudioTapHardware()
        let contender = makeInjectedEngine(
            hardware: contenderHardware,
            leaseAcquirer: broker.acquirer(owner: "B")
        )
        _ = await owner.prepareRuntime()

        let preparation = await contender.prepareRuntime()
        XCTAssertEqual(preparation, .unavailable(.leaseUnavailable))
        XCTAssertTrue(contenderHardware.calls.isEmpty)
    }

    @available(macOS 14.2, *)
    func testPrepareRuntimeNeverEnumeratesOrDestroysPrefixLookingObjects() async {
        let fixture = EngineFixture()

        let preparation = await fixture.engine.prepareRuntime()

        XCTAssertEqual(preparation, .ready(cleanupFailures: []))
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
    }

    func testNonBusyLeaseFailureMapsToLeaseFailedBeforeHardware() async {
        let broker = FakeAudioProcessOwnershipLeaseBroker()
        broker.failNextAcquire(with: .system(operation: .openLockFile, code: EIO))
        let hardware = FakeAudioTapHardware()
        let engine = makeInjectedEngine(
            hardware: hardware,
            leaseAcquirer: broker.acquirer(owner: "A")
        )

        let result = await engine.apply(
            plan: EngineFixture().plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .leaseFailed)
        XCTAssertTrue(hardware.calls.isEmpty)
    }

    func testShutdownReleasesOwnerBeforeSuccessorCleanup() async {
        let broker = FakeAudioProcessOwnershipLeaseBroker()
        let owner = makeInjectedEngine(
            hardware: FakeAudioTapHardware(),
            leaseAcquirer: broker.acquirer(owner: "A")
        )
        let successorHardware = FakeAudioTapHardware()
        let successor = makeInjectedEngine(
            hardware: successorHardware,
            leaseAcquirer: broker.acquirer(owner: "B")
        )
        _ = await owner.apply(
            plan: EngineFixture().plan(generation: 1),
            gain: ProcessGainState()
        )

        await owner.shutdown()
        XCTAssertNil(broker.currentOwner)
        let preparation = await successor.prepareRuntime()
        XCTAssertEqual(preparation, .ready(cleanupFailures: []))
        XCTAssertTrue(successorHardware.calls.isEmpty)
    }

    func testShutdownRetainsLeaseUntilBundleDestroyRetryDrains() async {
        let broker = FakeAudioProcessOwnershipLeaseBroker()
        let scheduler = FakeProcessTapRetryScheduler()
        let ownerHardware = FakeAudioTapHardware()
        let owner = EngineFixture(
            hardware: ownerHardware,
            scheduler: scheduler,
            leaseAcquirer: broker.acquirer(owner: "A")
        )
        let contenderHardware = FakeAudioTapHardware()
        let contender = makeInjectedEngine(
            hardware: contenderHardware,
            leaseAcquirer: broker.acquirer(owner: "B")
        )
        _ = await owner.engine.apply(
            plan: owner.plan(generation: 1),
            gain: ProcessGainState()
        )
        ownerHardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc
        )

        await owner.engine.shutdown()
        let blocked = await contender.prepareRuntime()

        XCTAssertEqual(broker.currentOwner, "A")
        XCTAssertEqual(blocked, .unavailable(.leaseUnavailable))
        XCTAssertTrue(contenderHardware.calls.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 1)

        ownerHardware.setPersistentStatus(nil, at: .destroyIOProc)
        scheduler.runNext()
        await owner.engine.waitUntilIdleForTesting()
        let succeeded = await contender.prepareRuntime()

        XCTAssertEqual(succeeded, .ready(cleanupFailures: []))
        XCTAssertEqual(broker.currentOwner, "B")
    }


    func testStopAllTearsDownButRetainsOwnershipUntilShutdown() async {
        let broker = FakeAudioProcessOwnershipLeaseBroker()
        let owner = makeInjectedEngine(
            hardware: FakeAudioTapHardware(),
            leaseAcquirer: broker.acquirer(owner: "A")
        )
        let contenderHardware = FakeAudioTapHardware()
        let contender = makeInjectedEngine(
            hardware: contenderHardware,
            leaseAcquirer: broker.acquirer(owner: "B")
        )
        _ = await owner.apply(
            plan: EngineFixture().plan(generation: 1),
            gain: ProcessGainState()
        )

        await owner.stopAll()
        let blocked = await contender.prepareRuntime()

        XCTAssertEqual(broker.currentOwner, "A")
        XCTAssertEqual(blocked, .unavailable(.leaseUnavailable))
        XCTAssertTrue(contenderHardware.calls.isEmpty)

        await owner.shutdown()
        let succeeded = await contender.prepareRuntime()
        XCTAssertEqual(succeeded, .ready(cleanupFailures: []))
    }

    func testSimulatedCrashSuccessorIsNotReleasedByOldToken() async {
        let broker = FakeAudioProcessOwnershipLeaseBroker()
        let oldOwner = makeInjectedEngine(
            hardware: FakeAudioTapHardware(),
            leaseAcquirer: broker.acquirer(owner: "A")
        )
        let successor = makeInjectedEngine(
            hardware: FakeAudioTapHardware(),
            leaseAcquirer: broker.acquirer(owner: "B")
        )
        _ = await oldOwner.prepareRuntime()
        broker.simulateProcessDeath(owner: "A")
        let succeeded = await successor.prepareRuntime()

        await oldOwner.shutdown()

        XCTAssertEqual(succeeded, .ready(cleanupFailures: []))
        XCTAssertEqual(broker.currentOwner, "B")
        XCTAssertEqual(Array(broker.events.suffix(1)), [
            .acquired(owner: "B", leaseID: 2),
        ])
    }
    func testSessionSnapshotStreamFinishesWhenEngineDeinitializes() async {
        var engine: ProcessTapVolumeEngine? = makeInjectedEngine(
            hardware: FakeAudioTapHardware()
        )
        let snapshots = engine!.sessionSnapshots
        let finished = expectation(description: "snapshot stream finished")
        let consumer = Task {
            for await _ in snapshots {}
            finished.fulfill()
        }

        engine = nil

        await fulfillment(of: [finished], timeout: 1)
        consumer.cancel()
    }

    func testOneCommandEmitsStrictlyIncreasingOrdinals() async {
        let recorder = SnapshotRecorder()
        let fixture = EngineFixture(onSessionSnapshot: recorder.record)

        let terminal = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        let values = recorder.snapshots

        XCTAssertFalse(values.isEmpty)
        XCTAssertTrue(values.allSatisfy {
            $0.commandSequence == terminal.commandSequence
        })
        XCTAssertEqual(
            values.map(\.emissionOrdinal),
            Array(0..<UInt64(values.count))
        )
        XCTAssertEqual(values.last, terminal)
    }

    func testNewCommandGetsHigherSequenceEvenWithSameGeneration() async {
        let fixture = EngineFixture()

        let first = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        let second = await fixture.engine.stop(
            processObjectID: 77,
            generation: 1
        )

        XCTAssertGreaterThan(second.commandSequence, first.commandSequence)
    }

    func testSnapshotOrderIsLexicographic() {
        XCTAssertLessThan(
            ProcessTapSnapshotOrder(
                commandSequence: 1,
                emissionOrdinal: 9
            ),
            ProcessTapSnapshotOrder(
                commandSequence: 2,
                emissionOrdinal: 0
            )
        )
    }

    func testDiscardedPublishConsumesNoOrdinalAndDoesNotMutate() async {
        let recorder = SnapshotRecorder()
        let fixture = EngineFixture(onSessionSnapshot: recorder.record)
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        recorder.clear()
        fixture.hardware.clearCalls()
        await fixture.engine.supersedeNextSnapshotPublishForTesting(
            processObjectID: 77,
            generation: 2
        )

        let stale = await fixture.engine.stop(
            processObjectID: 77,
            generation: 1
        )

        XCTAssertEqual(stale.error, .routeSuperseded)
        XCTAssertEqual(stale.emissionOrdinal, 0)
        XCTAssertTrue(recorder.snapshots.isEmpty)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)

        let stopped = await fixture.engine.stop(
            processObjectID: 77,
            generation: 2
        )
        XCTAssertEqual(stopped.state, .idle)
    }

    func testLegacySnapshotInitializerUsesDeterministicOrder() {
        let snapshot = ProcessTapSessionSnapshot(
            processObjectID: 77,
            generation: 3,
            state: .failed,
            error: .routeSuperseded
        )

        XCTAssertEqual(snapshot.commandSequence, 0)
        XCTAssertEqual(snapshot.emissionOrdinal, 0)
        XCTAssertEqual(
            snapshot.order,
            ProcessTapSnapshotOrder(commandSequence: 0, emissionOrdinal: 0)
        )
    }

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
            .validateFreshRoutePlan,
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
        XCTAssertEqual(Array(fixture.hardware.calls.suffix(4)), [
            .stopDevice,
            .destroyIOProc,
            .destroyAggregate,
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testInitialMuteReadbackFailureAfterTapCreationTearsDownEveryOwnedResource() async {
        let fixture = EngineFixture()
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .readMuteState(0)
        )

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.6)
        )

        XCTAssertEqual(
            snapshot.error,
            .operationFailed(
                operation: .getData,
                status: kAudioHardwareUnspecifiedError
            )
        )
        XCTAssertTrue(fixture.hardware.liveOwnedObjects.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .validateFreshRoutePlan,
            .createTap(sourceIndex: 0, initiallyMuted: false),
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testUnexpectedInitialMuteStateAfterTapCreationUsesTypedFailureAndTeardown() async {
        let fixture = EngineFixture()
        fixture.hardware.enqueueMuteStateRead(
            .mutedWhenTapped,
            forSourceIndex: 0
        )

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.6)
        )

        XCTAssertEqual(
            snapshot.error,
            .operationFailed(
                operation: .getData,
                status: kAudioHardwareUnspecifiedError
            )
        )
        XCTAssertTrue(fixture.hardware.liveOwnedObjects.isEmpty)
    }

    func testUnexpectedMutedReadbackRetainsTapForRestoreThenTearsItDown() async {
        let fixture = EngineFixture()
        fixture.hardware.enqueueMuteStateRead(.unmuted, forSourceIndex: 0)
        fixture.hardware.enqueueMuteStateRead(.unmuted, forSourceIndex: 0)

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.6)
        )

        XCTAssertEqual(
            snapshot.error,
            .operationFailed(
                operation: .getData,
                status: kAudioHardwareUnspecifiedError
            )
        )
        XCTAssertTrue(fixture.hardware.liveOwnedObjects.isEmpty)
        XCTAssertEqual(Array(fixture.hardware.calls.suffix(6)), [
            .setTapMutedWhenTapped(sourceIndex: 0),
            .setTapUnmuted(sourceIndex: 0),
            .stopDevice,
            .destroyIOProc,
            .destroyAggregate,
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testRestoreReadbackFailureRetainsMutedTapUntilCleanupRetry() async {
        let fixture = EngineFixture()
        let running = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.6)
        )
        XCTAssertEqual(running.state, .running)

        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .readMuteState(0)
        )
        fixture.hardware.clearCalls()

        let firstStop = await fixture.engine.stop(
            processObjectID: 77,
            generation: 1
        )

        XCTAssertEqual(firstStop.state, .failed)
        XCTAssertEqual(
            firstStop.error,
            .operationFailed(
                operation: .setData,
                status: kAudioHardwareUnspecifiedError
            )
        )
        XCTAssertEqual(fixture.hardware.calls, [
            .setTapUnmuted(sourceIndex: 0),
        ])
        XCTAssertEqual(fixture.hardware.currentMuteState, .unmuted)
        XCTAssertEqual(
            fixture.hardware.liveOwnedObjects.filter {
                $0.classID == kAudioTapClassID
            }.count,
            1
        )

        fixture.hardware.clearCalls()
        let retryFailures = await retryRetainedBundles(fixture.engine)

        XCTAssertTrue(retryFailures.isEmpty)
        XCTAssertEqual(fixture.hardware.currentMuteState, .unmuted)
        XCTAssertTrue(fixture.hardware.liveOwnedObjects.isEmpty)
        XCTAssertEqual(
            fixture.hardware.calls.first,
            .setTapUnmuted(sourceIndex: 0)
        )
        XCTAssertTrue(
            fixture.hardware.calls.contains(.destroyTap(sourceIndex: 0))
        )
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
        XCTAssertEqual(Array(fixture.hardware.calls.suffix(4)), [
            .stopDevice,
            .destroyIOProc,
            .destroyAggregate,
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
                    .validateFreshRoutePlan,
                    .createTap(sourceIndex: 0, initiallyMuted: false),
                ]
            ),
            Scenario(
                point: .createTap(1),
                sourceCount: 2,
                expectedCalls: [
                    .validateFreshRoutePlan,
                    .createTap(sourceIndex: 0, initiallyMuted: false),
                    .createTap(sourceIndex: 1, initiallyMuted: false),
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .readTapFormat(1),
                sourceCount: 2,
                expectedCalls: [
                    .validateFreshRoutePlan,
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
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .createIOProc,
                sourceCount: 1,
                expectedCalls: callsThroughStableTopology + [
                    .createIOProc,
                    .destroyAggregate,
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
            .validateFreshRoutePlan,
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

    func testCancelledStableTopologyReportsSupersededAndTearsDownResources() async {
        let fixture = EngineFixture()
        fixture.hardware.stableTopologyFailure = .cancelled

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertEqual(snapshot.error, .routeSuperseded)
        XCTAssertTrue(fixture.hardware.liveOwnedObjects.isEmpty)
        XCTAssertEqual(
            fixture.hardware.calls,
            callsThroughStableTopology + [
                .destroyAggregate,
                .destroyTap(sourceIndex: 0),
            ]
        )
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
            leaseAcquirer: FakeAudioProcessOwnershipLeaseBroker()
                .acquirer(owner: "process-taps-unavailable"),
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                ),
                nativeValidationPolicy: .allowingAllForTesting
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
        _ = await retryRetainedBundles(fixture.engine)

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
        let failures = await retryRetainedBundles(fixture.engine)
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
        let remaining = await retryRetainedBundles(fixture.engine)
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
        XCTAssertEqual(fixture.hardware.calls.first, .validateFreshRoutePlan)
        XCTAssertEqual(
            fixture.hardware.calls.dropFirst().first,
            .destroyTap(sourceIndex: 0)
        )
        XCTAssertEqual(
            fixture.hardware.calls.dropFirst(2).first,
            .createTap(sourceIndex: 0, initiallyMuted: false)
        )
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

        let failures = await retryRetainedBundles(fixture.engine)

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fixture.hardware.calls, [
            .destroyIOProc,
            .destroyAggregate,
            .destroyTap(sourceIndex: 0),
        ])
        await fixture.engine.stopAll()
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
        XCTAssertEqual(fixture.hardware.calls, [
            .validateFreshRoutePlan,
            .destroyTap(sourceIndex: 0),
        ])
        let remaining = await retryRetainedBundles(fixture.engine)
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
        let remaining = await retryRetainedBundles(fixture.engine)

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
        XCTAssertEqual(Array(fixture.hardware.calls.suffix(2)), [
            .destroyAggregate,
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testAggregateTeardownWaitsForExactIdentityDisappearanceBeforeDestroyingTaps() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.deferAggregateDisappearance = true
        fixture.hardware.clearCalls()

        let stopped = await fixture.engine.stop(
            processObjectID: 77,
            generation: 1
        )

        XCTAssertEqual(stopped.state, .idle)
        XCTAssertEqual(fixture.hardware.aggregateIdentityProbeCount, 1)
        XCTAssertFalse(fixture.hardware.calls.contains(.destroyTap(sourceIndex: 0)))
        XCTAssertEqual(fixture.scheduler.pendingCount, 1)

        fixture.hardware.confirmAggregateDisappearance()
        fixture.scheduler.runNext()
        await fixture.engine.waitUntilIdleForTesting()

        XCTAssertEqual(fixture.hardware.aggregateIdentityProbeCount, 2)
        XCTAssertTrue(fixture.hardware.calls.contains(.destroyTap(sourceIndex: 0)))
        XCTAssertTrue(fixture.hardware.liveOwnedObjects.isEmpty)
    }

    func testAggregateIdentityReadFailureRetainsBundleBeforeDestroyingTaps() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .aggregateIdentityIsPresent
        )
        fixture.hardware.clearCalls()

        let stopped = await fixture.engine.stop(
            processObjectID: 77,
            generation: 1
        )

        XCTAssertEqual(
            stopped.error,
            .operationFailed(
                operation: .getData,
                status: kAudioHardwareUnspecifiedError
            )
        )
        XCTAssertEqual(fixture.hardware.aggregateIdentityProbeCount, 1)
        XCTAssertFalse(fixture.hardware.calls.contains(.destroyTap(sourceIndex: 0)))
        XCTAssertEqual(fixture.scheduler.pendingCount, 1)
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
        let remaining: [AudioTeardownFailure]
        if let retryingEngine {
            remaining = await retryRetainedBundles(retryingEngine)
        } else {
            remaining = []
        }
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
        let firstCleanup = await retryRetainedBundles(fixture.engine)
        await waitForDeallocation { weakFirstContext.value == nil }

        XCTAssertEqual(firstCleanup.count, 1)
        XCTAssertNil(weakFirstContext.value)
        XCTAssertNotNil(weakSecondContext.value)

        fixture.hardware.setPersistentStatus(
            nil,
            at: .destroyIOProc,
            ioProcKey: secondIOProcKey
        )
        let finalCleanup = await retryRetainedBundles(fixture.engine)
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
        _ = await retryRetainedBundles(fixture.engine)
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
        let failures = await retryRetainedBundles(fixture.engine)

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
            .validateFreshRoutePlan,
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
                ),
                nativeValidationPolicy: .allowingAllForTesting
            )
        )
        let plan = EngineFixture().plan(generation: 1)

        let snapshot = await engine.apply(
            plan: plan,
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.error, .processTapsUnavailable)
    }

    func testConservativeProductionPolicyRejectsMacOS142BeforeHardwareWork() async {
        let hardware = FakeAudioTapHardware()
        let engine = ProcessTapVolumeEngine(
            hardware: hardware,
            leaseAcquirer: FakeAudioProcessOwnershipLeaseBroker()
                .acquirer(owner: "conservative-policy"),
            availability: AudioFeatureAvailability(
                operatingSystemVersion: .init(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                ),
                nativeValidationPolicy: .conservative
            ),
            queue: DispatchQueue(
                label: "ProcessTapVolumeEngineTests.conservative-policy"
            )
        )

        let snapshot = await engine.apply(
            plan: EngineFixture().plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.error, .processTapsUnavailable)
        XCTAssertTrue(hardware.calls.isEmpty)
    }

    func testOnlyOneRetryPassCanBeScheduled() async {
        let fixture = EngineFixture()
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc
        )
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)
        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)

        XCTAssertEqual(fixture.scheduler.pendingCount, 1)
    }

    func testStaleTimerDoubleFireCannotRunConcurrentRetryPasses() async {
        let fixture = EngineFixture()
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyIOProc
        )
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)

        fixture.scheduler.fireCapturedActionTwice()
        await fixture.engine.waitUntilIdleForTesting()
        let maximumConcurrentPasses = await fixture.engine
            .maximumConcurrentRetryPassesForTesting()
        let retryPassCount = await fixture.engine.retryPassCountForTesting()

        XCTAssertEqual(maximumConcurrentPasses, 1)
        XCTAssertEqual(retryPassCount, 1)
    }







    func testRuntimeTopologyFailureRejectsSameFingerprintBeforeHAL() async {
        let fixture = EngineFixture()
        fixture.hardware.aggregateTopologyError = .unsupportedTopology
        let fingerprint = fixture.plan(generation: 1).topologyFingerprint
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, fingerprint: fingerprint),
            gain: ProcessGainState()
        )
        fixture.hardware.aggregateTopologyError = nil
        fixture.hardware.clearCalls()

        let result = await fixture.engine.apply(
            plan: fixture.plan(
                processObjectID: 88,
                generation: 9,
                fingerprint: fingerprint
            ),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .unsupportedFormat)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
        XCTAssertEqual(fixture.scheduler.pendingCount, 0)
    }

    func testRuntimeRejectionBlocksActiveSessionRebuildBeforeHAL() async {
        let fixture = EngineFixture()
        let fingerprint = fixture.plan(generation: 1).topologyFingerprint
        let active = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, fingerprint: fingerprint),
            gain: ProcessGainState()
        )
        XCTAssertEqual(active.state, .running)

        fixture.hardware.aggregateTopologyError = .unsupportedTopology
        let rejected = await fixture.engine.apply(
            plan: fixture.plan(
                processObjectID: 88,
                generation: 1,
                fingerprint: fingerprint
            ),
            gain: ProcessGainState()
        )
        XCTAssertEqual(rejected.error, .unsupportedFormat)

        fixture.hardware.aggregateTopologyError = nil
        fixture.hardware.clearCalls()
        let rebuild = await fixture.engine.apply(
            plan: fixture.plan(generation: 2, fingerprint: fingerprint),
            gain: ProcessGainState(volume: 0.2)
        )

        XCTAssertEqual(rebuild.error, .unsupportedFormat)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
        await fixture.engine.stopAll()
    }

    func testRuntimeRejectionDoesNotBlockSameGenerationActiveSessionUpdate() async throws {
        let fixture = EngineFixture()
        let fingerprint = fixture.plan(generation: 1).topologyFingerprint
        let first = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, fingerprint: fingerprint),
            gain: ProcessGainState(volume: 0.6)
        )
        let context = try XCTUnwrap(fixture.hardware.lastContext)
        XCTAssertEqual(first.state, .running)

        fixture.hardware.aggregateTopologyError = .unsupportedTopology
        let rejected = await fixture.engine.apply(
            plan: fixture.plan(
                processObjectID: 88,
                generation: 1,
                fingerprint: fingerprint
            ),
            gain: ProcessGainState()
        )
        XCTAssertEqual(rejected.error, .unsupportedFormat)

        fixture.hardware.aggregateTopologyError = nil
        fixture.hardware.clearCalls()
        let updated = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, fingerprint: fingerprint),
            gain: ProcessGainState(volume: 0.2)
        )

        XCTAssertEqual(updated.state, .running)
        XCTAssertNil(updated.error)
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

    func testStaleRouteFailsBeforeAnyHardwareMutation() async {
        let fixture = EngineFixture()
        fixture.hardware.routePlanFreshness = .stale

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .routeStale)
        XCTAssertEqual(fixture.hardware.calls, [.validateFreshRoutePlan])
    }

    func testStaleRebuildPreservesRunningSessionWithoutTeardown() async {
        let fixture = EngineFixture()
        let initialResult = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        XCTAssertEqual(initialResult.state, .running)
        fixture.hardware.clearCalls()
        fixture.hardware.routePlanFreshness = .stale

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 2),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .routeStale)
        XCTAssertEqual(fixture.hardware.calls, [.validateFreshRoutePlan])
    }

    func testInvalidActiveSessionBundleCannotBypassRuntimeRejection() async {
        let corruptions: [ProcessTapVolumeEngine.ActiveSessionCorruptionForTesting] = [
            .missingBundle,
            .releasedBundle,
            .mismatchedAcquisitionID,
            .mismatchedProcessObjectID,
            .missingContext,
        ]

        for corruption in corruptions {
            let fixture = EngineFixture()
            let fingerprint = fixture.plan(generation: 1).topologyFingerprint
            let active = await fixture.engine.apply(
                plan: fixture.plan(generation: 1, fingerprint: fingerprint),
                gain: ProcessGainState(volume: 0.6)
            )
            XCTAssertEqual(active.state, .running, "\(corruption)")

            fixture.hardware.aggregateTopologyError = .unsupportedTopology
            let rejected = await fixture.engine.apply(
                plan: fixture.plan(
                    processObjectID: 88,
                    generation: 1,
                    fingerprint: fingerprint
                ),
                gain: ProcessGainState()
            )
            XCTAssertEqual(rejected.error, .unsupportedFormat, "\(corruption)")

            await fixture.engine.corruptActiveSessionForTesting(
                processObjectID: 77,
                corruption: corruption
            )
            fixture.hardware.aggregateTopologyError = nil
            fixture.hardware.clearCalls()
            let result = await fixture.engine.apply(
                plan: fixture.plan(generation: 1, fingerprint: fingerprint),
                gain: ProcessGainState(volume: 0.2)
            )

            XCTAssertEqual(result.error, .unsupportedFormat, "\(corruption)")
            XCTAssertTrue(fixture.hardware.calls.isEmpty, "\(corruption)")
            await fixture.engine.stopAll()
        }
    }

    func testSupersessionImmediatelyBeforeActiveGainMutationReturnsSuperseded() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.6)
        )
        let context = try XCTUnwrap(fixture.hardware.lastContext)
        await fixture.engine.supersedeNextActiveSessionMutationForTesting(
            processObjectID: 77,
            generation: 2
        )
        fixture.hardware.clearCalls()

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.2)
        )

        XCTAssertEqual(result.error, .routeSuperseded)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
        let frameCount = 1_440
        let storage = AudioBufferListTestStorage.interleavedStereo(
            input: Array(repeating: 1, count: frameCount * 2),
            outputFrameCount: frameCount
        )
        storage.process(with: context)
        let lastSample = try XCTUnwrap(storage.outputSamples.last)
        XCTAssertEqual(lastSample, 0.6, accuracy: 0.000_001)
        await fixture.engine.stopAll()
    }

    func testEveryDeterministicRuntimeCompatibilityFailureIsCached() async {
        let streamUsageFailures: [AudioIOProcStreamUsageError] = [
            .propertyMissing,
            .propertyNotSettable,
            .writeFailed(-1),
            .byteCountMismatch,
            .ioProcMismatch,
            .streamCountMismatch,
            .flagsMismatch,
        ]

        for failure in streamUsageFailures {
            let fixture = EngineFixture()
            let fingerprint = fixture.plan(generation: 1).topologyFingerprint
            fixture.hardware.streamUsageError = failure
            _ = await fixture.engine.apply(
                plan: fixture.plan(generation: 1, fingerprint: fingerprint),
                gain: ProcessGainState()
            )
            fixture.hardware.streamUsageError = nil
            fixture.hardware.clearCalls()

            let rejected = await fixture.engine.apply(
                plan: fixture.plan(
                    processObjectID: 88,
                    generation: 2,
                    fingerprint: fingerprint
                ),
                gain: ProcessGainState()
            )

            XCTAssertEqual(rejected.error, .unsupportedFormat, "\(failure)")
            XCTAssertTrue(fixture.hardware.calls.isEmpty, "\(failure)")
        }
    }

    func testMismatchedVerifiedStreamUsageFailsBeforeStartingTheIOProc() async {
        let fixture = EngineFixture()
        fixture.hardware.configuredStreamUsageOverride = [0]

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertEqual(snapshot.error, .unsupportedFormat)
        XCTAssertFalse(fixture.hardware.calls.contains(.startDevice))
    }

    func testReadinessTimeoutIsNotCached() async {
        let fixture = EngineFixture()
        let fingerprint = fixture.plan(generation: 1).topologyFingerprint
        fixture.hardware.stableTopologyFailure = .aggregateNotReady(lastStatus: -1)
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, fingerprint: fingerprint),
            gain: ProcessGainState()
        )
        fixture.hardware.stableTopologyFailure = nil
        fixture.hardware.clearCalls()

        let retried = await fixture.engine.apply(
            plan: fixture.plan(
                processObjectID: 88,
                generation: 2,
                fingerprint: fingerprint
            ),
            gain: ProcessGainState()
        )

        XCTAssertEqual(retried.state, .running)
        XCTAssertFalse(fixture.hardware.calls.isEmpty)
    }

    func testTransientStreamUsageReadFailurePreservesStatusAndIsNotCached() async {
        let fixture = EngineFixture()
        let fingerprint = fixture.plan(generation: 1).topologyFingerprint
        fixture.hardware.streamUsageError = .readFailed(-321)

        let first = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, fingerprint: fingerprint),
            gain: ProcessGainState()
        )
        fixture.hardware.streamUsageError = nil
        fixture.hardware.clearCalls()
        let retried = await fixture.engine.apply(
            plan: fixture.plan(
                processObjectID: 88,
                generation: 2,
                fingerprint: fingerprint
            ),
            gain: ProcessGainState()
        )

        XCTAssertEqual(
            first.error,
            .operationFailed(operation: .getData, status: -321)
        )
        XCTAssertEqual(retried.state, .running)
        XCTAssertFalse(fixture.hardware.calls.isEmpty)
    }

    func testTransientStreamUsageSettableQueryFailurePreservesStatusAndIsNotCached() async {
        let fixture = EngineFixture()
        let fingerprint = fixture.plan(generation: 1).topologyFingerprint
        fixture.hardware.streamUsageHALError = AudioHALError(
            operation: .isSettable,
            objectID: 20_000,
            address: nil,
            reason: .status(-321)
        )

        let first = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, fingerprint: fingerprint),
            gain: ProcessGainState()
        )
        fixture.hardware.streamUsageHALError = nil
        fixture.hardware.clearCalls()
        let retried = await fixture.engine.apply(
            plan: fixture.plan(
                processObjectID: 88,
                generation: 2,
                fingerprint: fingerprint
            ),
            gain: ProcessGainState()
        )

        XCTAssertEqual(
            first.error,
            .operationFailed(operation: .isSettable, status: -321)
        )
        XCTAssertEqual(retried.state, .running)
        XCTAssertFalse(fixture.hardware.calls.isEmpty)
    }

    func testChangedFingerprintCanProbeAfterRuntimeRejection() async {
        let fixture = EngineFixture()
        fixture.hardware.aggregateTopologyError = .unsupportedTopology
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.aggregateTopologyError = nil
        fixture.hardware.clearCalls()
        let changedFingerprint = AudioRouteTopologyFingerprint(
            osBuild: "25A124",
            sourceDeviceUIDs: ["source-0"],
            selectedTargetUIDs: ["output"],
            devices: []
        )

        let reprobed = await fixture.engine.apply(
            plan: fixture.plan(
                processObjectID: 88,
                generation: 2,
                fingerprint: changedFingerprint
            ),
            gain: ProcessGainState()
        )

        XCTAssertEqual(reprobed.state, .running)
        XCTAssertFalse(fixture.hardware.calls.isEmpty)
    }

    func testUnsupportedRuntimeLifecycleOperationsDoNotTouchHardware() async {
        let fixture = EngineFixture(macOS: (14, 1))

        await fixture.engine.updateGain(
            ProcessGainState(volume: 0.2),
            for: 77
        )
        await fixture.engine.stopAll()
        let preparation = await fixture.engine.prepareRuntime()
        let stopped = await fixture.engine.stop(
            processObjectID: 77,
            generation: 1
        )
        await fixture.engine.shutdown()

        XCTAssertEqual(
            preparation,
            .unavailable(.processTapsUnavailable)
        )
        XCTAssertEqual(stopped.error, .processTapsUnavailable)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
    }

    func testMissingSessionCorruptionDoesNotAffectLaterApply() async {
        let fixture = EngineFixture()

        await fixture.engine.corruptActiveSessionForTesting(
            processObjectID: 77,
            corruption: .missingBundle
        )
        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.state, .running)
        XCTAssertNil(snapshot.error)
        await fixture.engine.stopAll()
    }

    func testActiveGainUpdatePublishSupersessionRetainsDSPGain() async throws {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.6)
        )
        let context = try XCTUnwrap(fixture.hardware.lastContext)
        await fixture.engine.supersedeNextSnapshotPublishForTesting(
            processObjectID: 77,
            generation: 2
        )
        fixture.hardware.clearCalls()

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState(volume: 0.2)
        )

        XCTAssertEqual(result.error, .routeSuperseded)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
        let frameCount = 1_440
        let storage = AudioBufferListTestStorage.interleavedStereo(
            input: Array(repeating: 1, count: frameCount * 2),
            outputFrameCount: frameCount
        )
        storage.process(with: context)
        let lastSample = try XCTUnwrap(storage.outputSamples.last)
        XCTAssertEqual(lastSample, 0.2, accuracy: 0.000_001)
        await fixture.engine.stopAll()
    }

    func testRebuildPublishSupersessionPreservesExistingSessionAfterFreshnessRead() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        await fixture.engine.supersedeNextSnapshotPublishForTesting(
            processObjectID: 77,
            generation: 3
        )
        fixture.hardware.clearCalls()

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 2),
            gain: ProcessGainState(volume: 0.2)
        )

        XCTAssertEqual(result.error, .routeSuperseded)
        XCTAssertEqual(fixture.hardware.calls, [.validateFreshRoutePlan])
        await fixture.engine.stopAll()
    }

    func testPreparingPublishSupersessionSkipsMutationAfterFreshnessRead() async {
        let fixture = EngineFixture()
        await fixture.engine.supersedeNextSnapshotPublishForTesting(
            processObjectID: 77,
            generation: 2
        )

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .routeSuperseded)
        XCTAssertEqual(fixture.hardware.calls, [.validateFreshRoutePlan])
        await fixture.engine.stopAll()
    }

    func testIdleStopPublishSupersessionReturnsSuperseded() async {
        let fixture = EngineFixture()
        await fixture.engine.supersedeNextSnapshotPublishForTesting(
            processObjectID: 77,
            generation: 2
        )

        let result = await fixture.engine.stop(
            processObjectID: 77,
            generation: 1
        )

        XCTAssertEqual(result.error, .routeSuperseded)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
        await fixture.engine.stopAll()
    }

    func testRetainedBundleAdvanceSupersededByNewApply() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyTap(0)
        )
        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)
        fixture.hardware.setPersistentStatus(nil, at: .destroyTap(0))
        fixture.hardware.blockCalls(at: .destroyTap(0))

        let applying = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 2),
                gain: ProcessGainState(volume: 0.2)
            )
        }
        await fixture.hardware.waitUntilBlocked(at: .destroyTap(0))
        let newest = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 3),
                gain: ProcessGainState(volume: 0.4)
            )
        }
        fixture.hardware.releaseCalls(at: .destroyTap(0))

        let stale = await applying.value
        let current = await newest.value

        XCTAssertEqual(stale.error, .routeSuperseded)
        XCTAssertEqual(current.state, .running)
        await fixture.engine.stopAll()
    }

    func testRebuildTeardownSupersededByNewApply() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.blockCalls(at: .destroyTap(0))

        let rebuilding = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 2),
                gain: ProcessGainState(volume: 0.2)
            )
        }
        await fixture.hardware.waitUntilBlocked(at: .destroyTap(0))
        let newest = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 3),
                gain: ProcessGainState(volume: 0.4)
            )
        }
        fixture.hardware.releaseCalls(at: .destroyTap(0))

        let stale = await rebuilding.value
        let current = await newest.value

        XCTAssertEqual(stale.error, .routeSuperseded)
        XCTAssertEqual(current.state, .running)
        await fixture.engine.stopAll()
    }

    func testStopAdvanceSupersededByNewApply() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyTap(0)
        )
        _ = await fixture.engine.stop(processObjectID: 77, generation: 1)
        fixture.hardware.setPersistentStatus(nil, at: .destroyTap(0))
        fixture.hardware.blockCalls(at: .destroyTap(0))

        let stopping = Task {
            await fixture.engine.stop(processObjectID: 77, generation: 2)
        }
        await fixture.hardware.waitUntilBlocked(at: .destroyTap(0))
        let newest = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 3),
                gain: ProcessGainState(volume: 0.4)
            )
        }
        fixture.hardware.releaseCalls(at: .destroyTap(0))

        let stale = await stopping.value
        let current = await newest.value

        XCTAssertEqual(stale.error, .routeSuperseded)
        XCTAssertEqual(current.state, .running)
        await fixture.engine.stopAll()
    }

    func testStopTeardownSupersededByNewApply() async {
        let fixture = EngineFixture()
        _ = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )
        fixture.hardware.blockCalls(at: .destroyTap(0))

        let stopping = Task {
            await fixture.engine.stop(processObjectID: 77, generation: 2)
        }
        await fixture.hardware.waitUntilBlocked(at: .destroyTap(0))
        let newest = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 3),
                gain: ProcessGainState(volume: 0.4)
            )
        }
        fixture.hardware.releaseCalls(at: .destroyTap(0))

        let stale = await stopping.value
        let current = await newest.value

        XCTAssertEqual(stale.error, .routeSuperseded)
        XCTAssertEqual(current.state, .running)
        await fixture.engine.stopAll()
    }

    func testEmptyTapSourcesFailBeforeHardwareCreation() async {
        let fixture = EngineFixture()

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, sourceCount: 0),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .unsupportedFormat)
        XCTAssertTrue(fixture.hardware.calls.isEmpty)
    }

    func testSustainedCallbackDeadlineReturnsAggregateNotReady() async {
        let fixture = EngineFixture()
        fixture.hardware.singleCallbackOnly = true

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(result.error, .aggregateNotReady)
        XCTAssertFalse(
            fixture.hardware.calls.contains(.setTapMutedWhenTapped(sourceIndex: 0))
        )
    }


    func testBundleFailureOrderingUsesObjectIDForSameOperation() async {
        let fixture = EngineFixture()
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyTap(0)
        )
        fixture.hardware.setPersistentStatus(
            kAudioHardwareUnspecifiedError,
            at: .destroyTap(1)
        )

        let result = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, sourceCount: 2),
            gain: ProcessGainState()
        )
        let failures = await retryRetainedBundles(fixture.engine)
        let destroyTapFailures = failures.filter {
            $0.operation == .destroyTap
        }

        XCTAssertEqual(result.error, .unsupportedFormat)
        XCTAssertEqual(destroyTapFailures.map(\.objectID), [1_000, 1_001])
    }


    func testCancellingSupersededApplyLeavesNewerGenerationCurrent() async {
        let fixture = EngineFixture(readinessInitiallyBlocked: true)
        let older = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 1),
                gain: ProcessGainState()
            )
        }
        await fixture.hardware.waitUntilReadinessPolling()

        let newer = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 2),
                gain: ProcessGainState(volume: 0.4)
            )
        }
        let didSupersede = await waitUntilCondition {
            fixture.hardware.invokeLatestReadinessCancellationProbe() == true
        }
        XCTAssertTrue(didSupersede)
        older.cancel()

        let oldResult = await older.value
        let newestResult = await newer.value

        XCTAssertEqual(oldResult.error, .routeSuperseded)
        XCTAssertEqual(newestResult.state, .running)
        await fixture.engine.stopAll()
    }

    func testStopAllInvalidatesInFlightApplyBeforeTeardown() async {
        let fixture = EngineFixture(readinessInitiallyBlocked: true)
        let applying = Task {
            await fixture.engine.apply(
                plan: fixture.plan(generation: 1),
                gain: ProcessGainState()
            )
        }
        await fixture.hardware.waitUntilReadinessPolling()

        let stopping = Task {
            await fixture.engine.stopAll()
        }
        let didInvalidate = await waitUntilCondition {
            fixture.hardware.invokeLatestReadinessCancellationProbe() == true
        }
        XCTAssertTrue(didInvalidate)

        let result = await applying.value
        await stopping.value

        XCTAssertEqual(result.error, .routeSuperseded)
    }
}

private let callsThroughTapFormat: [FakeAudioTapHardware.Call] = [
    .validateFreshRoutePlan,
    .createTap(sourceIndex: 0, initiallyMuted: false),
    .readTapFormat(sourceIndex: 0),
]

private func retryRetainedBundles(
    _ engine: ProcessTapVolumeEngine
) async -> [AudioTeardownFailure] {
    switch await engine.prepareRuntime() {
    case .ready(let failures):
        failures
    case .unavailable:
        []
    }
}

private func advanceRetryBackoffToOneSecond(_ fixture: EngineFixture) async {
    for _ in 0..<10 {
        if fixture.scheduler.scheduledDelays.last == .milliseconds(1_000) {
            break
        }
        fixture.scheduler.runNext()
        await fixture.engine.waitUntilIdleForTesting()
    }
    XCTAssertEqual(fixture.scheduler.scheduledDelays.last, .milliseconds(1_000))
    XCTAssertEqual(fixture.scheduler.pendingCount, 1)
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
    let scheduler: FakeProcessTapRetryScheduler
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
        scheduler: FakeProcessTapRetryScheduler = FakeProcessTapRetryScheduler(),
        leaseAcquirer: any AudioProcessOwnershipLeaseAcquiring =
            FakeAudioProcessOwnershipLeaseBroker().acquirer(owner: UUID().uuidString),
        queue: DispatchQueue? = nil,
        onSessionSnapshot: (@Sendable (ProcessTapSessionSnapshot) -> Void)? = nil
    ) {
        self.hardware = hardware
        self.scheduler = scheduler
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
            leaseAcquirer: leaseAcquirer,
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: macOS.major,
                    minorVersion: macOS.minor,
                    patchVersion: 0
                ),
                nativeValidationPolicy: .allowingAllForTesting
            ),
            queue: engineQueue,
            retryLedgerLimit: retryLedgerLimit,
            retryScheduler: scheduler,
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
            processIdentifier: 101,
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
    hardware: FakeAudioTapHardware,
    leaseAcquirer: any AudioProcessOwnershipLeaseAcquiring =
        FakeAudioProcessOwnershipLeaseBroker().acquirer(owner: UUID().uuidString)
) -> ProcessTapVolumeEngine {
    ProcessTapVolumeEngine(
        hardware: hardware,
        leaseAcquirer: leaseAcquirer,
        availability: AudioFeatureAvailability(
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 14,
                minorVersion: 2,
                patchVersion: 0
            ),
            nativeValidationPolicy: .allowingAllForTesting
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
