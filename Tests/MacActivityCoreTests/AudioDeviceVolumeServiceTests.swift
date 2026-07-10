import AudioToolbox
import CoreAudio
import XCTest
@testable import MacActivityCore

final class AudioDeviceVolumeServiceTests: XCTestCase {
    func testDeviceRowsExposeWritableHardwareVolume() {
        let device = AudioDeviceVolumeService.makeDevice(
            id: "BuiltInOutput",
            name: "MacBook Speakers",
            volume: 0.42,
            isMuted: false,
            canSetVolume: true,
            canSetMute: true
        )

        XCTAssertEqual(device.id, "BuiltInOutput")
        XCTAssertEqual(device.name, "MacBook Speakers")
        XCTAssertEqual(device.volume, 0.42, accuracy: 0.001)
        XCTAssertEqual(device.volumeAvailability, .writable)
        XCTAssertEqual(device.muteAvailability, .writable)
    }

    func testDeviceRowsMarkUnsupportedVolumeAsReadOnly() {
        let device = AudioDeviceVolumeService.makeDevice(
            id: "HDMI",
            name: "Display Audio",
            volume: nil,
            isMuted: nil,
            canSetVolume: false,
            canSetMute: false
        )

        XCTAssertEqual(device.volume, 1.0)
        XCTAssertEqual(device.volumeAvailability, .unsupported)
        XCTAssertEqual(device.muteAvailability, .unsupported)
    }

    func testVolumeInputIsClampedForWrites() {
        XCTAssertEqual(AudioDeviceVolumeService.clampedVolume(-0.5), 0)
        XCTAssertEqual(AudioDeviceVolumeService.clampedVolume(0.5), 0.5)
        XCTAssertEqual(AudioDeviceVolumeService.clampedVolume(1.5), 1)
    }

    @MainActor
    func testMissingVolumePropertyIsUnsupported() throws {
        let backend = configuredBackend(devices: [.builtInOutput])
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        let missingProperty = try service.outputDeviceSnapshot(forUID: "BuiltInOutput")

        XCTAssertEqual(missingProperty.volume, .unsupported)
    }

