import CoreAudio
import Dispatch
import Foundation
import XCTest
@testable import MacActivityCore

final class AudioSystemAccessServiceTests: XCTestCase {
    func testSuccessfulNoOpProbeReportsOperationalAccess() async {
        let backend = FakeAudioHALBackend()
        backend.nextProcessTapID = 701
        backend.nextAggregateDeviceID = 702
        backend.nextIOProcID = audioAccessTestIOProcID
        backend.setArray(
            [AudioStreamID(703)],
            objectID: 702,
            address: .init(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeInput
            )
        )
        let service = AudioSystemAccessService(
            hal: AudioHALClient(backend: backend),
            isSupported: true,
            uuidProvider: { UUID(uuidString: "4D414341-0000-4000-8000-000000000001")! },
            pollInterval: 0
        )

        let result = await service.checkAccess()

        XCTAssertEqual(result, .available)
    }

    @available(macOS 14.2, *)
    func testProbeUsesPrivateUnmutedTapAndInputOnlyAggregate() async throws {
        let backend = configuredBackend()
        let service = makeService(backend)
        let result = await awaitResult(from: service)

        XCTAssertEqual(result, .available)

        let tap = try XCTUnwrap(backend.createdProcessTapDescriptions.first)
        XCTAssertTrue(tap.isPrivate)
        XCTAssertEqual(tap.muteBehavior, .unmuted)
        XCTAssertTrue(tap.uuid.uuidString.hasPrefix("4D414341-"))
        if #available(macOS 26.0, *) {
            XCTAssertFalse(tap.isProcessRestoreEnabled)
        }

