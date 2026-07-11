import AudioToolbox
import CoreAudio
import XCTest
@testable import MacActivityCore

final class AudioRoutePlannerTests: XCTestCase {
    func testFollowOriginalIgnoresDifferentSystemDefault() throws {
        let request = fixtureRequest(
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: "HDMI",
            mode: .followOriginal
        )

        let plan = try AudioRoutePlanner().plan(request)

        XCTAssertEqual(plan.selectedTargetUIDs, ["BuiltIn"])
        XCTAssertEqual(Set(plan.tapSources.map(\.deviceUID)), ["BuiltIn"])
        XCTAssertFalse(plan.selectedTargetUIDs.contains("HDMI"))
    }

    func testFollowOriginalTracksSourceRouteChanges() throws {
        let planner = AudioRoutePlanner()

        let builtInPlan = try planner.plan(fixtureRequest(sourceDeviceUIDs: ["BuiltIn"]))
        let usbPlan = try planner.plan(fixtureRequest(sourceDeviceUIDs: ["USB"]))

        XCTAssertEqual(builtInPlan.selectedTargetUIDs, ["BuiltIn"])
        XCTAssertEqual(builtInPlan.tapSources.map(\.deviceUID), ["BuiltIn"])
        XCTAssertEqual(usbPlan.selectedTargetUIDs, ["USB"])
        XCTAssertEqual(usbPlan.tapSources.map(\.deviceUID), ["USB"])
    }

