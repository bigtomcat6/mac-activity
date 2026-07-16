import AudioToolbox
import CoreAudio
import XCTest
@testable import MacActivityCore

final class AudioSystemMonitorTests: XCTestCase {
    func testDefaultInitializerCanBeConstructedWithoutReadingHardware() {
        _ = AudioSystemMonitor()
    }

    func testConservativeProductionPolicyOmitsProcessListenersOnMacOS142() throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .conservative
        )

        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )

        XCTAssertFalse(fixture.backend.addedListeners.contains {
            $0.address == .processList || $0.objectID == 100
        })
        XCTAssertEqual(fixture.backend.addCount(for: 10), 2)
    }

    func testDeviceVolumeAndMuteListenersRegisterAndEmitADeviceRefresh() async throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .conservative
        )
        fixture.backend.setScalar(
            Float32(0.5),
            objectID: 10,
            address: .deviceVolume
        )
        fixture.backend.setScalar(
            UInt32(0),
            objectID: 10,
            address: .deviceMute
        )

        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: []
        )

        guard fixture.backend.addedAddresses(for: 10).contains(.deviceVolume),
              fixture.backend.addedAddresses(for: 10).contains(.deviceMute)
        else {
            return XCTFail("Expected volume and mute listeners for a controllable device")
        }

        let event = Task { try await fixture.nextChangeSet() }
        XCTAssertTrue(
            fixture.backend.invokeLatestListener(
                objectID: 10,
                address: .deviceVolume
            )
        )
        let changes = try await event.value
        XCTAssertTrue(changes.contains { change in
            guard case .device(let deviceID, _) = change else { return false }
            return deviceID == 10
        })
    }

    func testRestartRecoveryBackoffSequenceIsExponentiallyCapped() {
        var backoff = AudioRestartRecoveryBackoff(
            initialDelayMilliseconds: 250,
            maximumDelayMilliseconds: 1_000
        )

        XCTAssertEqual(backoff.nextDelay(), .milliseconds(250))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(500))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(1_000))
        XCTAssertEqual(backoff.nextDelay(), .milliseconds(1_000))
    }

    func testRestartRecoveryBackoffResetReturnsInitialDelay() {
        var backoff = AudioRestartRecoveryBackoff(
            initialDelayMilliseconds: 250,
            maximumDelayMilliseconds: 1_000
        )
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()

        backoff.reset()

        XCTAssertEqual(backoff.nextDelay(), .milliseconds(250))
    }

    func testBaseListenerAvailabilityMatrix() throws {
        let macOS141 = MonitorFixture(
            macOS: (14, 1),
            nativeValidationPolicy: .allowingAllForTesting
        )
        let macOS142 = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting
        )

        XCTAssertEqual(try macOS141.startAndCountRegistrations(), 3)
        XCTAssertEqual(try macOS142.startAndCountRegistrations(), 4)
        XCTAssertFalse(
            macOS141.backend.addedListeners.contains {
                $0.address.selector == kAudioHardwarePropertyProcessObjectList
            }
        )
    }

    func testObservedObjectDiffRemovesAndAddsExactPairs() throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting
        )
        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10, 20],
            processObjectIDs: [100]
        )
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [20, 30],
            processObjectIDs: [100]
        )

        XCTAssertEqual(
            Set(fixture.backend.removedAddresses(for: 10)),
            Set([.nominalSampleRate, .deviceIsAlive])
        )
        XCTAssertEqual(
            Set(fixture.backend.addedAddresses(for: 20)),
            Set([.nominalSampleRate, .deviceIsAlive])
        )
        XCTAssertEqual(fixture.backend.addCount(for: 30), 2)
        XCTAssertEqual(fixture.backend.addCount(for: 100), 2)
        XCTAssertEqual(
            Set(fixture.backend.addedAddresses(for: 100)),
            Set([.processOutputDevices, .processIsRunningOutput])
        )
    }

    func testObservedObjectsConfiguredBeforeStartAreRegisteredOnInitialStart() throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting
        )

        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )
        try fixture.monitor.start()

        XCTAssertEqual(fixture.backend.addCount(for: 10), 2)
        XCTAssertEqual(fixture.backend.addCount(for: 100), 2)
    }

    func testObservedProcessRemovalCancelsOnlyThatProcessTokens() throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting
        )
        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )

        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: []
        )

        XCTAssertEqual(
            Set(fixture.backend.removedAddresses(for: 100)),
            Set([.processOutputDevices, .processIsRunningOutput])
        )
        XCTAssertTrue(fixture.backend.removedAddresses(for: 10).isEmpty)
    }

    func testBurstIsEmittedAsOneTypedSet() async throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting,
            delay: .milliseconds(10)
        )
        try fixture.monitor.start()
        let event = Task { try await fixture.nextChangeSet() }

        fixture.fire(.deviceList)
        fixture.fire(.deviceList)
        fixture.fire(.defaultOutputDevice)

        let changes = try await event.value
        XCTAssertEqual(
            changes,
            [.deviceList, .defaultOutputDevice]
        )
    }

    func testStartAndUnchangedObservedSetsAreIdempotent() throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting
        )

        try fixture.monitor.start()
        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )
        let registrationCount = fixture.backend.addedListeners.count
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )

        XCTAssertEqual(registrationCount, 8)
        XCTAssertEqual(fixture.backend.addedListeners.count, registrationCount)
        XCTAssertTrue(fixture.backend.removedListeners.isEmpty)
    }

    func testUnsupportedProcessObjectsNeverRegister() throws {
        let fixture = MonitorFixture(
            macOS: (14, 1),
            nativeValidationPolicy: .allowingAllForTesting
        )
        try fixture.monitor.start()

        try fixture.monitor.updateObservedObjects(
            deviceIDs: [],
            processObjectIDs: [100]
        )

        XCTAssertEqual(fixture.backend.addCount(for: 100), 0)
    }

    func testStopRemovesEachExactTupleOnce() throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting
        )
        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )
        let registrations = fixture.backend.addedListeners

        fixture.monitor.stop()
        fixture.monitor.stop()

        XCTAssertEqual(
            listenerTupleCounts(fixture.backend.removedListeners),
            listenerTupleCounts(registrations)
        )
    }

    func testStopSuppressesPendingEmission() throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting,
            delay: .milliseconds(100)
        )
        try fixture.monitor.start()
        let emission = expectation(description: "No change set is emitted after stop")
        emission.isInverted = true
        let observer = Task {
            for await _ in fixture.monitor.changes {
                emission.fulfill()
                break
            }
        }

        fixture.fire(.deviceList)
        fixture.monitor.stop()

        XCTAssertEqual(XCTWaiter.wait(for: [emission], timeout: 0.2), .completed)
        observer.cancel()
    }

    func testServiceRestartRebuildsRememberedRegistrationsBeforeEmission() async throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting,
            delay: .milliseconds(10)
        )
        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )
        let staleRegistrations = fixture.backend.addedListeners
        let event = Task { try await fixture.nextChangeSet() }

        fixture.fire(.serviceRestarted)

        let changes = try await event.value
        XCTAssertEqual(changes, [.serviceRestarted])
        XCTAssertEqual(fixture.backend.addedListeners.count, staleRegistrations.count * 2)
        XCTAssertEqual(fixture.backend.addCount(for: 10), 4)
        XCTAssertEqual(fixture.backend.addCount(for: 100), 4)
        XCTAssertTrue(fixture.backend.removedListeners.isEmpty)

        fixture.monitor.stop()
        let staleRegistrationIDs = Set(
            staleRegistrations.map(\.registrationIdentifier)
        )
        XCTAssertEqual(fixture.backend.removedListeners.count, staleRegistrations.count)
        XCTAssertTrue(
            fixture.backend.removedListeners.allSatisfy {
                !staleRegistrationIDs.contains($0.registrationIdentifier)
            },
            "stale: \(staleRegistrationIDs), removed: "
                + "\(fixture.backend.removedListeners.map(\.registrationIdentifier))"
        )
    }

    func testDuplicateStaleServiceRestartCallbackDoesNotLeakReplacementGeneration() async throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting,
            delay: .milliseconds(10)
        )
        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )
        let staleRestartListener = try XCTUnwrap(
            fixture.backend.activeListeners.first {
                $0.address == .serviceRestarted
            }
        )
        let event = Task { try await fixture.nextChangeSet() }

        fixture.fire(.serviceRestarted)
        fixture.backend.invokeRetainedListener(staleRestartListener)

        let changes = try await event.value
        XCTAssertEqual(changes, [.serviceRestarted])
        let replacementRegistrations = fixture.backend.activeListeners
        XCTAssertEqual(replacementRegistrations.count, 8)

        fixture.monitor.stop()

        XCTAssertTrue(fixture.backend.activeListeners.isEmpty)
        XCTAssertEqual(
            listenerTupleCounts(fixture.backend.removedListeners),
            listenerTupleCounts(replacementRegistrations)
        )
    }

    func testServiceRestartRetriesTransientRegistrationFailureBeforeEmission() async throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting,
            delay: .milliseconds(10)
        )
        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )
        let initialRegistrationCount = fixture.backend.addedListeners.count
        fixture.backend.enqueueAddListenerStatuses([
            noErr,
            kAudioHardwareUnspecifiedError,
        ])

        fixture.fire(.serviceRestarted)

        let changes = try await fixture.nextChangeSet(timeout: .milliseconds(250))
        XCTAssertEqual(changes, [.serviceRestarted])
        XCTAssertEqual(fixture.backend.addedListeners.count, initialRegistrationCount + 10)
        XCTAssertEqual(fixture.backend.removedListeners.count, 1)
        let recoveredRegistrations = Array(fixture.backend.addedListeners.suffix(8))
        XCTAssertEqual(
            listenerTupleCounts(fixture.backend.activeListeners),
            listenerTupleCounts(recoveredRegistrations)
        )

        fixture.monitor.stop()

        XCTAssertTrue(fixture.backend.activeListeners.isEmpty)
        XCTAssertEqual(fixture.backend.removedListeners.count, 9)
        XCTAssertEqual(
            listenerTupleCounts(Array(fixture.backend.removedListeners.suffix(8))),
            listenerTupleCounts(recoveredRegistrations)
        )
    }

    func testStopCancelsPendingServiceRestartRecovery() throws {
        let fixture = MonitorFixture(
            macOS: (14, 2),
            nativeValidationPolicy: .allowingAllForTesting,
            delay: .milliseconds(10)
        )
        try fixture.monitor.start()
        let initialRegistrationCount = fixture.backend.addedListeners.count
        fixture.backend.enqueueAddListenerStatuses([
            kAudioHardwareUnspecifiedError,
        ])
        let wait = expectation(description: "No registration retry after stop")
        wait.isInverted = true

        fixture.fire(.serviceRestarted)
        fixture.monitor.stop()

        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 0.05), .completed)
        XCTAssertEqual(fixture.backend.addedListeners.count, initialRegistrationCount + 1)
        XCTAssertTrue(fixture.backend.activeListeners.isEmpty)
        XCTAssertTrue(fixture.backend.removedListeners.isEmpty)
    }
}