        let aggregate = try XCTUnwrap(backend.createdAggregateDeviceDescriptions.first) as NSDictionary
        XCTAssertEqual(aggregate[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(aggregate[kAudioAggregateDeviceTapAutoStartKey] as? Bool, false)
        XCTAssertNil(aggregate[kAudioAggregateDeviceSubDeviceListKey])
        XCTAssertNil(aggregate[kAudioAggregateDeviceMainSubDeviceKey])
        let taps = try XCTUnwrap(aggregate[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps[0][kAudioSubTapUIDKey] as? String, tap.uuid.uuidString)
    }

    func testNoOpProbeCallbackDoesNotReadWriteOrForwardAudioBuffers() async throws {
        let backend = configuredBackend()
        let service = makeService(backend)
        let result = await awaitResult(from: service)

        XCTAssertEqual(result, .available)

        let callback = try XCTUnwrap(backend.ioProcCreations.first?.callback)
        var input: [Float32] = [0.25]
        var output: [Float32] = [9]

        XCTAssertEqual(
            invokeIOProc(callback, deviceID: 702, input: &input, output: &output),
            noErr
        )
        XCTAssertEqual(input, [0.25])
        XCTAssertEqual(output, [9])
    }

    func testUnsupportedSystemSkipsEveryMutableHALOperation() async {
        let backend = configuredBackend()
        let service = AudioSystemAccessService(
            hal: AudioHALClient(backend: backend),
            isSupported: false,
            uuidProvider: fixedProbeUUID,
            pollInterval: 0
        )
        let result = await awaitResult(from: service)

        XCTAssertEqual(result, .otherFailure(.unsupported))
        XCTAssertTrue(backend.mutableOperations.isEmpty)
    }

    func testStartPermissionStatusIsDistinctFromOtherHALFailures() async {
        let permissionBackend = configuredBackend()
        permissionBackend.startDeviceStatus = kAudioDevicePermissionsError
        let permissionResult = await awaitResult(from: makeService(permissionBackend))

        XCTAssertEqual(
            permissionResult,
            .permissionRequired(kAudioDevicePermissionsError)
        )

        let otherBackend = configuredBackend()
        otherBackend.startDeviceStatus = -777
        let otherResult = await awaitResult(from: makeService(otherBackend))

        XCTAssertEqual(
            otherResult,
            .otherFailure(.operationFailed(AudioHALError(
                operation: .startDevice,
                objectID: 702,
                address: nil,
                reason: .status(-777)
            )))
        )
    }

    func testGlobalProbeStartsWithoutAnAudibleProcess() async {
        let backend = configuredBackend()
        let result = await awaitResult(from: makeService(backend))

        XCTAssertEqual(result, .available)
        XCTAssertEqual(backend.createdProcessTapDescriptions.count, 1)
        XCTAssertEqual(backend.mutableOperations.filter { $0 == .startDevice }.count, 1)
    }

    func testPartialAcquisitionFailuresCleanUpOnlyResourcesAlreadyOwned() async {
        let cases: [(String, (FakeAudioHALBackend) -> Void, [AudioHALOperation])] = [
            (
                "tap",
                { $0.createProcessTapStatus = -101 },
                [.createTap]
            ),
            (
                "aggregate",
                { $0.createAggregateDeviceStatus = -102 },
                [.createTap, .createAggregate, .destroyTap]
            ),
            (
                "input topology",
                { backend in
                    backend.removeProperty(
                        objectID: 702,
                        address: .init(
                            selector: kAudioDevicePropertyStreams,
                            scope: kAudioObjectPropertyScopeInput
                        )
                    )
                },
                [.createTap, .createAggregate, .destroyAggregate, .destroyTap]
            ),
            (
                "IOProc",
                { $0.createIOProcStatus = -103 },
                [.createTap, .createAggregate, .createIOProc, .destroyAggregate, .destroyTap]
            ),
            (
                "start",
                { $0.startDeviceStatus = -104 },
                [
                    .createTap,
                    .createAggregate,
                    .createIOProc,
                    .startDevice,
                    .destroyIOProc,
                    .destroyAggregate,
                    .destroyTap,
                ]
            ),
        ]

        for (name, configure, expectedOperations) in cases {
            let backend = configuredBackend()
            configure(backend)
            let result = await awaitResult(from: makeService(backend, topologyPollCount: 1))

            guard case .otherFailure = result else {
                return XCTFail("\(name) must not report operational access")
            }
            XCTAssertEqual(backend.mutableOperations, expectedOperations, name)
        }
    }

    func testInputTopologyReadFailurePreservesItsHALFailure() async {
        let backend = configuredBackend()
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        )
        backend.setReadError(
            -120,
            objectID: 702,
            address: address,
            announcedByteCount: UInt32(MemoryLayout<AudioStreamID>.stride)
        )

        let result = await awaitResult(from: makeService(backend, topologyPollCount: 1))

        XCTAssertEqual(
            result,
            .otherFailure(.inputTopologyUnavailable(AudioHALError(
                operation: .getData,
                objectID: 702,
                address: address,
                reason: .status(-120)
            )))
        )
    }

    func testInputTopologyPermissionStatusReportsPermissionRequired() async {
        let backend = configuredBackend()
        backend.setReadError(
            kAudioDevicePermissionsError,
            objectID: 702,
            address: .init(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeInput
            ),
            announcedByteCount: UInt32(MemoryLayout<AudioStreamID>.stride)
        )

        let result = await awaitResult(from: makeService(backend, topologyPollCount: 1))

        XCTAssertEqual(result, .permissionRequired(kAudioDevicePermissionsError))
    }

    func testDelayedInputTopologyAndAggregateDestructionAreWaitedOut() async {
        let backend = configuredBackend()
        backend.removeProperty(
            objectID: 702,
            address: .init(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeInput
            )
        )
        backend.enqueueArrayRead(announced: [], returned: [AudioStreamID]())
        backend.enqueueArrayRead(announced: [AudioStreamID(703)], returned: [AudioStreamID(703)])
        backend.aggregateDestructionDelayPolls = 1
        let result = await awaitResult(
            from: makeService(backend, topologyPollCount: 2, cleanupPollCount: 2)
        )

        XCTAssertEqual(result, .available)
        XCTAssertEqual(backend.destroyedAggregateDeviceIDs, [702])
        XCTAssertGreaterThanOrEqual(
            backend.dataReadCount(for: kAudioDevicePropertyDeviceUID),
            2
        )
    }

    func testAggregateDisappearanceTimeoutReportsDestroyAggregateFailure() async {
        let backend = configuredBackend()
        backend.aggregateDestructionDelayPolls = 2
        let service = makeService(backend, cleanupPollCount: 1)

        let result = await awaitResult(from: service)

        guard case .otherFailure(.cleanupFailed(let failures)) = result else {
            return XCTFail("aggregate disappearance timeout must retain the probe for draining")
        }
        XCTAssertEqual(failures.map(\.operation), [.destroyAggregate])
        XCTAssertEqual(failures.map(\.objectID), [702])
        XCTAssertEqual(failures.map(\.status), [kAudioHardwareUnspecifiedError])

        await service.drainRetainedResources()
        XCTAssertTrue(backend.destroyedProcessTapIDs.isEmpty)
        await service.drainRetainedResources()

        XCTAssertEqual(backend.destroyedProcessTapIDs, [701])
    }

    func testCleanupFailureIsNotReportedAsOperationalAccessAndIsRetriedBeforeAnotherProbe() async {
        let backend = configuredBackend()
        backend.stopDeviceStatus = -105
        let service = makeService(backend)

        let firstResult = await awaitResult(from: service)

        guard case .otherFailure(.cleanupFailed(let failures)) = firstResult else {
            return XCTFail("cleanup failure must not report operational access")
        }
        XCTAssertEqual(failures.map(\.operation), [.stopDevice])
        XCTAssertEqual(backend.createdProcessTapDescriptions.count, 1)
        XCTAssertEqual(backend.destroyedProcessTapIDs, [])

        backend.stopDeviceStatus = noErr
        let secondResult = await awaitResult(from: service)

        XCTAssertEqual(secondResult, .available)
        XCTAssertEqual(backend.createdProcessTapDescriptions.count, 2)
        XCTAssertEqual(backend.destroyedProcessTapIDs.count, 2)
    }

    func testCleanupFailureIsRetriedWithoutAnotherAccessProbe() async {
        let backend = configuredBackend()
        let cleanupFinished = expectation(description: "retained probe cleanup finished")
        backend.onDestroyProcessTap = { cleanupFinished.fulfill() }
        backend.enqueueStopDeviceStatuses([-105, noErr])
        let service = makeService(backend, cleanupRetryDelay: 0)

        let result = await awaitResult(from: service)

        guard case .otherFailure(.cleanupFailed(let failures)) = result else {
            return XCTFail("cleanup failure must not report operational access")
        }
        XCTAssertEqual(failures.map(\.operation), [.stopDevice])
        await fulfillment(of: [cleanupFinished], timeout: 1)
        XCTAssertEqual(backend.createdProcessTapDescriptions.count, 1)
        XCTAssertEqual(backend.stoppedDeviceIDs, [702, 702])
        XCTAssertEqual(backend.destroyedIOProcDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedAggregateDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedProcessTapIDs, [701])
    }

    func testShutdownRejectsNewChecksWithoutStartingAProbe() async {
        let backend = configuredBackend()
        let service = makeService(backend)

        await service.shutdown()
        let result = await service.checkAccess()

        XCTAssertEqual(result, .shutdown)
        XCTAssertTrue(backend.mutableOperations.isEmpty)
    }

    func testShutdownRetainsCleanupUntilRecoveryRetryDrainsWithoutAnotherProbe() async {
        let backend = configuredBackend()
        let retryScheduler = FakeAudioSystemAccessRetryScheduler()
        backend.stopDeviceStatus = -105
        var service: AudioSystemAccessService? = makeService(
            backend,
            cleanupRetryDelay: 60,
            cleanupRetryScheduler: retryScheduler
        )
        let retainedService = WeakObjectReference(service)

        let result = await awaitResult(from: service!)

        guard case .otherFailure(.cleanupFailed) = result else {
            return XCTFail("cleanup failure must retain the probe for draining")
        }

        await service!.shutdown()
        let terminalResult = await service!.checkAccess()
        XCTAssertEqual(terminalResult, .shutdown)
        XCTAssertEqual(retryScheduler.pendingCount, 1)
        XCTAssertEqual(backend.createdProcessTapDescriptions.count, 1)

        service = nil
        XCTAssertNotNil(retainedService.value)

        let cleanupFinished = expectation(description: "terminal cleanup retry finished")
        backend.onDestroyProcessTap = { cleanupFinished.fulfill() }
        backend.stopDeviceStatus = noErr
        retryScheduler.runNext()
        await fulfillment(of: [cleanupFinished], timeout: 1)
        await waitUntilIdle(retainedService)
        await waitForDeallocation(retainedService)

        XCTAssertNil(retainedService.value)
        XCTAssertEqual(retryScheduler.pendingCount, 0)
        XCTAssertEqual(backend.createdProcessTapDescriptions.count, 1)
        XCTAssertEqual(backend.createdAggregateDeviceDescriptions.count, 1)
        XCTAssertEqual(backend.ioProcCreations.count, 1)
        XCTAssertEqual(backend.destroyedProcessTapIDs, [701])
    }

    func testDrainRetainedResourcesCleansUpWithoutCreatingAnotherProbe() async {
        let backend = configuredBackend()
        backend.stopDeviceStatus = -105
        let service = makeService(backend, cleanupRetryDelay: 60)

        let result = await awaitResult(from: service)

        guard case .otherFailure(.cleanupFailed) = result else {
            return XCTFail("cleanup failure must retain the probe for draining")
        }
        backend.stopDeviceStatus = noErr
        await service.drainRetainedResources()

        XCTAssertEqual(backend.createdProcessTapDescriptions.count, 1)
        XCTAssertEqual(backend.stoppedDeviceIDs, [702, 702])
        XCTAssertEqual(backend.destroyedIOProcDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedAggregateDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedProcessTapIDs, [701])
    }

    func testEveryCleanupStageFailureIsReportedWithoutClaimingAccess() async {
        let cases: [(String, (FakeAudioHALBackend) -> Void, (FakeAudioHALBackend) -> Void, AudioHALOperation)] = [
            ("stop", { $0.stopDeviceStatus = -106 }, { $0.stopDeviceStatus = noErr }, .stopDevice),
            ("IOProc", { $0.destroyIOProcStatus = -107 }, { $0.destroyIOProcStatus = noErr }, .destroyIOProc),
            ("aggregate", { $0.destroyAggregateDeviceStatus = -108 }, { $0.destroyAggregateDeviceStatus = noErr }, .destroyAggregate),
            ("tap", { $0.destroyProcessTapStatus = -109 }, { $0.destroyProcessTapStatus = noErr }, .destroyTap),
        ]

        for (name, configure, restore, operation) in cases {
            let backend = configuredBackend()
            configure(backend)
            let service = makeService(backend)

            let result = await awaitResult(from: service)

            guard case .otherFailure(.cleanupFailed(let failures)) = result else {
                return XCTFail("\(name) cleanup failure must not report access")
            }
            XCTAssertEqual(failures.map(\.operation), [operation], name)
            restore(backend)
            await service.drainRetainedResources()
            XCTAssertEqual(
                backend.destroyedProcessTapIDs,
                operation == .destroyTap ? [701, 701] : [701],
                name
            )
        }
    }

    func testCleanupSkipsAnAlreadyRemovedAggregateWithoutTouchingAReplacement() async {
        let backend = configuredBackend()
        backend.onStartDevice = { [backend] in
            backend.removeProperty(
                objectID: 702,
                address: .init(selector: kAudioObjectPropertyClass)
            )
            backend.removeProperty(
                objectID: 702,
                address: .init(selector: kAudioDevicePropertyDeviceUID)
            )
        }

        let result = await awaitResult(from: makeService(backend))

        XCTAssertEqual(result, .available)
        XCTAssertEqual(backend.stoppedDeviceIDs, [])
        XCTAssertEqual(backend.destroyedIOProcDeviceIDs, [])
        XCTAssertEqual(backend.destroyedAggregateDeviceIDs, [])
        XCTAssertEqual(backend.destroyedProcessTapIDs, [701])
    }

    func testCleanupFailsClosedWhenAnAggregateUIDCannotBeRead() async {
        let backend = configuredBackend()
        backend.onStartDevice = { [backend] in
            backend.removeProperty(
                objectID: 702,
                address: .init(selector: kAudioDevicePropertyDeviceUID)
            )
        }

        let service = makeService(backend)
        let result = await awaitResult(from: service)

        guard case .otherFailure(.cleanupFailed(let failures)) = result else {
            return XCTFail("an aggregate with an unreadable UID must remain owned")
        }
        XCTAssertEqual(failures.map(\.operation), [.getData])
        XCTAssertEqual(failures.map(\.status), [kAudioHardwareUnknownPropertyError])
        XCTAssertEqual(backend.stoppedDeviceIDs, [])
        XCTAssertEqual(backend.destroyedIOProcDeviceIDs, [])
        XCTAssertEqual(backend.destroyedAggregateDeviceIDs, [])
        XCTAssertEqual(backend.destroyedProcessTapIDs, [])

        backend.setString(
            AudioRoutePlanner.aggregateUIDPrefix + "access.\(fixedProbeUUID().uuidString)",
            objectID: 702,
            address: .init(selector: kAudioDevicePropertyDeviceUID)
        )
        await service.drainRetainedResources()
        XCTAssertEqual(backend.destroyedProcessTapIDs, [701])
    }

    func testCleanupTreatsAnAggregateBadObjectStatusAsAlreadyReleased() async {
        let backend = configuredBackend()
        backend.stopDeviceStatus = kAudioHardwareBadObjectError

        let result = await awaitResult(from: makeService(backend))

        XCTAssertEqual(result, .available)
        XCTAssertEqual(backend.stoppedDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedIOProcDeviceIDs, [])
        XCTAssertEqual(backend.destroyedAggregateDeviceIDs, [])
        XCTAssertEqual(backend.destroyedProcessTapIDs, [701])
    }

    func testCleanupTreatsEveryOwnedProbeResourceBadObjectStatusAsAlreadyReleased() async {
        let cases: [(String, (FakeAudioHALBackend) -> Void, [AudioHALOperation])] = [
            (
                "IOProc",
                { $0.destroyIOProcStatus = kAudioHardwareBadObjectError },
                [.createTap, .createAggregate, .createIOProc, .startDevice, .stopDevice, .destroyIOProc, .destroyTap]
            ),
            (
                "aggregate",
                { $0.destroyAggregateDeviceStatus = kAudioHardwareBadObjectError },
                [
                    .createTap,
                    .createAggregate,
                    .createIOProc,
                    .startDevice,
                    .stopDevice,
                    .destroyIOProc,
                    .destroyAggregate,
                    .destroyTap,
                ]
            ),
            (
                "tap",
                { $0.destroyProcessTapStatus = kAudioHardwareBadObjectError },
                [
                    .createTap,
                    .createAggregate,
                    .createIOProc,
                    .startDevice,
                    .stopDevice,
                    .destroyIOProc,
                    .destroyAggregate,
                    .destroyTap,
                ]
            ),
        ]

        for (name, configure, operations) in cases {
            let backend = configuredBackend()
            configure(backend)

            let result = await awaitResult(from: makeService(backend))

            XCTAssertEqual(result, .available, name)
            XCTAssertEqual(backend.mutableOperations, operations, name)
        }
    }

    func testCancellationWaitsForTheInFlightNativeStartAndItsCleanup() async {
        let backend = configuredBackend()
        let started = expectation(description: "native start entered")
        let releaseStart = DispatchSemaphore(value: 0)
        backend.startDeviceBlocker = releaseStart
        backend.onStartDevice = { started.fulfill() }
        let service = makeService(backend)

        let check = Task { await service.checkAccess() }
        await fulfillment(of: [started], timeout: 1)
        check.cancel()
        releaseStart.signal()
        let result = await check.value

        XCTAssertEqual(result, .available)
        XCTAssertEqual(backend.stoppedDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedIOProcDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedAggregateDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedProcessTapIDs, [701])
    }

    func testShutdownDuringInFlightProbeWaitsForProbeAndCleanup() async {
        let backend = configuredBackend()
        let started = expectation(description: "native start entered")
        let shutdownEntered = expectation(description: "shutdown entered actor")
        let cleanupEntered = expectation(description: "tap cleanup entered")
        let releaseStart = DispatchSemaphore(value: 0)
        let releaseCleanup = DispatchSemaphore(value: 0)
        backend.startDeviceBlocker = releaseStart
        backend.destroyProcessTapBlocker = releaseCleanup
        backend.onStartDevice = { started.fulfill() }
        backend.onDestroyProcessTap = { cleanupEntered.fulfill() }
        let service = makeService(backend)

        let check = Task { await service.checkAccess() }
        await fulfillment(of: [started], timeout: 1)
        await service.testingObserveShutdownEntry {
            shutdownEntered.fulfill()
        }
        let shutdown = Task { await service.shutdown() }
        await fulfillment(of: [shutdownEntered], timeout: 1)
        releaseStart.signal()
        await fulfillment(of: [cleanupEntered], timeout: 1)
        let didCompleteBeforeCleanupRelease = await service.testingDidCompleteShutdown()
        XCTAssertFalse(didCompleteBeforeCleanupRelease)
        releaseCleanup.signal()

        let result = await check.value
        await shutdown.value
        let didCompleteAfterCleanupRelease = await service.testingDidCompleteShutdown()

        XCTAssertEqual(result, .available)
        XCTAssertEqual(backend.stoppedDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedIOProcDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedAggregateDeviceIDs, [702])
        XCTAssertEqual(backend.destroyedProcessTapIDs, [701])
        XCTAssertTrue(didCompleteAfterCleanupRelease)
        let terminalResult = await service.checkAccess()
        XCTAssertEqual(terminalResult, .shutdown)
    }

    func testConcurrentChecksShareOneNativeProbe() async {
        let backend = configuredBackend()
        let started = expectation(description: "native start entered")
        let releaseStart = DispatchSemaphore(value: 0)
        backend.startDeviceBlocker = releaseStart
        backend.onStartDevice = { started.fulfill() }
        let service = makeService(backend)

        let first = Task { await service.checkAccess() }
        await fulfillment(of: [started], timeout: 1)
        let second = Task { await service.checkAccess() }
        await Task.yield()
        releaseStart.signal()
        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertEqual(firstResult, .available)
        XCTAssertEqual(secondResult, .available)
        XCTAssertEqual(backend.createdProcessTapDescriptions.count, 1)
        XCTAssertEqual(backend.createdAggregateDeviceDescriptions.count, 1)
        XCTAssertEqual(backend.ioProcCreations.count, 1)
    }

    private func configuredBackend() -> FakeAudioHALBackend {
        let backend = FakeAudioHALBackend()
        backend.nextProcessTapID = 701
        backend.nextAggregateDeviceID = 702
        backend.nextIOProcID = audioAccessTestIOProcID
        backend.setArray(
            [AudioStreamID(703)],
            objectID: 702,
            address: .init(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeInput
            )
        )
        return backend
    }

    private func makeService(
        _ backend: FakeAudioHALBackend,
        topologyPollCount: Int = 200,
        cleanupPollCount: Int = 200,
        cleanupRetryDelay: TimeInterval = 60,
        cleanupRetryScheduler: (any AudioSystemAccessRetryScheduling)? = nil
    ) -> AudioSystemAccessService {
        AudioSystemAccessService(
            hal: AudioHALClient(backend: backend),
            isSupported: true,
            uuidProvider: fixedProbeUUID,
            topologyPollCount: topologyPollCount,
            cleanupPollCount: cleanupPollCount,
            pollInterval: 0,
            cleanupRetryDelay: cleanupRetryDelay,
            cleanupRetryScheduler: cleanupRetryScheduler
        )
    }

    private func awaitResult(from service: AudioSystemAccessService) async -> AudioSystemAccessResult {
        await service.checkAccess()
    }
}

private let audioAccessTestIOProcID: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in
    noErr
}