    func testExplicitRouteIsUnaffectedBySystemDefaultChanges() throws {
        let planner = AudioRoutePlanner()
        let first = try planner.plan(fixtureRequest(
            systemDefaultOutputDeviceUID: "BuiltIn",
            mode: .explicit(targetDeviceUIDs: ["USB"])
        ))
        let second = try planner.plan(fixtureRequest(
            systemDefaultOutputDeviceUID: "HDMI",
            mode: .explicit(targetDeviceUIDs: ["USB"])
        ))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.selectedTargetUIDs, ["USB"])
    }

    func testExplicitTargetsAreExactOrderedAndDeduplicated() throws {
        let plan = try AudioRoutePlanner().plan(fixtureRequest(
            systemDefaultOutputDeviceUID: "DefaultThatMustNotAppear",
            mode: .explicit(targetDeviceUIDs: ["USB", "HDMI", "USB"])
        ))

        XCTAssertEqual(plan.selectedTargetUIDs, ["USB", "HDMI"])
        XCTAssertEqual(plan.subdevices.map(\.uid), ["USB", "HDMI"])
        XCTAssertEqual(plan.mainDeviceUID, "USB")
        XCTAssertEqual(plan.subdevices.map(\.usesDriftCompensation), [false, true])
    }

    func testExplicitMultiDeviceTargetsRetainEachDeviceOutputStreamOrder() throws {
        let usbStreams = [
            AudioRouteStream(streamIndex: 8, format: fixtureFormat(channelCount: 1)),
            AudioRouteStream(streamIndex: 2, format: fixtureFormat(channelCount: 2)),
        ]
        let hdmiStreams = [
            AudioRouteStream(streamIndex: 5, format: fixtureFormat(channelCount: 6)),
        ]
        let plan = try AudioRoutePlanner().plan(fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["HDMI", "USB"]),
            devices: fixtureDevices(
                usbOutputStreams: usbStreams,
                hdmiOutputStreams: hdmiStreams
            )
        ))

        XCTAssertEqual(plan.subdevices.map(\.uid), ["HDMI", "USB"])
        XCTAssertEqual(plan.subdevices.map(\.outputStreams), [hdmiStreams, usbStreams])
    }

    func testAggregateTargetsFlattenWithoutNesting() throws {
        let usbStreams = [
            AudioRouteStream(streamIndex: 4, format: fixtureFormat(channelCount: 2)),
            AudioRouteStream(streamIndex: 1, format: fixtureFormat(channelCount: 1)),
        ]
        let hdmiStreams = [
            AudioRouteStream(streamIndex: 7, format: fixtureFormat(channelCount: 6)),
        ]
        let plan = try AudioRoutePlanner().plan(fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["StudioAggregate"]),
            devices: fixtureDevices(
                usbOutputStreams: usbStreams,
                hdmiOutputStreams: hdmiStreams
            )
        ))

        XCTAssertEqual(plan.selectedTargetUIDs, ["StudioAggregate"])
        XCTAssertEqual(plan.subdevices.map(\.uid), ["USB", "HDMI"])
        XCTAssertEqual(plan.subdevices.map(\.outputStreams), [usbStreams, hdmiStreams])
    }

    func testNestedAggregatesFlattenInStableOrderAndDeduplicateLeaves() throws {
        let devices = fixtureDevices() + [
            fixtureDevice(
                objectID: 50,
                uid: "NestedAggregate",
                isAggregate: true,
                aggregateSubdeviceUIDs: ["StudioAggregate", "USB", "BuiltIn"]
            ),
        ]

        let plan = try AudioRoutePlanner().plan(fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["NestedAggregate", "HDMI"]),
            devices: devices
        ))

        XCTAssertEqual(plan.selectedTargetUIDs, ["NestedAggregate", "HDMI"])
        XCTAssertEqual(plan.subdevices.map(\.uid), ["USB", "HDMI", "BuiltIn"])
        XCTAssertEqual(plan.subdevices.map(\.usesDriftCompensation), [false, true, true])
    }

    func testEmptyExplicitTargetsAreRejected() {
        assertPlanningError(
            .emptyExplicitTargets,
            request: fixtureRequest(mode: .explicit(targetDeviceUIDs: []))
        )
    }

    func testEmptySourceRouteIsRejected() {
        assertPlanningError(
            .noSourceRoute,
            request: fixtureRequest(sourceDeviceUIDs: [])
        )
    }

    func testMissingAndUnavailableTargetsAreRejected() {
        assertPlanningError(
            .missingDevice("Missing"),
            request: fixtureRequest(mode: .explicit(targetDeviceUIDs: ["Missing"]))
        )

        let devices = fixtureDevices() + [
            fixtureDevice(objectID: 60, uid: "Disconnected", isAlive: false),
        ]
        assertPlanningError(
            .unavailableDevice("Disconnected"),
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["Disconnected"]),
                devices: devices
            )
        )
    }

    func testMissingAndUnavailableSourcesAreRejected() {
        assertPlanningError(
            .missingDevice("MissingSource"),
            request: fixtureRequest(
                sourceDeviceUIDs: ["MissingSource"],
                mode: .explicit(targetDeviceUIDs: ["USB"])
            )
        )

        let devices = fixtureDevices() + [
            fixtureDevice(objectID: 61, uid: "DeadSource", isAlive: false),
        ]
        assertPlanningError(
            .unavailableDevice("DeadSource"),
            request: fixtureRequest(
                sourceDeviceUIDs: ["DeadSource"],
                mode: .explicit(targetDeviceUIDs: ["USB"]),
                devices: devices
            )
        )
    }

    func testAggregateCycleIsRejected() {
        let devices = fixtureDevices() + [
            fixtureDevice(
                objectID: 70,
                uid: "AggregateA",
                isAggregate: true,
                aggregateSubdeviceUIDs: ["AggregateB"]
            ),
            fixtureDevice(
                objectID: 71,
                uid: "AggregateB",
                isAggregate: true,
                aggregateSubdeviceUIDs: ["AggregateA"]
            ),
        ]

        assertPlanningError(
            .recursiveAggregate("AggregateA"),
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["AggregateA"]),
                devices: devices
            )
        )
    }

    func testAggregateWithMissingOrNoChildrenIsRejected() {
        let missingChildDevices = fixtureDevices() + [
            fixtureDevice(
                objectID: 72,
                uid: "BrokenAggregate",
                isAggregate: true,
                aggregateSubdeviceUIDs: ["MissingChild"]
            ),
        ]
        assertPlanningError(
            .missingDevice("MissingChild"),
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["BrokenAggregate"]),
                devices: missingChildDevices
            )
        )

        let emptyAggregateDevices = fixtureDevices() + [
            fixtureDevice(
                objectID: 73,
                uid: "EmptyAggregate",
                isAggregate: true,
                aggregateSubdeviceUIDs: []
            ),
        ]
        assertPlanningError(
            .missingDevice("EmptyAggregate"),
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["EmptyAggregate"]),
                devices: emptyAggregateDevices
            )
        )
    }

    func testMacActivityOwnedAggregateSelectionIsRejected() {
        let uid = AudioRoutePlanner.aggregateUIDPrefix + "existing"

        assertPlanningError(
            .macActivityAggregateSelected(uid),
            request: fixtureRequest(mode: .explicit(targetDeviceUIDs: [uid]))
        )
    }

    func testMacActivityOwnedUIDOutsideAggregateNamespaceIsRejected() {
        let uid = "com.how.macactivity.audio.legacy-output"
        let devices = fixtureDevices() + [
            fixtureDevice(objectID: 74, uid: uid),
        ]

        assertPlanningError(
            .macActivityAggregateSelected(uid),
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: [uid]),
                devices: devices
            )
        )
    }

    func testAggregateChildInMacActivityOwnedNamespaceIsRejected() {
        let ownedUID = "com.how.macactivity.audio.legacy-output"
        let devices = fixtureDevices() + [
            fixtureDevice(objectID: 74, uid: ownedUID),
            fixtureDevice(
                objectID: 75,
                uid: "UserAggregate",
                isAggregate: true,
                aggregateSubdeviceUIDs: ["USB", ownedUID]
            ),
        ]

        assertPlanningError(
            .macActivityAggregateSelected(ownedUID),
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["UserAggregate"]),
                devices: devices
            )
        )
    }

    func testNonFloat32SourceStreamIsRejected() {
        let devices = fixtureDevices() + [
            fixtureDevice(
                objectID: 80,
                uid: "IntegerSource",
                format: fixtureFormat(isFloat32: false)
            ),
        ]

        assertPlanningError(
            .unsupportedFormat(deviceUID: "IntegerSource", streamIndex: 0),
            request: fixtureRequest(
                sourceDeviceUIDs: ["IntegerSource"],
                mode: .explicit(targetDeviceUIDs: ["USB"]),
                devices: devices
            )
        )
    }

    func testNonFloat32TargetStreamIsRejected() {
        let devices = fixtureDevices() + [
            fixtureDevice(
                objectID: 81,
                uid: "IntegerTarget",
                format: fixtureFormat(isFloat32: false)
            ),
        ]

        assertPlanningError(
            .unsupportedFormat(deviceUID: "IntegerTarget", streamIndex: 0),
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["IntegerTarget"]),
                devices: devices
            )
        )
    }

    func testIncompatibleTargetSampleRateIsRejected() {
        let devices = fixtureDevices() + [
            fixtureDevice(
                objectID: 82,
                uid: "DifferentRate",
                format: fixtureFormat(sampleRate: 44_100)
            ),
        ]

        assertPlanningError(
            .incompatibleTarget(deviceUID: "DifferentRate"),
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["USB", "DifferentRate"]),
                devices: devices
            )
        )
    }

    func testTargetSampleRatesWithinToleranceAreCompatible() throws {
        let devices = fixtureDevices() + [
            fixtureDevice(
                objectID: 83,
                uid: "ToleranceTarget",
                format: fixtureFormat(sampleRate: 48_000.49)
            ),
        ]

        let plan = try AudioRoutePlanner().plan(fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["USB", "ToleranceTarget"]),
            devices: devices
        ))

        XCTAssertEqual(plan.subdevices.map(\.uid), ["USB", "ToleranceTarget"])
    }

    func testTargetWithoutOutputStreamsIsIncompatible() {
        let devices = fixtureDevices() + [
            fixtureDevice(objectID: 84, uid: "NoStreams", outputStreams: [])
        ]

        assertPlanningError(
            .incompatibleTarget(deviceUID: "NoStreams"),
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["NoStreams"]),
                devices: devices
            )
        )
    }

    func testPlanIdentityAndAggregateUIDAreDeterministic() throws {
        let request = fixtureRequest(processObjectID: 77, generation: 9)
        let planner = AudioRoutePlanner()

        let first = try planner.plan(request)
        let second = try planner.plan(request)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.processObjectID, 77)
        XCTAssertEqual(first.generation, 9)
        XCTAssertEqual(
            first.aggregateUID,
            AudioRoutePlanner.aggregateUIDPrefix + "77.9"
        )
        XCTAssertTrue(first.isStacked)
    }

    @MainActor
    func testDeviceProviderReadsLiveRouteDescriptorsThroughHALClient() throws {
        let backend = FakeAudioHALBackend()
        let devicesAddress = AudioHALPropertyAddress(selector: kAudioHardwarePropertyDevices)
        let streamsAddress = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        )
        let uidAddress = AudioHALPropertyAddress(selector: kAudioDevicePropertyDeviceUID)
        let nameAddress = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        let aliveAddress = AudioHALPropertyAddress(selector: kAudioDevicePropertyDeviceIsAlive)
        let aggregateAddress = AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyActiveSubDeviceList
        )
        let formatAddress = AudioHALPropertyAddress(selector: kAudioStreamPropertyVirtualFormat)

        backend.setArray(
            [AudioDeviceID(10), 20, 40],
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: devicesAddress
        )
        configureRouteDevice(
            backend,
            objectID: 10,
            streamID: 110,
            uid: "BuiltIn",
            name: "MacBook Speakers",
            isAlive: true,
            streamsAddress: streamsAddress,
            uidAddress: uidAddress,
            nameAddress: nameAddress,
            aliveAddress: aliveAddress,
            formatAddress: formatAddress
        )
        configureRouteDevice(
            backend,
            objectID: 20,
            streamID: 120,
            uid: "USB",
            name: "USB Interface",
            isAlive: false,
            streamsAddress: streamsAddress,
            uidAddress: uidAddress,
            nameAddress: nameAddress,
            aliveAddress: aliveAddress,
            formatAddress: formatAddress
        )
        configureRouteDevice(
            backend,
            objectID: 40,
            streamID: 140,
            uid: "StudioAggregate",
            name: "Studio Aggregate",
            isAlive: true,
            interleaving: .nonInterleaved,
            streamsAddress: streamsAddress,
            uidAddress: uidAddress,
            nameAddress: nameAddress,
            aliveAddress: aliveAddress,
            formatAddress: formatAddress
        )
        backend.setArray(
            [AudioObjectID(20), 10],
            objectID: 40,
            address: aggregateAddress
        )

        let service = AudioDeviceVolumeService(client: AudioHALClient(backend: backend))
        let descriptors = try service.routeDevices()

        XCTAssertEqual(descriptors.map(\.uid), ["BuiltIn", "USB", "StudioAggregate"])
        XCTAssertEqual(descriptors.map(\.isAlive), [true, false, true])
        XCTAssertEqual(descriptors.map(\.isAggregate), [false, false, true])
        XCTAssertEqual(descriptors[2].aggregateSubdeviceUIDs, ["USB", "BuiltIn"])
        XCTAssertEqual(descriptors[0].outputStreams.map(\.streamIndex), [0])
        XCTAssertEqual(descriptors[0].outputStreams[0].format, fixtureFormat())
        XCTAssertEqual(
            descriptors[2].outputStreams[0].format.interleaving,
            .nonInterleaved
        )
        XCTAssertTrue(backend.readSelectors.contains(kAudioStreamPropertyVirtualFormat))
        XCTAssertTrue(backend.writeSelectors.isEmpty)
    }
}