private final class MonitorFixture: @unchecked Sendable {
    let backend = FakeAudioHALBackend()
    let monitor: AudioSystemMonitor

    init(
        macOS: (major: Int, minor: Int),
        nativeValidationPolicy: AudioRouteNativeValidationPolicy,
        delay: DispatchTimeInterval = .milliseconds(50),
        restartRecoveryBackoff: AudioRestartRecoveryBackoff = .init(
            initialDelayMilliseconds: 5,
            maximumDelayMilliseconds: 20
        )
    ) {
        monitor = AudioSystemMonitor(
            hal: AudioHALClient(backend: backend),
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: macOS.major,
                    minorVersion: macOS.minor,
                    patchVersion: 0
                ),
                nativeValidationPolicy: nativeValidationPolicy
            ),
            queue: DispatchQueue(label: "AudioSystemMonitorTests.monitor"),
            coalescingDelay: delay,
            restartRecoveryBackoff: restartRecoveryBackoff
        )
    }

    func startAndCountRegistrations() throws -> Int {
        try monitor.start()
        return backend.addedListeners.count
    }

    func nextChangeSet() async throws -> Set<AudioSystemChange> {
        var iterator = monitor.changes.makeAsyncIterator()
        guard let changes = await iterator.next() else {
            throw MonitorFixtureError.streamEnded
        }
        return changes
    }

    func nextChangeSet(timeout: Duration) async throws -> Set<AudioSystemChange> {
        let stream = monitor.changes
        return try await withThrowingTaskGroup(
            of: Set<AudioSystemChange>.self
        ) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let changes = await iterator.next() else {
                    throw MonitorFixtureError.streamEnded
                }
                return changes
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MonitorFixtureError.timedOut
            }
            defer { group.cancelAll() }
            guard let changes = try await group.next() else {
                throw MonitorFixtureError.streamEnded
            }
            return changes
        }
    }

    func fire(_ change: AudioSystemChange) {
        let registration: (AudioObjectID, AudioHALPropertyAddress)
        switch change {
        case .deviceList:
            registration = (.system, .deviceList)
        case .defaultOutputDevice:
            registration = (.system, .defaultOutputDevice)
        case .serviceRestarted:
            registration = (.system, .serviceRestarted)
        case .processList:
            registration = (.system, .processList)
        case .device(let deviceID, .nominalSampleRate):
            registration = (deviceID, .nominalSampleRate)
        case .device(let deviceID, .liveness):
            registration = (deviceID, .deviceIsAlive)
        case .device(let deviceID, .volume):
            registration = (deviceID, .deviceVolume)
        case .device(let deviceID, .mute):
            registration = (deviceID, .deviceMute)
        case .process(let processObjectID, .runningOutput):
            registration = (processObjectID, .processIsRunningOutput)
        case .process(let processObjectID, .outputDevices):
            registration = (processObjectID, .processOutputDevices)
        }

        XCTAssertTrue(
            backend.invokeLatestListener(
                objectID: registration.0,
                address: registration.1
            )
        )
    }
}

