import AudioToolbox
import CoreAudio
import XCTest
@testable import MacActivityCore

final class AudioDeviceVolumeServiceTests: XCTestCase {
    @MainActor
    func testDefaultInitializerCanBeConstructedWithoutReadingHardware() {
        _ = AudioDeviceVolumeService()
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
    func testFailedMuteReadReturnsItsTypedFailureState() throws {
        let backend = configuredBackend(devices: [.builtInOutput])
        backend.setScalar(
            UInt32(0),
            objectID: TestOutputDevice.builtInOutput.objectID,
            address: muteAddress,
            isSettable: true
        )
        backend.setReadError(
            kAudioHardwareUnspecifiedError,
            objectID: TestOutputDevice.builtInOutput.objectID,
            address: muteAddress,
            announcedByteCount: UInt32(MemoryLayout<UInt32>.size)
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        let snapshot = try service.outputDeviceSnapshot(forUID: "BuiltInOutput")

        guard case .failed(let error) = snapshot.mute else {
            return XCTFail("Expected a typed failure state")
        }
        XCTAssertEqual(error.operation, .getData)
        XCTAssertEqual(error.status, kAudioHardwareUnspecifiedError)
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
    func testOutputSnapshotsSkipUnreadableDeviceWithoutDroppingReadableDevices() throws {
        let backend = configuredBackend(devices: [.builtInOutput, .usbOutput])
        backend.setReadError(
            kAudioHardwareUnspecifiedError,
            objectID: TestOutputDevice.usbOutput.objectID,
            address: .init(selector: kAudioObjectPropertyName),
            announcedByteCount: UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        XCTAssertEqual(try service.outputDeviceSnapshots().map(\.id), ["BuiltInOutput"])
    }

    @MainActor
    func testOutputSnapshotsSkipDeviceWhoseUIDCannotBeRead() throws {
        let backend = configuredBackend(devices: [.builtInOutput, .usbOutput])
        backend.setReadError(
            kAudioHardwareUnspecifiedError,
            objectID: TestOutputDevice.usbOutput.objectID,
            address: .init(selector: kAudioDevicePropertyDeviceUID),
            announcedByteCount: UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        XCTAssertEqual(try service.outputDeviceSnapshots().map(\.id), ["BuiltInOutput"])
    }

    @MainActor
    func testOutputDeviceEnumerationDropsMissingAndUnreadableOutputStreamMetadata() throws {
        let backend = configuredBackend(devices: [.builtInOutput, .usbOutput])
        backend.setRawBytes(
            [],
            objectID: TestOutputDevice.builtInOutput.objectID,
            address: .init(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput
            ),
            isSettable: false
        )
        backend.setReadError(
            kAudioHardwareUnspecifiedError,
            objectID: TestOutputDevice.usbOutput.objectID,
            address: .init(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput
            ),
            announcedByteCount: UInt32(MemoryLayout<AudioStreamID>.size)
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        XCTAssertEqual(try service.outputDeviceSnapshots(), [])
    }

    @MainActor
    func testOutputDeviceEnumerationDropsDeviceWithoutAnOutputStreamProperty() throws {
        let backend = configuredBackend(devices: [.builtInOutput])
        backend.removeProperty(
            objectID: TestOutputDevice.builtInOutput.objectID,
            address: .init(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput
            )
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        XCTAssertEqual(try service.outputDeviceSnapshots(), [])
    }

    @MainActor
    func testRouteDevicesSkipUnreadableDeviceWithoutDroppingReadableDevices() throws {
        let backend = configuredBackend(devices: [.builtInOutput, .usbOutput])
        configureRouteMetadata(for: .builtInOutput, backend: backend)
        configureRouteMetadata(for: .usbOutput, backend: backend)
        backend.setReadError(
            kAudioHardwareUnspecifiedError,
            objectID: TestOutputDevice.usbOutput.objectID,
            address: .init(selector: kAudioObjectPropertyName),
            announcedByteCount: UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        XCTAssertEqual(try service.routeDevices().map(\.uid), ["BuiltInOutput"])
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

    @MainActor
    func testDeviceLookupSkipsUnreadableCandidatesAndReportsMissingValue() {
        let backend = configuredBackend(devices: [.builtInOutput, .usbOutput])
        backend.setReadError(
            kAudioHardwareUnspecifiedError,
            objectID: TestOutputDevice.builtInOutput.objectID,
            address: .init(selector: kAudioDevicePropertyDeviceUID),
            announcedByteCount: UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        )
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        XCTAssertThrowsError(try service.outputDeviceSnapshot(forUID: "Missing")) { error in
            guard let halError = error as? AudioHALError else {
                return XCTFail("Expected typed HAL error")
            }
            XCTAssertEqual(halError.operation, .getData)
            XCTAssertEqual(halError.reason, .missingValue)
        }
    }

    @MainActor
    func testInternalDeviceUIDIsRejectedBeforeHardwareEnumeration() {
        let backend = FakeAudioHALBackend()
        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))

        XCTAssertThrowsError(
            try service.outputDeviceSnapshot(forUID: "com.how.macactivity.audio.aggregate.fixture")
        ) { error in
            XCTAssertEqual((error as? AudioHALError)?.reason, .missingValue)
        }
        XCTAssertEqual(backend.dataSizeCallCount, 0)
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

    func configureRouteMetadata(
        for device: TestOutputDevice,
        backend: FakeAudioHALBackend
    ) {
        backend.setScalar(
            UInt32(1),
            objectID: device.objectID,
            address: .init(selector: kAudioDevicePropertyDeviceIsAlive)
        )
        backend.setScalar(
            AudioStreamBasicDescription(
                mSampleRate: 48_000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8,
                mFramesPerPacket: 1,
                mBytesPerFrame: 8,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            ),
            objectID: AudioStreamID(device.objectID + 1_000),
            address: .init(selector: kAudioStreamPropertyVirtualFormat)
        )
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

    static let usbOutput = TestOutputDevice(
        objectID: 11,
        uid: "USBOutput",
        name: "USB Speakers"
    )
}