private let fixedProbeUUID: @Sendable () -> UUID = {
    UUID(uuidString: "4D414341-0000-4000-8000-000000000001")!
}

private func waitUntilIdle(
    _ reference: WeakObjectReference<AudioSystemAccessService>
) async {
    guard let service = reference.value else { return }
    await service.waitUntilIdleForTesting()
}

private func waitForDeallocation(
    _ reference: WeakObjectReference<AudioSystemAccessService>
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while reference.value != nil && clock.now < deadline {
        await Task.yield()
    }
}

private final class WeakObjectReference<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}

private final class FakeAudioSystemAccessRetryScheduler: AudioSystemAccessRetryScheduling,
    @unchecked Sendable {
    private final class Cancellation: AudioSystemAccessRetryCancellation, @unchecked Sendable {
        private let cancelAction: @Sendable () -> Void

        init(_ cancelAction: @escaping @Sendable () -> Void) {
            self.cancelAction = cancelAction
        }

        func cancel() {
            cancelAction()
        }
    }

    private struct Pending {
        let id: UUID
        let action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var pending: Pending?

    var pendingCount: Int {
        locked { pending == nil ? 0 : 1 }
    }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @Sendable () -> Void
    ) -> any AudioSystemAccessRetryCancellation {
        let id = UUID()
        locked {
            precondition(pending == nil)
            pending = .init(id: id, action: action)
        }
        return Cancellation { [weak self] in
            self?.locked {
                guard self?.pending?.id == id else { return }
                self?.pending = nil
            }
        }
    }

    func runNext() {
        let action = locked { () -> (@Sendable () -> Void)? in
            defer { pending = nil }
            return pending?.action
        }
        action?()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private func invokeIOProc(
    _ callback: AudioDeviceIOProc,
    deviceID: AudioDeviceID,
    input: inout [Float32],
    output: inout [Float32]
) -> OSStatus {
    input.withUnsafeMutableBytes { inputBytes in
        output.withUnsafeMutableBytes { outputBytes in
            var inputBuffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(inputBytes.count),
                    mData: inputBytes.baseAddress
                )
            )
            var outputBuffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(outputBytes.count),
                    mData: outputBytes.baseAddress
                )
            )
            var timestamp = AudioTimeStamp()
            return withUnsafePointer(to: &timestamp) { timestampPointer in
                withUnsafePointer(to: &inputBuffers) { inputPointer in
                    withUnsafeMutablePointer(to: &outputBuffers) { outputPointer in
                        callback(
                            deviceID,
                            timestampPointer,
                            inputPointer,
                            timestampPointer,
                            outputPointer,
                            timestampPointer,
                            nil
                        )
                    }
                }
            }
        }
    }
}