private enum MonitorFixtureError: Error {
    case streamEnded
    case timedOut
}

private struct ListenerTuple: Hashable {
    let objectID: AudioObjectID
    let address: AudioHALPropertyAddress
    let queueIdentifier: ObjectIdentifier
    let registrationIdentifier: ObjectIdentifier

    init(_ call: FakeAudioHALBackend.ListenerCall) {
        objectID = call.objectID
        address = call.address
        queueIdentifier = ObjectIdentifier(call.queue)
        registrationIdentifier = call.registrationIdentifier
    }
}

private func listenerTupleCounts(
    _ calls: [FakeAudioHALBackend.ListenerCall]
) -> [ListenerTuple: Int] {
    calls.reduce(into: [:]) { counts, call in
        counts[ListenerTuple(call), default: 0] += 1
    }
}

private extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
}

private extension AudioHALPropertyAddress {
    static let deviceList = AudioHALPropertyAddress(
        selector: kAudioHardwarePropertyDevices
    )
    static let defaultOutputDevice = AudioHALPropertyAddress(
        selector: kAudioHardwarePropertyDefaultOutputDevice
    )
    static let serviceRestarted = AudioHALPropertyAddress(
        selector: kAudioHardwarePropertyServiceRestarted
    )
    static let processList = AudioHALPropertyAddress(
        selector: kAudioHardwarePropertyProcessObjectList
    )
    static let nominalSampleRate = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyNominalSampleRate
    )
    static let deviceIsAlive = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyDeviceIsAlive
    )
    static let deviceVolume = AudioHALPropertyAddress(
        selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        scope: kAudioObjectPropertyScopeOutput
    )
    static let deviceMute = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyMute,
        scope: kAudioObjectPropertyScopeOutput
    )
    static let processOutputDevices = AudioHALPropertyAddress(
        selector: kAudioProcessPropertyDevices,
        scope: kAudioObjectPropertyScopeOutput
    )
    static let processIsRunningOutput = AudioHALPropertyAddress(
        selector: kAudioProcessPropertyIsRunningOutput
    )
}