private extension AudioRoutePlannerTests {
    func fixtureRequest(
        processObjectID: AudioObjectID = 42,
        generation: UInt64 = 3,
        sourceDeviceUIDs: [String] = ["BuiltIn"],
        systemDefaultOutputDeviceUID: String? = "HDMI",
        mode: AudioRouteMode = .followOriginal,
        devices: [AudioRouteDevice]? = nil
    ) -> AudioRouteRequest {
        AudioRouteRequest(
            processObjectID: processObjectID,
            generation: generation,
            sourceDeviceUIDs: sourceDeviceUIDs,
            systemDefaultOutputDeviceUID: systemDefaultOutputDeviceUID,
            mode: mode,
            devices: devices ?? fixtureDevices()
        )
    }

    func fixtureDevices(
        usbOutputStreams: [AudioRouteStream]? = nil,
        hdmiOutputStreams: [AudioRouteStream]? = nil
    ) -> [AudioRouteDevice] {
        [
            fixtureDevice(objectID: 10, uid: "BuiltIn", name: "MacBook Speakers"),
            fixtureDevice(
                objectID: 20,
                uid: "USB",
                name: "USB Interface",
                outputStreams: usbOutputStreams
            ),
            fixtureDevice(
                objectID: 30,
                uid: "HDMI",
                name: "Display Audio",
                outputStreams: hdmiOutputStreams
            ),
            fixtureDevice(
                objectID: 40,
                uid: "StudioAggregate",
                name: "Studio Aggregate",
                isAggregate: true,
                aggregateSubdeviceUIDs: ["USB", "HDMI"]
            ),
        ]
    }