    @MainActor
    func testReadableReadOnlyVolumePreservesItsValue() throws {
        let backend = configuredBackend(devices: [.builtInOutput])
        backend.setScalar(
            Float32(0.42),
            objectID: 10,
            address: volumeAddress,
            isSettable: false
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        let readOnlyProperty = try service.outputDeviceSnapshot(forUID: "BuiltInOutput")

        XCTAssertEqual(readOnlyProperty.volume, .value(0.42, isWritable: false))
    }

    @MainActor
    func testFailedVolumeReadDoesNotInventAFallbackValue() throws {
        let backend = configuredBackend(devices: [.builtInOutput])
        backend.setReadError(
            kAudioHardwareUnspecifiedError,
            objectID: 10,
            address: volumeAddress,
            announcedByteCount: UInt32(MemoryLayout<Float32>.size)
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        let failedProperty = try service.outputDeviceSnapshot(forUID: "BuiltInOutput")

        XCTAssertNil(failedProperty.volume.value)
        guard case .failed(let error) = failedProperty.volume else {
            return XCTFail("Expected a typed failed state")
        }
        XCTAssertEqual(error.operation, .getData)
        XCTAssertEqual(error.status, kAudioHardwareUnspecifiedError)
    }

    @MainActor
    func testBadObjectVolumeReadIsUnavailable() throws {
        let backend = configuredBackend(devices: [.builtInOutput])
        backend.setReadError(
            kAudioHardwareBadObjectError,
            objectID: 10,
            address: volumeAddress,
            announcedByteCount: UInt32(MemoryLayout<Float32>.size)
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        let snapshot = try service.outputDeviceSnapshot(forUID: "BuiltInOutput")

        XCTAssertEqual(snapshot.volume, .unavailable)
    }

    @MainActor
    func testMuteCapabilityIsReadIndependentlyFromVolume() throws {
        let backend = configuredBackend(devices: [.builtInOutput])
        backend.setScalar(
            UInt32(1),
            objectID: 10,
            address: muteAddress,
            isSettable: false
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        let snapshot = try service.outputDeviceSnapshot(forUID: "BuiltInOutput")

        XCTAssertEqual(snapshot.volume, .unsupported)
        XCTAssertEqual(snapshot.mute, .value(true, isWritable: false))
    }

    @MainActor
    func testOutputSnapshotsFilterMacActivityInternalDeviceUIDs() throws {
        let backend = configuredBackend(
            devices: [
                .builtInOutput,
                TestOutputDevice(
                    objectID: 11,
                    uid: "com.how.macactivity.audio.aggregate.fixture",
                    name: "MacActivity Aggregate"
                ),
            ]
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        let deviceUIDs = try service.outputDeviceSnapshots().map(\.id)

        XCTAssertEqual(deviceUIDs, ["BuiltInOutput"])
        XCTAssertFalse(deviceUIDs.contains("com.how.macactivity.audio.aggregate.fixture"))
    }

    @MainActor
    func testWriteVolumeClampsAndConfirmsOnlyTheTargetProperty() throws {
        let backend = configuredBackend(devices: [.builtInOutput])
        backend.setScalar(
            Float32(0.25),
            objectID: 10,
            address: volumeAddress,
            isSettable: true
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        let confirmed = try service.writeVolume(1.4, forUID: "BuiltInOutput")

        XCTAssertEqual(confirmed, 1)
        XCTAssertEqual(backend.writeSelectors, [kAudioHardwareServiceDeviceProperty_VirtualMainVolume])
        XCTAssertFalse(backend.readSelectors.contains(kAudioHardwarePropertyProcessObjectList))
        XCTAssertFalse(backend.readSelectors.contains(kAudioObjectPropertyName))
        XCTAssertFalse(backend.readSelectors.contains(kAudioDevicePropertyMute))
    }

    @MainActor
    func testWriteMuteConfirmsOnlyTheTargetProperty() throws {
        let backend = configuredBackend(devices: [.builtInOutput])
        backend.setScalar(
            UInt32(0),
            objectID: 10,
            address: muteAddress,
            isSettable: true
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        let confirmed = try service.writeMute(true, forUID: "BuiltInOutput")

        XCTAssertTrue(confirmed)
        XCTAssertEqual(backend.writeSelectors, [kAudioDevicePropertyMute])
        XCTAssertFalse(backend.readSelectors.contains(kAudioHardwarePropertyProcessObjectList))
        XCTAssertFalse(backend.readSelectors.contains(kAudioObjectPropertyName))
        XCTAssertFalse(
            backend.readSelectors.contains(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        )
    }
}

private extension AudioDeviceVolumeServiceTests {
    var volumeAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    var muteAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    func configuredBackend(
        devices: [TestOutputDevice]
    ) -> FakeAudioHALBackend {
        let backend = FakeAudioHALBackend()
        backend.setArray(
            devices.map(\.objectID),
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: .init(selector: kAudioHardwarePropertyDevices)
        )

        for device in devices {
            backend.setArray(
                [AudioStreamID(device.objectID + 1_000)],
                objectID: device.objectID,
                address: .init(
                    selector: kAudioDevicePropertyStreams,
                    scope: kAudioObjectPropertyScopeOutput
                )
            )
            backend.setString(
                device.uid,
                objectID: device.objectID,
                address: .init(selector: kAudioDevicePropertyDeviceUID)
            )
            backend.setString(
                device.name,
                objectID: device.objectID,
                address: .init(selector: kAudioObjectPropertyName)
            )
        }

        return backend
    }
}

private struct TestOutputDevice {
    let objectID: AudioDeviceID
    let uid: String
    let name: String

    static let builtInOutput = TestOutputDevice(
        objectID: 10,
        uid: "BuiltInOutput",
        name: "MacBook Speakers"
    )
}
