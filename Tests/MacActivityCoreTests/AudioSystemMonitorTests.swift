import CoreAudio
import XCTest
@testable import MacActivityCore

final class AudioSystemMonitorTests: XCTestCase {
    func testBaseListenerAvailabilityMatrix() throws {
        let macOS141 = MonitorFixture(macOS: (14, 1))
        let macOS142 = MonitorFixture(macOS: (14, 2))

        XCTAssertEqual(try macOS141.startAndCountRegistrations(), 3)
        XCTAssertEqual(try macOS142.startAndCountRegistrations(), 4)
        XCTAssertFalse(
            macOS141.backend.addedListeners.contains {
                $0.address.selector == kAudioHardwarePropertyProcessObjectList
            }
        )
    }

    func testObservedObjectDiffRemovesAndAddsExactPairs() throws {
        let fixture = MonitorFixture(macOS: (14, 2))
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

    func testBurstIsEmittedAsOneTypedSet() async throws {
        let fixture = MonitorFixture(macOS: (14, 2), delay: .milliseconds(10))
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
        let fixture = MonitorFixture(macOS: (14, 2))

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
        let fixture = MonitorFixture(macOS: (14, 1))
        try fixture.monitor.start()

        try fixture.monitor.updateObservedObjects(
            deviceIDs: [],
            processObjectIDs: [100]
        )

        XCTAssertEqual(fixture.backend.addCount(for: 100), 0)
    }

    func testStopRemovesEachExactTupleOnce() throws {
        let fixture = MonitorFixture(macOS: (14, 2))
        try fixture.monitor.start()
        try fixture.monitor.updateObservedObjects(
            deviceIDs: [10],
            processObjectIDs: [100]
        )
        let registrations = fixture.backend.addedListeners

        fixture.monitor.stop()
        fixture.monitor.stop()

        XCTAssertEqual(fixture.backend.removedListeners.count, registrations.count)
        for removal in fixture.backend.removedListeners {
            let exactMatches = registrations.filter {
                $0.objectID == removal.objectID
                    && $0.address == removal.address
                    && $0.queue === removal.queue
                    && $0.blockIdentifier == removal.blockIdentifier
            }
            XCTAssertEqual(exactMatches.count, 1)
        }
    }

    func testStopSuppressesPendingEmission() throws {
        let fixture = MonitorFixture(macOS: (14, 2), delay: .milliseconds(100))
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
        let fixture = MonitorFixture(macOS: (14, 2), delay: .milliseconds(10))
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
        let staleBlockIDs = Set(staleRegistrations.map(\.blockIdentifier))
        XCTAssertEqual(fixture.backend.removedListeners.count, staleRegistrations.count)
        XCTAssertTrue(
            fixture.backend.removedListeners.allSatisfy {
                !staleBlockIDs.contains($0.blockIdentifier)
            },
            "stale: \(staleBlockIDs), removed: "
                + "\(fixture.backend.removedListeners.map(\.blockIdentifier))"
        )
    }
}

private final class MonitorFixture: @unchecked Sendable {
    let backend = FakeAudioHALBackend()
    let monitor: AudioSystemMonitor

    init(
        macOS: (major: Int, minor: Int),
        delay: DispatchTimeInterval = .milliseconds(50)
    ) {
        monitor = AudioSystemMonitor(
            hal: AudioHALClient(backend: backend),
            availability: AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: macOS.major,
                    minorVersion: macOS.minor,
                    patchVersion: 0
                )
            ),
            queue: DispatchQueue(label: "AudioSystemMonitorTests.monitor"),
            coalescingDelay: delay
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
    static let processOutputDevices = AudioHALPropertyAddress(
        selector: kAudioProcessPropertyDevices,
        scope: kAudioObjectPropertyScopeOutput
    )
    static let processIsRunningOutput = AudioHALPropertyAddress(
        selector: kAudioProcessPropertyIsRunningOutput
    )
}