    func fixtureDevice(
        objectID: AudioObjectID,
        uid: String,
        name: String? = nil,
        isAlive: Bool = true,
        isAggregate: Bool = false,
        aggregateSubdeviceUIDs: [String] = [],
        format: ProcessTapAudioFormat? = nil,
        outputStreams: [AudioRouteStream]? = nil
    ) -> AudioRouteDevice {
        AudioRouteDevice(
            objectID: objectID,
            uid: uid,
            name: name ?? uid,
            isAlive: isAlive,
            isAggregate: isAggregate,
            aggregateSubdeviceUIDs: aggregateSubdeviceUIDs,
            outputStreams: outputStreams ?? [
                AudioRouteStream(streamIndex: 0, format: format ?? fixtureFormat()),
            ]
        )
    }

    func fixtureFormat(
        sampleRate: Double = 48_000,
        isFloat32: Bool = true,
        channelCount: Int = 2,
        interleaving: AudioPCMInterleaving = .interleaved
    ) -> ProcessTapAudioFormat {
        ProcessTapAudioFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            formatID: kAudioFormatLinearPCM,
            formatFlags: isFloat32
                ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            bitsPerChannel: 32,
            interleaving: interleaving
        )
    }

    func assertPlanningError(
        _ expected: AudioRoutePlanningError,
        request: AudioRouteRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AudioRoutePlanner().plan(request),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AudioRoutePlanningError,
                expected,
                file: file,
                line: line
            )
        }
    }

    func configureRouteDevice(
        _ backend: FakeAudioHALBackend,
        objectID: AudioDeviceID,
        streamID: AudioStreamID,
        uid: String,
        name: String,
        isAlive: Bool,
        interleaving: AudioPCMInterleaving = .interleaved,
        streamsAddress: AudioHALPropertyAddress,
        uidAddress: AudioHALPropertyAddress,
        nameAddress: AudioHALPropertyAddress,
        aliveAddress: AudioHALPropertyAddress,
        formatAddress: AudioHALPropertyAddress
    ) {
        backend.setArray([streamID], objectID: objectID, address: streamsAddress)
        backend.setString(uid, objectID: objectID, address: uidAddress)
        backend.setString(name, objectID: objectID, address: nameAddress)
        backend.setScalar(UInt32(isAlive ? 1 : 0), objectID: objectID, address: aliveAddress)

        let nonInterleavedFlag: AudioFormatFlags = interleaving == .nonInterleaved
            ? kAudioFormatFlagIsNonInterleaved
            : 0
        backend.setScalar(
            AudioStreamBasicDescription(
                mSampleRate: 48_000,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat
                    | kAudioFormatFlagIsPacked
                    | nonInterleavedFlag,
                mBytesPerPacket: interleaving == .nonInterleaved ? 4 : 8,
                mFramesPerPacket: 1,
                mBytesPerFrame: interleaving == .nonInterleaved ? 4 : 8,
                mChannelsPerFrame: 2,
                mBitsPerChannel: 32,
                mReserved: 0
            ),
            objectID: streamID,
            address: formatAddress
        )
    }
}
