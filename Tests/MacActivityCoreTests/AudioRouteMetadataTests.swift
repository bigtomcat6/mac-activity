import AudioToolbox
import CoreAudio
import XCTest
@testable import MacActivityCore

@MainActor
final class AudioRouteMetadataTests: XCTestCase {
    func testRouteDeviceReadsStablePhysicalTopology() throws {
        let fixture = MetadataFixture()
        fixture.installDevice(
            id: 40,
            uid: "USB",
            modelUID: "Model.USB",
            inputStreams: [(401, fixture.format(channels: 2))],
            outputStreams: [(402, fixture.format(channels: 8))],
            clockDomain: 0,
            transportType: kAudioDeviceTransportTypeUSB,
            ownerID: 900,
            plugInBundleID: "com.vendor.driver"
        )

        let device = try XCTUnwrap(fixture.service.routeDevices().first)

        XCTAssertEqual(device.inputStreams.map(\.streamObjectID), [401])
        XCTAssertEqual(device.outputStreams.map(\.streamObjectID), [402])
        XCTAssertEqual(device.clockDomain, 0)
        XCTAssertEqual(device.transportType, kAudioDeviceTransportTypeUSB)
        XCTAssertEqual(device.modelUID, "Model.USB")
        XCTAssertEqual(device.driverIdentity?.plugInBundleID, "com.vendor.driver")
        XCTAssertNil(device.driverIdentity?.availableVersion)
        XCTAssertTrue(fixture.backend.writeSelectors.isEmpty)
        XCTAssertTrue(fixture.backend.mutableOperations.isEmpty)
    }

    func testAggregateCompositionUsesFullListOrderAndActiveMembership() throws {
        let fixture = MetadataFixture()
        fixture.installAggregate(
            id: 50,
            fullUIDs: ["USB", "HDMI"],
            activeIDs: [502, 501],
            activeUIDsByID: [501: "USB", 502: "HDMI"],
            mainUID: "USB",
            isStacked: true,
            tapUUIDs: []
        )

        let device = try XCTUnwrap(fixture.service.routeDevices().first)
        let composition = try XCTUnwrap(device.aggregateComposition)
        XCTAssertEqual(composition.fullSubdeviceUIDs, ["USB", "HDMI"])
        XCTAssertEqual(Set(composition.activeSubdeviceUIDs), Set(["USB", "HDMI"]))
        XCTAssertEqual(device.aggregateSubdeviceUIDs, composition.activeSubdeviceUIDs)
        XCTAssertEqual(composition.mainSubdeviceUID, "USB")
        XCTAssertEqual(composition.isStacked, true)
        XCTAssertEqual(composition.tapUUIDs, [])
        XCTAssertEqual(
            fixture.backend.dataReadCount(
                for: kAudioAggregateDevicePropertyActiveSubDeviceList
            ),
            1
        )
    }

    func testDriverIdentityRejectsANonPlugInOwner() throws {
        let fixture = MetadataFixture()
        fixture.installDevice(
            id: 40,
            uid: "USB",
            outputStreams: [(402, fixture.format(channels: 2))],
            ownerID: 900,
            ownerClassID: kAudioDeviceClassID,
            plugInBundleID: "not-a-plugin"
        )

        XCTAssertNil(try fixture.service.routeDevices().first?.driverIdentity)
    }

    func testIncompleteAggregateCompositionRemainsExplicitlyIncomplete() throws {
        let fixture = MetadataFixture()
        fixture.installAggregate(id: 50, fullUIDs: ["USB"], omitComposition: true)

        let composition = try XCTUnwrap(
            fixture.service.routeDevices().first?.aggregateComposition
        )
        XCTAssertNil(composition.mainSubdeviceUID)
        XCTAssertNil(composition.isStacked)
    }

    func testAggregateMissingActiveEvidenceIsStillRecognizedAsIncomplete() throws {
        let fixture = MetadataFixture()
        fixture.installAggregate(
            id: 50,
            fullUIDs: ["USB"],
            mainUID: "USB",
            isStacked: false,
            omitActiveList: true
        )

        let device = try XCTUnwrap(fixture.service.routeDevices().first)

        XCTAssertTrue(device.isAggregate)
        XCTAssertEqual(device.aggregateSubdeviceUIDs, [])
        XCTAssertEqual(device.aggregateComposition?.activeSubdeviceUIDs, [])
        XCTAssertEqual(
            fixture.backend.dataReadCount(
                for: kAudioAggregateDevicePropertyActiveSubDeviceList
            ),
            0
        )
    }

    func testTopologyFingerprintRoundTripsWithoutParallelSchema() throws {
        let stream = AudioRouteStream(
            streamObjectID: 402,
            streamIndex: 0,
            format: ProcessTapAudioFormat(
                sampleRate: 48_000,
                channelCount: 8,
                formatID: kAudioFormatLinearPCM,
                formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                bitsPerChannel: 32,
                interleaving: .interleaved
            )
        )
        let fingerprint = AudioRouteTopologyFingerprint(
            osBuild: "25A1",
            sourceDeviceUIDs: ["Source"],
            selectedTargetUIDs: ["USB"],
            devices: [
                AudioRouteDeviceFingerprint(
                    uid: "USB",
                    modelUID: "Model.USB",
                    driverIdentity: AudioRouteDriverIdentity(
                        plugInBundleID: "com.vendor.driver",
                        availableVersion: nil
                    ),
                    inputStreams: [],
                    outputStreams: [stream],
                    fullSubdeviceUIDs: [],
                    activeSubdeviceUIDs: [],
                    aggregateMainSubdeviceUID: nil,
                    aggregateIsStacked: nil,
                    aggregateTapUUIDs: [],
                    clockDomain: 0,
                    transportType: kAudioDeviceTransportTypeUSB,
                    isAlive: true
                ),
            ]
        )

        let encoded = try JSONEncoder().encode(fingerprint)

        XCTAssertEqual(
            try JSONDecoder().decode(AudioRouteTopologyFingerprint.self, from: encoded),
            fingerprint
        )
    }

