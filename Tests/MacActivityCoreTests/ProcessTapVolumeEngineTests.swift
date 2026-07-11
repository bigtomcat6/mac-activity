import CoreAudio
import Foundation
import XCTest

@testable import MacActivityCore

final class ProcessTapVolumeEngineTests: XCTestCase {
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
            .readAggregateLayout,
            .createIOProc,
            .startDevice,
            .waitForFirstCallback,
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

    func testLaterMuteFailureRestoresAlreadyMutedTapBeforeReverseTeardown() async {
        let fixture = EngineFixture()
        fixture.hardware.enqueueStatus(
            kAudioHardwareUnspecifiedError,
            at: .setTapMuted(1)
        )

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1, sourceCount: 2),
            gain: ProcessGainState(volume: 0.6)
        )

        XCTAssertEqual(
            snapshot.error,
            .operationFailed(
                operation: .setData,
                status: kAudioHardwareUnspecifiedError
            )
        )
        XCTAssertEqual(Array(fixture.hardware.calls.suffix(6)), [
            .setTapUnmuted(sourceIndex: 0),
            .stopDevice,
            .destroyIOProc,
            .destroyAggregate,
            .destroyTap(sourceIndex: 1),
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
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .readAggregateLayout,
                sourceCount: 1,
                expectedCalls: callsThroughAggregate + [
                    .waitForAggregateReadiness,
                    .readAggregateLayout,
                    .destroyAggregate,
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .createIOProc,
                sourceCount: 1,
                expectedCalls: callsThroughLayout + [
                    .createIOProc,
                    .destroyAggregate,
                    .destroyTap(sourceIndex: 0),
                ]
            ),
            Scenario(
                point: .startDevice,
                sourceCount: 1,
                expectedCalls: callsThroughLayout + [
                    .createIOProc,
                    .startDevice,
                    .stopDevice,
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
            .createTap(sourceIndex: 0, initiallyMuted: false),
            .readTapFormat(sourceIndex: 0),
            .destroyTap(sourceIndex: 0),
        ])
    }

    func testInvalidActualAggregateMappingFailsBeforeIOProcCreation() async {
        let fixture = EngineFixture()
        let format = fixture.format
        fixture.hardware.aggregateLayoutOverride = AudioAggregateLayout(
            inputFormats: [format],
            outputFormats: [format],
            channelMaps: [
                ProcessTapChannelMap(
                    input: ProcessTapChannelAddress(
                        bufferIndex: 0,
                        channelIndex: 2,
                        interleavedChannelCount: 2
                    ),
                    output: ProcessTapChannelAddress(
                        bufferIndex: 0,
                        channelIndex: 0,
                        interleavedChannelCount: 2
                    ),
                    mixCoefficient: 1
                ),
            ]
        )

        let snapshot = await fixture.engine.apply(
            plan: fixture.plan(generation: 1),
            gain: ProcessGainState()
        )

        XCTAssertEqual(snapshot.error, .unsupportedFormat)
        XCTAssertFalse(fixture.hardware.calls.contains(.createIOProc))
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

    func testTeardownInspectsEveryStatusAndReturnsAllRemainingFailures() async {
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
            .destroyAggregate,
            .destroyTap(sourceIndex: 0),
        ])
        let failures = await fixture.engine.cleanupOrphans()
        XCTAssertEqual(failures.count, 4)
        XCTAssertEqual(Set(failures.map(\.operation.rawValue)), Set([
            AudioHALOperation.stopDevice.rawValue,
            AudioHALOperation.destroyIOProc.rawValue,
            AudioHALOperation.destroyAggregate.rawValue,
            AudioHALOperation.destroyTap.rawValue,
        ]))
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

    func testDefaultInitializerKeepsAsyncPathFailClosedUntilHardwareExists() async {
        let engine = ProcessTapVolumeEngine()
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

private let callsThroughAggregate = callsThroughTapFormat + [
    FakeAudioTapHardware.Call.createAggregate(tapAutoStart: false),
]

private let callsThroughLayout = callsThroughAggregate + [
    FakeAudioTapHardware.Call.waitForAggregateReadiness,
    FakeAudioTapHardware.Call.readAggregateLayout,
]

private final class EngineFixture: @unchecked Sendable {
    let hardware: FakeAudioTapHardware
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
        onSessionSnapshot: (@Sendable (ProcessTapSessionSnapshot) -> Void)? = nil
    ) {
        self.hardware = hardware
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
            queue: DispatchQueue(
                label: "ProcessTapVolumeEngineTests.\(UUID().uuidString)"
            ),
            retryLedgerLimit: retryLedgerLimit,
            onSessionSnapshot: snapshotHandler
        )
    }

    func plan(
        processObjectID: AudioObjectID = 77,
        generation: UInt64,
        sourceCount: Int = 1
    ) -> AudioRoutePlan {
        AudioRoutePlan(
            processObjectID: processObjectID,
            generation: generation,
            tapSources: (0..<sourceCount).map { index in
                AudioTapSource(
                    deviceUID: "source-\(index)",
                    streamIndex: UInt(index),
                    expectedFormat: format
                )
            },
            selectedTargetUIDs: ["output"],
            subdevices: [
                AudioRouteSubdevice(
                    uid: "output",
                    usesDriftCompensation: false
                ),
            ],
            clockDeviceUID: "output",
            isStacked: true,
            aggregateUID: AudioRoutePlanner.aggregateUIDPrefix
                + "\(processObjectID).\(generation)"
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