    func testOSBuildDecodeUsesReturnedByteCountPrefixBeforeTrimmingNUL() throws {
        let storage = Array("25A1\0stale".utf8).map { CChar(bitPattern: $0) }

        XCTAssertEqual(
            try AudioRouteOSBuild.decode(bytes: storage, returnedByteCount: 5),
            "25A1"
        )
    }
}

@MainActor
private final class MetadataFixture {
    let backend = FakeAudioHALBackend()
    private(set) lazy var service = AudioDeviceVolumeService(
        client: AudioHALClient(backend: backend)
    )
    private var deviceIDs: [AudioDeviceID] = []

    func format(channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    func installDevice(
        id: AudioDeviceID,
        uid: String,
        modelUID: String? = nil,
        inputStreams: [(AudioStreamID, AudioStreamBasicDescription)] = [],
        outputStreams: [(AudioStreamID, AudioStreamBasicDescription)],
        clockDomain: UInt32? = nil,
        transportType: UInt32? = nil,
        ownerID: AudioObjectID? = nil,
        ownerClassID: AudioClassID = kAudioPlugInClassID,
        plugInBundleID: String? = nil
    ) {
        registerDevice(id)
        backend.setString(uid, objectID: id, address: .init(selector: kAudioDevicePropertyDeviceUID))
        backend.setString(uid, objectID: id, address: .init(selector: kAudioObjectPropertyName))
        backend.setScalar(
            UInt32(1),
            objectID: id,
            address: .init(selector: kAudioDevicePropertyDeviceIsAlive)
        )
        installStreams(inputStreams, deviceID: id, scope: kAudioObjectPropertyScopeInput)
        installStreams(outputStreams, deviceID: id, scope: kAudioObjectPropertyScopeOutput)

        if let modelUID {
            backend.setString(
                modelUID,
                objectID: id,
                address: .init(selector: kAudioDevicePropertyModelUID)
            )
        }
        if let clockDomain {
            backend.setScalar(
                clockDomain,
                objectID: id,
                address: .init(selector: kAudioDevicePropertyClockDomain)
            )
        }
        if let transportType {
            backend.setScalar(
                transportType,
                objectID: id,
                address: .init(selector: kAudioDevicePropertyTransportType)
            )
        }
        if let ownerID {
            backend.setOwnerTopology(
                objectID: id,
                ownerID: ownerID,
                ownerClassID: ownerClassID
            )
            if let plugInBundleID {
                backend.setString(
                    plugInBundleID,
                    objectID: ownerID,
                    address: .init(selector: kAudioPlugInPropertyBundleID)
                )
            }
        }
    }

    func installAggregate(
        id: AudioDeviceID,
        fullUIDs: [String],
        activeIDs: [AudioObjectID] = [501],
        activeUIDsByID: [AudioObjectID: String] = [501: "USB"],
        mainUID: String? = nil,
        isStacked: Bool? = nil,
        tapUUIDs: [String] = [],
        omitComposition: Bool = false,
        omitActiveList: Bool = false
    ) {
        installDevice(
            id: id,
            uid: "Aggregate",
            outputStreams: [(id + 1_000, format(channels: 2))]
        )
        backend.setRetainedObject(
            fullUIDs as NSArray,
            objectID: id,
            address: .init(selector: kAudioAggregateDevicePropertyFullSubDeviceList)
        )
        if !omitActiveList {
            backend.setArray(
                activeIDs,
                objectID: id,
                address: .init(selector: kAudioAggregateDevicePropertyActiveSubDeviceList)
            )
        }
        for (memberID, uid) in activeUIDsByID {
            backend.setString(
                uid,
                objectID: memberID,
                address: .init(selector: kAudioDevicePropertyDeviceUID)
            )
        }
        if let mainUID {
            backend.setString(
                mainUID,
                objectID: id,
                address: .init(selector: kAudioAggregateDevicePropertyMainSubDevice)
            )
        }
        if !omitComposition {
            let dictionary: NSDictionary = isStacked.map {
                [kAudioAggregateDeviceIsStackedKey: NSNumber(value: $0)]
            } ?? [:]
            backend.setRetainedObject(
                dictionary,
                objectID: id,
                address: .init(selector: kAudioAggregateDevicePropertyComposition)
            )
        }
        if #available(macOS 14.2, *) {
            backend.setRetainedObject(
                tapUUIDs as NSArray,
                objectID: id,
                address: .init(selector: kAudioAggregateDevicePropertyTapList)
            )
        }
    }

    private func registerDevice(_ id: AudioDeviceID) {
        if !deviceIDs.contains(id) {
            deviceIDs.append(id)
        }
        backend.setArray(
            deviceIDs,
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: .init(selector: kAudioHardwarePropertyDevices)
        )
    }

    private func installStreams(
        _ streams: [(AudioStreamID, AudioStreamBasicDescription)],
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) {
        backend.setArray(
            streams.map(\.0),
            objectID: deviceID,
            address: .init(selector: kAudioDevicePropertyStreams, scope: scope)
        )
        for (streamID, format) in streams {
            backend.setScalar(
                format,
                objectID: streamID,
                address: .init(selector: kAudioStreamPropertyVirtualFormat)
            )
        }
    }
}
