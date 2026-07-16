import CoreAudio
import Foundation
import XCTest
@testable import MacActivityCore

final class AudioTapHardwareDescriptionTests: XCTestCase {
    @available(macOS 14.2, *)
    func testConfigureInputStreamUsageWritesAndReadsBackExactFlags() throws {
        let backend = FakeAudioHALBackend()
        let ioProc = AudioIOProcResource(
            aggregateDeviceID: 700,
            aggregateUID: "aggregate",
            ioProcID: hardwareBoundaryIOProcID
        )
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyIOProcStreamUsage,
            scope: kAudioObjectPropertyScopeInput
        )
        backend.setRawBytes(
            AudioIOProcStreamUsage.withEncoded(ioProcID: ioProc.ioProcID, flags: [0]) {
                Array($0)
            },
            objectID: ioProc.aggregateDeviceID,
            address: address,
            isSettable: true
        )

        XCTAssertEqual(
            try makeHardware(backend).configureInputStreamUsage([1], for: ioProc),
            [1]
        )
        XCTAssertEqual(
            backend.writeSelectors,
            [kAudioDevicePropertyIOProcStreamUsage]
        )
        XCTAssertEqual(
            backend.dataReadCount(for: kAudioDevicePropertyIOProcStreamUsage),
            1
        )
    }

    @available(macOS 14.2, *)
    func testConfigureInputStreamUsagePreservesTransientSettableQueryStatus() {
        let backend = FakeAudioHALBackend()
        let ioProc = AudioIOProcResource(
            aggregateDeviceID: 700,
            aggregateUID: "aggregate",
            ioProcID: hardwareBoundaryIOProcID
        )
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyIOProcStreamUsage,
            scope: kAudioObjectPropertyScopeInput
        )
        backend.setRawBytes(
            AudioIOProcStreamUsage.withEncoded(ioProcID: ioProc.ioProcID, flags: [0]) {
                Array($0)
            },
            objectID: ioProc.aggregateDeviceID,
            address: address,
            isSettable: true
        )
        backend.enqueueIsSettableStatuses([-321])

        XCTAssertThrowsError(
            try makeHardware(backend).configureInputStreamUsage([1], for: ioProc)
        ) { error in
            XCTAssertEqual(
                error as? AudioHALError,
                AudioHALError(
                    operation: .isSettable,
                    objectID: ioProc.aggregateDeviceID,
                    address: address,
                    reason: .status(-321)
                )
            )
        }
        XCTAssertTrue(backend.writeSelectors.isEmpty)
    }

    @available(macOS 14.2, *)
    func testIdentityCheckedMutationsDoNotTouchReplacementObjects() {
        let backend = FakeAudioHALBackend()
        let tap = fixtureTap(objectID: 71)
        let aggregate = AudioAggregateResource(objectID: 80, uid: "owned")
        let ioProc = AudioIOProcResource(
            aggregateDeviceID: aggregate.objectID,
            aggregateUID: aggregate.uid,
            ioProcID: hardwareBoundaryIOProcID
        )
        configureDestroyIdentity(
            backend,
            id: tap.objectID,
            classID: kAudioTapClassID,
            uid: UUID().uuidString
        )
        configureDestroyIdentity(
            backend,
            id: aggregate.objectID,
            classID: kAudioAggregateDeviceClassID,
            uid: "replacement"
        )
        let hardware = makeHardware(backend)

        XCTAssertEqual(hardware.restoreOriginalAudio(for: tap), noErr)
        XCTAssertEqual(hardware.stop(ioProc), noErr)
        XCTAssertEqual(hardware.destroyIOProc(ioProc), noErr)
        XCTAssertEqual(hardware.destroyAggregate(aggregate), noErr)
        XCTAssertEqual(hardware.destroyTap(tap), noErr)
        XCTAssertTrue(backend.objectWrites.isEmpty)
        XCTAssertTrue(backend.mutableOperations.isEmpty)
    }


    @available(macOS 14.2, *)
    func testStableTopologyTimeoutPreservesLastRawReadStatus() {
        let backend = FakeAudioHALBackend()
        let aggregate = AudioAggregateResource(objectID: 703, uid: "aggregate")
        backend.setReadError(
            -777,
            objectID: aggregate.objectID,
            address: streamListAddress(scope: kAudioObjectPropertyScopeInput),
            announcedByteCount: UInt32(MemoryLayout<AudioStreamID>.size)
        )

        XCTAssertThrowsError(try makeHardware(backend).waitForStableTopology(
            aggregate,
            deadline: .now() + .milliseconds(15),
            isCancelled: { false }
        )) { error in
            XCTAssertEqual(
                error as? AudioTapHardwareError,
                .aggregateNotReady(lastStatus: -777)
            )
        }
    }
    @available(macOS 14.2, *)
    func testTwoDeviceDescriptionUsesExactTargetsMainDeviceDriftAndTapDictionaries() throws {
        let plan = fixturePlan(
            targets: ["USB", "HDMI"],
            tapSources: [AudioTapSource(
                deviceUID: "Source.Device",
                streamIndex: 0,
                expectedFormat: fixtureFormat(),
                driftCompensation: .highQuality
            )],
            targetInputStreams: [
                [AudioRouteStream(
                    streamObjectID: 801,
                    streamIndex: 1,
                    format: fixtureFormat(channelCount: 2)
                )],
                [AudioRouteStream(
                    streamObjectID: 802,
                    streamIndex: 2,
                    format: fixtureFormat(channelCount: 4)
                )],
            ],
            targetOutputStreams: [
                [AudioRouteStream(
                    streamObjectID: 901,
                    streamIndex: 1,
                    format: fixtureFormat(channelCount: 8)
                )],
                [AudioRouteStream(
                    streamObjectID: 902,
                    streamIndex: 2,
                    format: fixtureFormat(channelCount: 2)
                )],
            ]
        )
        let tapUUID = UUID(uuidString: "4D414341-0000-4000-8000-000000000001")!

        let description = try CoreAudioTapHardware.aggregateDescription(
            plan: plan,
            tapUUID: tapUUID
        ) as NSDictionary

        XCTAssertEqual(description[kAudioAggregateDeviceUIDKey] as? String, plan.aggregateUID)
        XCTAssertEqual(
            description[kAudioAggregateDeviceNameKey] as? String,
            "MacActivity Audio Aggregate 91.4"
        )
        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "USB")
        XCTAssertNil(description[kAudioAggregateDeviceClockDeviceKey])
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertNil(description[kAudioAggregateDeviceTapAutoStartKey])

        let subdevices = try dictionaries(
            in: description,
            key: kAudioAggregateDeviceSubDeviceListKey
        )
        XCTAssertEqual(
            subdevices.map { $0[kAudioSubDeviceUIDKey] as? String },
            ["USB", "HDMI"]
        )
        XCTAssertEqual(
            subdevices.map { ($0[kAudioSubDeviceInputChannelsKey] as? NSNumber)?.intValue },
            [0, 0]
        )
        XCTAssertEqual(
            subdevices.map { ($0[kAudioSubDeviceOutputChannelsKey] as? NSNumber)?.intValue },
            [8, 2]
        )
        XCTAssertEqual(
            subdevices.map { $0[kAudioSubDeviceDriftCompensationKey] as? Bool },
            [false, true]
        )
        XCTAssertNil(subdevices[0][kAudioSubDeviceDriftCompensationQualityKey])
        XCTAssertEqual(
            subdevices[1][kAudioSubDeviceDriftCompensationQualityKey] as? UInt32,
            kAudioAggregateDriftCompensationHighQuality
        )

        let taps = try dictionaries(in: description, key: kAudioAggregateDeviceTapListKey)
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(
            taps.map { $0[kAudioSubTapUIDKey] as? String },
            [tapUUID.uuidString]
        )
        XCTAssertEqual(taps[0][kAudioSubTapDriftCompensationKey] as? Bool, true)
        XCTAssertEqual(
            taps[0][kAudioSubTapDriftCompensationQualityKey] as? UInt32,
            kAudioAggregateDriftCompensationHighQuality
        )
    }

    @available(macOS 14.2, *)
    func testSourceTapDescriptionPreservesSourceAndUsesPrivateUnmutedReservedUUID() throws {
        let source = fixtureSource(deviceUID: "Source.Device", streamIndex: 7)

        let description: CATapDescription = CoreAudioTapHardware.tapDescription(
            processObjectID: 91,
            source: source
        )

        XCTAssertEqual(description.processes, [91])
        XCTAssertEqual(description.deviceUID, "Source.Device")
        XCTAssertEqual(description.stream, 7)
        XCTAssertTrue(description.isPrivate)
        XCTAssertEqual(description.muteBehavior, CATapMuteBehavior.unmuted)
        XCTAssertEqual(
            description.name,
            "MacActivity Audio Tap \(description.uuid.uuidString)"
        )
        XCTAssertTrue(description.uuid.uuidString.hasPrefix("4D414341-"))
    }


    @available(macOS 14.2, *)
    func testAggregateDescriptionRejectsInvalidTapCardinalityAndEmptyTopology() {
        let source = fixtureSource(deviceUID: "Source.Device", streamIndex: 0)
        let invalidPlans = [
            fixturePlan(targets: [], tapSources: []),
            fixturePlan(targets: ["USB"], tapSources: [source, source]),
        ]

        for plan in invalidPlans {
            XCTAssertThrowsError(try CoreAudioTapHardware.aggregateDescription(
                plan: plan,
                tapUUID: UUID()
            )) { error in
                XCTAssertEqual(
                    error as? AudioAggregateTopologyError,
                    .unsupportedTopology
                )
            }
        }
    }

    @available(macOS 14.2, *)
    func testDisabledSubTapOmitsDriftQuality() throws {
        let description = try CoreAudioTapHardware.aggregateDescription(
            plan: fixturePlan(targets: ["USB"]),
            tapUUID: UUID(uuidString: "4D414341-0000-4000-8000-000000000001")!
        ) as NSDictionary
        let taps = try dictionaries(
            in: description,
            key: kAudioAggregateDeviceTapListKey
        )

        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps[0][kAudioSubTapDriftCompensationKey] as? Bool, false)
        XCTAssertNil(taps[0][kAudioSubTapDriftCompensationQualityKey])
    }


    @available(macOS 14.2, *)
    func testInstanceCreateTapUsesSourceDescriptionAndReturnsCreatedIdentity() throws {
        let backend = FakeAudioHALBackend()
        backend.nextProcessTapID = 701
        let source = fixtureSource(deviceUID: "Source.Device", streamIndex: 7)
        let hardware = makeHardware(backend)

        let tap = try hardware.createTap(
            processObjectID: 91,
            source: source,
            uuid: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        )

        let descriptions: [CATapDescription] = backend.createdProcessTapDescriptions
        let description = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(description.processes, [91])
        XCTAssertEqual(description.deviceUID, source.deviceUID)
        XCTAssertEqual(description.stream, source.streamIndex)
        XCTAssertFalse(description.isMixdown)
        XCTAssertTrue(description.isPrivate)
        XCTAssertEqual(description.muteBehavior, CATapMuteBehavior.unmuted)
        XCTAssertTrue(description.uuid.uuidString.hasPrefix("4D414341-"))
        XCTAssertEqual(
            tap,
            AudioTapResource(objectID: 701, uuid: description.uuid, source: source)
        )
    }

    @available(macOS 14.2, *)
    func testInstanceCreateTapChecksAvailabilityBeforeMutableHAL() {
        let backend = FakeAudioHALBackend()
        let hardware = makeHardware(backend, processTapsAvailable: false)

        XCTAssertThrowsError(
            try hardware.createTap(
                processObjectID: 91,
                source: fixtureSource(deviceUID: "Source.Device", streamIndex: 0),
                uuid: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioHALError,
                AudioHALError(
                    operation: .createTap,
                    objectID: kAudioObjectUnknown,
                    address: nil,
                    reason: .processTapsUnavailable
                )
            )
        }
        XCTAssertTrue(backend.mutableOperations.isEmpty)
    }

    @available(macOS 14.2, *)
    func testInstanceTapFormatReadsExactTapFormatASBD() throws {
        let backend = FakeAudioHALBackend()
        let tap = fixtureTap(objectID: 702)
        let address = AudioHALPropertyAddress(selector: kAudioTapPropertyFormat)
        backend.setScalar(
            fixtureASBD(
                sampleRate: 96_000,
                channelCount: 6,
                formatFlags: kAudioFormatFlagIsFloat
                    | kAudioFormatFlagIsPacked
                    | kAudioFormatFlagIsNonInterleaved
            ),
            objectID: tap.objectID,
            address: address
        )

        let format = try makeHardware(backend).readTapFormat(tap)

        XCTAssertEqual(
            format,
            fixtureFormat(
                sampleRate: 96_000,
                channelCount: 6,
                interleaving: .nonInterleaved
            )
        )
        XCTAssertEqual(backend.readSelectors, [kAudioTapPropertyFormat])
    }

    @available(macOS 14.2, *)
    func testTapFormatRejects257ChannelASBDBeforeMutableOperation() {
        let backend = FakeAudioHALBackend()
        let tap = fixtureTap(objectID: 702)
        backend.setScalar(
            fixtureASBD(channelCount: 257),
            objectID: tap.objectID,
            address: AudioHALPropertyAddress(selector: kAudioTapPropertyFormat)
        )

        XCTAssertThrowsError(try makeHardware(backend).readTapFormat(tap)) { error in
            XCTAssertTrue(error is CoreAudioTapHardware.ValidationError)
        }
        XCTAssertTrue(backend.mutableOperations.isEmpty)
    }

    @available(macOS 14.2, *)
    func testInstanceMuteStateReadReturnsOnlyObservedTapStateWithoutWriting() throws {
        let backend = FakeAudioHALBackend()
        let tap = fixtureTap(objectID: 705)
        let address = AudioHALPropertyAddress(selector: kAudioTapPropertyDescription)
        let description = CATapDescription(
            processes: [91],
            deviceUID: tap.source.deviceUID,
            stream: tap.source.streamIndex
        )
        description.uuid = tap.uuid
        description.muteBehavior = .mutedWhenTapped
        configureDestroyIdentity(
            backend,
            id: tap.objectID,
            classID: kAudioTapClassID,
            uid: tap.uuid.uuidString
        )
        backend.setRetainedObject(description, objectID: tap.objectID, address: address)

        let state = try makeHardware(backend).readMuteState(for: tap)

        XCTAssertEqual(state, .mutedWhenTapped)
        XCTAssertEqual(
            backend.readSelectors,
            [
                kAudioObjectPropertyClass,
                kAudioTapPropertyUID,
                kAudioTapPropertyDescription,
            ]
        )
        XCTAssertTrue(backend.writeSelectors.isEmpty)
        XCTAssertTrue(backend.objectWrites.isEmpty)
    }

    @available(macOS 14.2, *)
    func testInstanceMuteStateReadDoesNotTouchReplacementTap() {
        let backend = FakeAudioHALBackend()
        let tap = fixtureTap(objectID: 706)
        configureDestroyIdentity(
            backend,
            id: tap.objectID,
            classID: kAudioTapClassID,
            uid: UUID().uuidString
        )

        XCTAssertThrowsError(try makeHardware(backend).readMuteState(for: tap)) { error in
            XCTAssertEqual(
                error as? AudioHALError,
                AudioHALError(
                    operation: .getData,
                    objectID: tap.objectID,
                    address: nil,
                    reason: .missingValue
                )
            )
        }
        XCTAssertEqual(
            backend.readSelectors,
            [kAudioObjectPropertyClass, kAudioTapPropertyUID]
        )
        XCTAssertTrue(backend.writeSelectors.isEmpty)
        XCTAssertTrue(backend.objectWrites.isEmpty)
    }

    @available(macOS 14.2, *)
    func testInstanceMuteStateReadRejectsUnsupportedObservedMuteBehavior() {
        let backend = FakeAudioHALBackend()
        let tap = fixtureTap(objectID: 707)
        let address = AudioHALPropertyAddress(selector: kAudioTapPropertyDescription)
        let description = CATapDescription(
            processes: [91],
            deviceUID: tap.source.deviceUID,
            stream: tap.source.streamIndex
        )
        description.uuid = tap.uuid
        description.muteBehavior = .muted
        configureDestroyIdentity(
            backend,
            id: tap.objectID,
            classID: kAudioTapClassID,
            uid: tap.uuid.uuidString
        )
        backend.setRetainedObject(description, objectID: tap.objectID, address: address)

        XCTAssertThrowsError(try makeHardware(backend).readMuteState(for: tap)) { error in
            XCTAssertEqual(
                error as? AudioHALError,
                AudioHALError(
                    operation: .getData,
                    objectID: tap.objectID,
                    address: address,
                    reason: .missingValue
                )
            )
        }
        XCTAssertTrue(backend.writeSelectors.isEmpty)
        XCTAssertTrue(backend.objectWrites.isEmpty)
    }

    @available(macOS 14.2, *)
    func testInstanceAggregateCreationUsesTapDictionariesAndReturnedID() throws {
        let backend = FakeAudioHALBackend()
        backend.nextAggregateDeviceID = 703
        let plan = fixturePlan(targets: ["USB", "HDMI"])
        let taps = [
            fixtureTap(
                objectID: 31,
                uuid: UUID(uuidString: "4D414341-0000-4000-8000-000000000031")!
            ),
        ]

        let aggregate = try makeHardware(backend).createAggregate(plan: plan, taps: taps)

        XCTAssertEqual(
            aggregate,
            AudioAggregateResource(objectID: 703, uid: plan.aggregateUID)
        )
        let descriptions: [CFDictionary] = backend.createdAggregateDeviceDescriptions
        let description = try XCTUnwrap(descriptions.first) as NSDictionary
        let tapDictionaries = try dictionaries(
            in: description,
            key: kAudioAggregateDeviceTapListKey
        )
        XCTAssertEqual(
            tapDictionaries.map { $0[kAudioSubTapUIDKey] as? String },
            taps.map(\.uuid.uuidString)
        )
    }

    @available(macOS 14.2, *)
    func testAggregateCreationRejectsTapResourceMismatchBeforeMutableHAL() {
        let validPlan = fixturePlan(targets: ["USB"])
        let validSource = validPlan.tapSources[0]
        let wrongSource = fixtureSource(deviceUID: "Wrong.Source", streamIndex: 9)
        let multiSourcePlan = fixturePlan(
            targets: ["USB"],
            tapSources: [validSource, wrongSource]
        )
        let cases: [(AudioRoutePlan, [AudioTapResource])] = [
            (validPlan, []),
            (validPlan, [
                fixtureTap(objectID: 31, source: validSource),
                fixtureTap(objectID: 32, source: validSource),
            ]),
            (validPlan, [fixtureTap(objectID: 33, source: wrongSource)]),
            (multiSourcePlan, [fixtureTap(objectID: 34, source: validSource)]),
        ]

        for (plan, taps) in cases {
            let backend = FakeAudioHALBackend()
            XCTAssertThrowsError(
                try makeHardware(backend).createAggregate(plan: plan, taps: taps)
            ) { error in
                XCTAssertEqual(
                    error as? CoreAudioTapHardware.ValidationError,
                    .tapResourcesMismatch
                )
            }
            XCTAssertTrue(backend.mutableOperations.isEmpty)
        }
    }

    @available(macOS 14.2, *)
    func testDescriptionAndAggregateRejectMalformedPlanBeforeMutableHAL() {
        let source = fixtureSource(deviceUID: "Source.Device", streamIndex: 0)
        let emptyTopology = fixturePlan(targets: [], tapSources: [source])
        let emptySubdevice = fixturePlan(
            targets: ["USB"],
            tapSources: [source],
            targetOutputStreams: [[]]
        )
        let zeroChannel = fixturePlan(
            targets: ["USB"],
            tapSources: [source],
            targetOutputStreams: [[AudioRouteStream(
                streamObjectID: 901,
                streamIndex: 0,
                format: fixtureFormat(channelCount: 0)
            )]]
        )
        let overflowingChannels = fixturePlan(
            targets: ["USB"],
            tapSources: [source],
            targetOutputStreams: [[
                AudioRouteStream(
                    streamObjectID: 902,
                    streamIndex: 0,
                    format: fixtureFormat(channelCount: Int.max)
                ),
                AudioRouteStream(
                    streamObjectID: 903,
                    streamIndex: 1,
                    format: fixtureFormat(channelCount: 1)
                ),
            ]]
        )

        for plan in [emptyTopology, emptySubdevice, zeroChannel, overflowingChannels] {
            XCTAssertThrowsError(try CoreAudioTapHardware.aggregateDescription(
                plan: plan,
                tapUUID: UUID()
            )) { error in
                XCTAssertEqual(
                    error as? AudioAggregateTopologyError,
                    .unsupportedTopology
                )
            }

            let backend = FakeAudioHALBackend()
            XCTAssertThrowsError(try makeHardware(backend).createAggregate(
                plan: plan,
                taps: [fixtureTap(objectID: 35, source: source)]
            )) { error in
                XCTAssertEqual(
                    error as? AudioAggregateTopologyError,
                    .unsupportedTopology
                )
            }
            XCTAssertTrue(backend.mutableOperations.isEmpty)
        }
    }

    @available(macOS 14.2, *)
    func testInstanceReadinessUsesAliveAndInputOutputStreamsAndCancellationShortCircuits() throws {
        let backend = FakeAudioHALBackend()
        let aggregate = AudioAggregateResource(objectID: 704, uid: "aggregate")
        configureAggregateStreams(
            backend,
            aggregateID: aggregate.objectID,
            input: [(41, fixtureFormat(channelCount: 2))],
            output: [(42, fixtureFormat(channelCount: 2))]
        )
        let hardware = makeHardware(backend)

        let snapshot = try hardware.waitForStableTopology(
            aggregate,
            deadline: .now() + .seconds(1),
            isCancelled: { false }
        )
        XCTAssertEqual(snapshot.inputStreamIDs, [41])
        XCTAssertEqual(snapshot.outputStreamIDs, [42])
        XCTAssertGreaterThanOrEqual(
            backend.dataReadCount(for: kAudioDevicePropertyDeviceIsAlive),
            2
        )
        XCTAssertFalse(backend.readSelectors.contains(kAudioStreamPropertyIsActive))

        let cancelledBackend = FakeAudioHALBackend()
        XCTAssertThrowsError(try makeHardware(cancelledBackend).waitForStableTopology(
            aggregate, deadline: .now() + .seconds(30), isCancelled: { true }
        )) { error in
            XCTAssertEqual(error as? AudioTapHardwareError, .cancelled)
        }
        XCTAssertTrue(cancelledBackend.readSelectors.isEmpty)
        XCTAssertTrue(cancelledBackend.mutableOperations.isEmpty)
    }

    @available(macOS 14.2, *)
    func testStableTopologyRequiresSecondConsecutiveChangedObservation() throws {
        let backend = FakeAudioHALBackend()
        let aggregate = AudioAggregateResource(objectID: 705, uid: "aggregate")
        configureAggregateStreams(
            backend,
            aggregateID: aggregate.objectID,
            input: [(41, fixtureFormat(channelCount: 2))],
            output: [(42, fixtureFormat(channelCount: 2))]
        )
        backend.setScalarReadSequence(
            [
                (fixtureASBD(sampleRate: 44_100), noErr),
                (fixtureASBD(sampleRate: 48_000), noErr),
                (fixtureASBD(sampleRate: 48_000), noErr),
            ],
            objectID: 42,
            address: .init(selector: kAudioStreamPropertyVirtualFormat)
        )

        let snapshot = try makeHardware(backend).waitForStableTopology(
            aggregate,
            deadline: .now() + .seconds(1),
            isCancelled: { false }
        )

        XCTAssertEqual(snapshot.outputFormats.map(\.sampleRate), [48_000])
        XCTAssertEqual(
            backend.dataReadCount(for: kAudioStreamPropertyVirtualFormat),
            6
        )
    }

    @available(macOS 14.2, *)
    func testStableTopologyErrorResetsConsecutiveObservationBaseline() throws {
        let backend = FakeAudioHALBackend()
        let aggregate = AudioAggregateResource(objectID: 706, uid: "aggregate")
        configureAggregateStreams(
            backend,
            aggregateID: aggregate.objectID,
            input: [(51, fixtureFormat(channelCount: 2))],
            output: [(52, fixtureFormat(channelCount: 2))]
        )
        backend.setScalarReadSequence(
            [
                (fixtureASBD(sampleRate: 48_000), noErr),
                (fixtureASBD(sampleRate: 48_000), OSStatus(-777)),
                (fixtureASBD(sampleRate: 48_000), noErr),
                (fixtureASBD(sampleRate: 48_000), noErr),
            ],
            objectID: 52,
            address: .init(selector: kAudioStreamPropertyVirtualFormat)
        )

        let snapshot = try makeHardware(backend).waitForStableTopology(
            aggregate,
            deadline: .now() + .seconds(1),
            isCancelled: { false }
        )

        XCTAssertEqual(snapshot.outputFormats.map(\.sampleRate), [48_000])
        XCTAssertEqual(
            backend.dataReadCount(for: kAudioStreamPropertyVirtualFormat),
            8
        )
    }

    @available(macOS 14.2, *)
    func testStableTopologyIncompleteObservationResetsConsecutiveBaseline() throws {
        let backend = FakeAudioHALBackend()
        let aggregate = AudioAggregateResource(objectID: 707, uid: "aggregate")
        configureAggregateStreams(
            backend,
            aggregateID: aggregate.objectID,
            input: [(61, fixtureFormat(channelCount: 2))],
            output: [(62, fixtureFormat(channelCount: 2))]
        )
        backend.setScalarReadSequence(
            [
                (UInt32(1), noErr),
                (UInt32(0), noErr),
                (UInt32(1), noErr),
                (UInt32(1), noErr),
            ],
            objectID: aggregate.objectID,
            address: .init(selector: kAudioDevicePropertyDeviceIsAlive)
        )

        let snapshot = try makeHardware(backend).waitForStableTopology(
            aggregate,
            deadline: .now() + .seconds(1),
            isCancelled: { false }
        )

        XCTAssertTrue(snapshot.isAlive)
        XCTAssertEqual(
            backend.dataReadCount(for: kAudioDevicePropertyDeviceIsAlive),
            4
        )
    }

    @available(macOS 14.2, *)
    func testInstanceIOProcRegistersOneContextAndCallbackContractIsExact() throws {
        let backend = FakeAudioHALBackend()
        backend.nextIOProcID = hardwareBoundaryIOProcID
        let aggregate = AudioAggregateResource(objectID: 707, uid: "aggregate")
        let context = try fixtureDSPContext()
        let hardware = makeHardware(backend)

        let resource = try hardware.createIOProc(aggregate: aggregate, context: context)

        XCTAssertEqual(resource.aggregateDeviceID, aggregate.objectID)
        XCTAssertEqual(
            hardwareIOProcIdentity(resource.ioProcID),
            hardwareIOProcIdentity(hardwareBoundaryIOProcID)
        )
        XCTAssertEqual(backend.ioProcCreations.count, 1)
        let creation = backend.ioProcCreations[0]
        XCTAssertEqual(creation.deviceID, aggregate.objectID)
        XCTAssertEqual(
            creation.clientData,
            Unmanaged.passUnretained(context).toOpaque()
        )

        var input: [Float32] = [0.25]
        var output: [Float32] = [9]
        XCTAssertEqual(
            invokeIOProc(
                creation.callback,
                deviceID: aggregate.objectID,
                input: &input,
                output: &output,
                clientData: nil
            ),
            kAudioHardwareUnspecifiedError
        )
        XCTAssertEqual(output, [9])
        XCTAssertFalse(context.hasObservedCallback)
        XCTAssertEqual(context.callbackCount, 0)

        XCTAssertEqual(
            invokeIOProc(
                creation.callback,
                deviceID: aggregate.objectID,
                input: &input,
                output: &output,
                clientData: creation.clientData
            ),
            noErr
        )
        XCTAssertEqual(output, [0])
        XCTAssertTrue(context.hasObservedCallback)
        XCTAssertEqual(context.callbackCount, 1)

        XCTAssertEqual(
            invokeIOProc(
                creation.callback,
                deviceID: aggregate.objectID,
                input: &input,
                output: &output,
                clientData: creation.clientData
            ),
            noErr
        )
        XCTAssertEqual(context.callbackCount, 2)
        XCTAssertEqual(backend.ioProcCreations.count, 1)
    }

    @available(macOS 14.2, *)
    func testInstanceMuteReadsAndWritesSameRetainedTapDescription() throws {
        let backend = FakeAudioHALBackend()
        let tap = fixtureTap(objectID: 708)
        let address = AudioHALPropertyAddress(selector: kAudioTapPropertyDescription)
        let description = CATapDescription(
            processes: [91],
            deviceUID: tap.source.deviceUID,
            stream: tap.source.streamIndex
        )
        description.uuid = tap.uuid
        description.muteBehavior = .unmuted
        let descriptionPointer = Unmanaged.passUnretained(description).toOpaque()
        configureDestroyIdentity(
            backend,
            id: tap.objectID,
            classID: kAudioTapClassID,
            uid: tap.uuid.uuidString
        )
        backend.setRetainedObject(description, objectID: tap.objectID, address: address)

        try makeHardware(backend).setMuteState(AudioTapMuteState.mutedWhenTapped, for: tap)

        XCTAssertEqual(description.muteBehavior, .mutedWhenTapped)
        XCTAssertEqual(
            backend.readSelectors,
            [
                kAudioObjectPropertyClass,
                kAudioTapPropertyUID,
                kAudioTapPropertyDescription,
            ]
        )
        XCTAssertEqual(backend.writeSelectors, [kAudioTapPropertyDescription])
        XCTAssertEqual(backend.objectWrites.count, 1)
        XCTAssertEqual(backend.objectWrites[0].objectID, tap.objectID)
        XCTAssertEqual(backend.objectWrites[0].address, address)
        XCTAssertEqual(backend.objectWrites[0].objectPointer, descriptionPointer)
    }

    @available(macOS 14.2, *)
    func testInstanceLifecyclePreservesExactStartAndRetryStatuses() {
        let backend = FakeAudioHALBackend()
        let hardware = makeHardware(backend)
        let ioProc = AudioIOProcResource(
            aggregateDeviceID: 709,
            aggregateUID: "aggregate",
            ioProcID: hardwareBoundaryIOProcID
        )
        let aggregate = AudioAggregateResource(objectID: 710, uid: "aggregate")
        let tap = fixtureTap(objectID: 711)
        configureDestroyIdentity(
            backend,
            id: aggregate.objectID,
            classID: kAudioAggregateDeviceClassID,
            uid: aggregate.uid
        )
        configureDestroyIdentity(
            backend,
            id: tap.objectID,
            classID: kAudioTapClassID,
            uid: tap.uuid.uuidString
        )
        configureDestroyIdentity(
            backend,
            id: ioProc.aggregateDeviceID,
            classID: kAudioAggregateDeviceClassID,
            uid: ioProc.aggregateUID
        )

        backend.startDeviceStatus = -801
        XCTAssertThrowsError(try hardware.start(ioProc)) { error in
            XCTAssertEqual(
                error as? AudioHALError,
                AudioHALError(
                    operation: .startDevice,
                    objectID: ioProc.aggregateDeviceID,
                    address: nil,
                    reason: .status(-801)
                )
            )
        }
        backend.stopDeviceStatus = -802
        backend.destroyIOProcStatus = -803
        backend.destroyAggregateDeviceStatus = -804
        backend.destroyProcessTapStatus = -805

        XCTAssertEqual(hardware.stop(ioProc), -802)
        XCTAssertEqual(hardware.destroyIOProc(ioProc), -803)
        XCTAssertEqual(hardware.destroyAggregate(aggregate), -804)
        XCTAssertEqual(hardware.destroyTap(tap), -805)
        XCTAssertEqual(
            backend.mutableOperations,
            [.startDevice, .stopDevice, .destroyIOProc, .destroyAggregate, .destroyTap]
        )
    }

    @available(macOS 14.2, *)
    func testIdentityCheckedDestroyDispatchesExactClassesIDsAndRawStatuses() {
        let backend = FakeAudioHALBackend()
        let hardware = makeHardware(backend)
        let aggregate = AudioAggregateResource(objectID: 720, uid: "Owned.Aggregate.720")
        let tap = fixtureTap(
            objectID: 721,
            uuid: UUID(uuidString: "4D414341-0000-4000-8000-000000000721")!
        )
        for object in [
            AudioOwnedObject(
                id: aggregate.objectID,
                classID: kAudioAggregateDeviceClassID,
                uid: aggregate.uid,
                name: "Aggregate"
            ),
            AudioOwnedObject(
                id: tap.objectID,
                classID: kAudioTapClassID,
                uid: tap.uuid.uuidString,
                name: "Tap"
            ),
        ] {
            configureDestroyIdentity(
                backend,
                id: object.id,
                classID: object.classID,
                uid: object.uid
            )
        }
        backend.destroyAggregateDeviceStatus = -820
        backend.destroyProcessTapStatus = -821

        XCTAssertEqual(hardware.destroyAggregate(aggregate), -820)
        XCTAssertEqual(hardware.destroyTap(tap), -821)
        XCTAssertEqual(backend.destroyedAggregateDeviceIDs, [720])
        XCTAssertEqual(backend.destroyedProcessTapIDs, [721])
        XCTAssertEqual(backend.mutableOperations, [
            .destroyAggregate,
            .destroyTap,
        ])
    }

    @available(macOS 14.2, *)
    func testIdentityCheckedDestroyTreatsReusedOrMissingObjectAsAlreadyGone() {
        let backend = FakeAudioHALBackend()
        let hardware = makeHardware(backend)
        let aggregate = AudioAggregateResource(objectID: 730, uid: "Old.Aggregate")
        let tap = fixtureTap(
            objectID: 731,
            uuid: UUID(uuidString: "4D414341-0000-4000-8000-000000000731")!
        )
        configureDestroyIdentity(
            backend,
            id: aggregate.objectID,
            classID: kAudioAggregateDeviceClassID,
            uid: "Replacement.Aggregate"
        )
        configureDestroyIdentity(
            backend,
            id: tap.objectID,
            classID: kAudioTapClassID,
            uid: "4D414341-0000-4000-8000-000000009999"
        )
        XCTAssertEqual(hardware.destroyAggregate(aggregate), noErr)
        XCTAssertEqual(hardware.destroyTap(tap), noErr)
        XCTAssertEqual(
            hardware.destroyAggregate(
                AudioAggregateResource(objectID: 733, uid: "Missing.Aggregate")
            ),
            noErr
        )
        XCTAssertTrue(backend.mutableOperations.isEmpty)
        XCTAssertTrue(backend.destroyedAggregateDeviceIDs.isEmpty)
        XCTAssertTrue(backend.destroyedProcessTapIDs.isEmpty)
    }

    @available(macOS 14.2, *)
    func testIdentityCheckedDestroyPreservesTransientIdentityReadStatus() {
        let backend = FakeAudioHALBackend()
        let hardware = makeHardware(backend)
        let aggregate = AudioAggregateResource(objectID: 740, uid: "Owned.Aggregate.740")
        backend.setReadError(
            -822,
            objectID: aggregate.objectID,
            address: AudioHALPropertyAddress(selector: kAudioObjectPropertyClass),
            announcedByteCount: UInt32(MemoryLayout<AudioClassID>.size)
        )

        XCTAssertEqual(hardware.destroyAggregate(aggregate), -822)
        XCTAssertTrue(backend.mutableOperations.isEmpty)
        XCTAssertTrue(backend.destroyedAggregateDeviceIDs.isEmpty)
    }

}

private func dictionaries(in description: NSDictionary, key: String) throws -> [NSDictionary] {
    let values = try XCTUnwrap(description[key] as? [Any])
    return try values.map { try XCTUnwrap($0 as? NSDictionary) }
}

private func fixturePlan(
    targets: [String],
    tapSources: [AudioTapSource]? = nil,
    targetInputStreams: [[AudioRouteStream]]? = nil,
    targetOutputStreams: [[AudioRouteStream]]? = nil
) -> AudioRoutePlan {
    let inputStreams = targetInputStreams ?? Array(repeating: [], count: targets.count)
    let outputStreams = targetOutputStreams ?? targets.indices.map { index in
        [AudioRouteStream(
            streamObjectID: AudioStreamID(1_000 + index),
            streamIndex: 0,
            format: fixtureFormat()
        )]
    }
    precondition(inputStreams.count == targets.count)
    precondition(outputStreams.count == targets.count)
    return AudioRoutePlan(
        processObjectID: 91,
        generation: 4,
        tapSources: tapSources ?? [fixtureSource(deviceUID: "Source.Device", streamIndex: 0)],
        selectedTargetUIDs: targets,
        subdevices: targets.enumerated().map { index, uid in
            AudioRouteSubdevice(
                uid: uid,
                driftCompensation: index > 0 ? .highQuality : .disabled,
                inputStreams: inputStreams[index],
                outputStreams: outputStreams[index]
            )
        },
        mainDeviceUID: targets.first ?? "",
        isStacked: true,
        aggregateUID: "com.how.macactivity.audio.aggregate.fixture",
        topologyFingerprint: fixtureTopologyFingerprint()
    )
}

private func fixtureSource(deviceUID: String, streamIndex: UInt) -> AudioTapSource {
    AudioTapSource(
        deviceUID: deviceUID,
        streamIndex: streamIndex,
        expectedFormat: fixtureFormat(),
        driftCompensation: .disabled
    )
}

private func fixtureTopologyFingerprint() -> AudioRouteTopologyFingerprint {
    AudioRouteTopologyFingerprint(
        osBuild: "25A123",
        sourceDeviceUIDs: ["Source.Device"],
        selectedTargetUIDs: ["output"],
        devices: []
    )
}

private func fixtureFormat(
    sampleRate: Double = 48_000,
    channelCount: Int = 2,
    interleaving: AudioPCMInterleaving = .interleaved
) -> ProcessTapAudioFormat {
    let nonInterleavedFlag: AudioFormatFlags = interleaving == .nonInterleaved
        ? kAudioFormatFlagIsNonInterleaved
        : 0
    return ProcessTapAudioFormat(
        sampleRate: sampleRate,
        channelCount: channelCount,
        formatID: kAudioFormatLinearPCM,
        formatFlags: kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | nonInterleavedFlag,
        bitsPerChannel: 32,
        interleaving: interleaving
    )
}

@available(macOS 14.2, *)
private func makeHardware(
    _ backend: FakeAudioHALBackend,
    processTapsAvailable: Bool = true
) -> CoreAudioTapHardware {
    CoreAudioTapHardware(
        hal: AudioHALClient(
            backend: backend,
            processTapsAvailable: processTapsAvailable
        )
    )
}

private func fixtureTap(
    objectID: AudioObjectID,
    uuid: UUID = UUID(uuidString: "4D414341-0000-4000-8000-000000000001")!,
    source: AudioTapSource = fixtureSource(deviceUID: "Source.Device", streamIndex: 0)
) -> AudioTapResource {
    AudioTapResource(objectID: objectID, uuid: uuid, source: source)
}

private func fixtureASBD(
    sampleRate: Double = 48_000,
    channelCount: UInt32 = 2,
    formatFlags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
) -> AudioStreamBasicDescription {
    let isNonInterleaved = formatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let bytesPerFrame = UInt32(MemoryLayout<Float32>.stride)
        * (isNonInterleaved ? 1 : channelCount)
    return AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: formatFlags,
        mBytesPerPacket: bytesPerFrame,
        mFramesPerPacket: 1,
        mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: channelCount,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private func streamListAddress(scope: AudioObjectPropertyScope) -> AudioHALPropertyAddress {
    AudioHALPropertyAddress(selector: kAudioDevicePropertyStreams, scope: scope)
}

private func configureAggregateStreams(
    _ backend: FakeAudioHALBackend,
    aggregateID: AudioObjectID,
    input: [(AudioStreamID, ProcessTapAudioFormat)],
    output: [(AudioStreamID, ProcessTapAudioFormat)],
    tapUUIDs: [UUID] = [
        UUID(uuidString: "4D414341-0000-4000-8000-000000000001")!,
    ],
    activeSubTapIDs: [AudioObjectID] = [900]
) {
    backend.setScalar(
        UInt32(1),
        objectID: aggregateID,
        address: AudioHALPropertyAddress(selector: kAudioDevicePropertyDeviceIsAlive)
    )
    backend.setArray(
        input.map(\.0),
        objectID: aggregateID,
        address: streamListAddress(scope: kAudioObjectPropertyScopeInput)
    )
    backend.setArray(
        output.map(\.0),
        objectID: aggregateID,
        address: streamListAddress(scope: kAudioObjectPropertyScopeOutput)
    )
    backend.setRetainedObject(
        tapUUIDs.map(\.uuidString) as CFArray,
        objectID: aggregateID,
        address: AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyTapList
        )
    )
    backend.setArray(
        activeSubTapIDs,
        objectID: aggregateID,
        address: AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertySubTapList
        )
    )
    let formatAddress = AudioHALPropertyAddress(selector: kAudioStreamPropertyVirtualFormat)
    for (streamID, format) in input + output {
        backend.setScalar(
            fixtureASBD(
                sampleRate: format.sampleRate,
                channelCount: UInt32(format.channelCount),
                formatFlags: format.formatFlags
            ),
            objectID: streamID,
            address: formatAddress
        )
    }
}

private func fixtureDSPContext() throws -> ProcessTapDSPContext {
    let format = fixtureFormat(channelCount: 1)
    let address = ProcessTapChannelAddress(
        bufferIndex: 0,
        channelIndex: 0,
        interleavedChannelCount: 1
    )
    return ProcessTapDSPContext(
        configuration: try ProcessTapDSPConfiguration.validated(
            sampleRate: format.sampleRate,
            inputFormats: [format],
            outputFormats: [format],
            channelMaps: [
                ProcessTapChannelMap(
                    input: address,
                    output: address,
                    mixCoefficient: 1
                ),
            ]
        ),
        initialGain: 1
    )
}

private let hardwareBoundaryIOProcID: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in
    noErr
}

private func hardwareIOProcIdentity(_ ioProcID: AudioDeviceIOProcID) -> UInt {
    unsafeBitCast(ioProcID, to: UInt.self)
}

private func invokeIOProc(
    _ callback: AudioDeviceIOProc,
    deviceID: AudioDeviceID,
    input: inout [Float32],
    output: inout [Float32],
    clientData: UnsafeMutableRawPointer?
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
                            clientData
                        )
                    }
                }
            }
        }
    }
}

@available(macOS 14.2, *)
private func configureDestroyIdentity(
    _ backend: FakeAudioHALBackend,
    id: AudioObjectID,
    classID: AudioClassID,
    uid: String
) {
    backend.setScalar(
        classID,
        objectID: id,
        address: AudioHALPropertyAddress(selector: kAudioObjectPropertyClass)
    )
    let uidSelector = classID == kAudioTapClassID
        ? kAudioTapPropertyUID
        : kAudioDevicePropertyDeviceUID
    backend.setString(
        uid,
        objectID: id,
        address: AudioHALPropertyAddress(selector: uidSelector)
    )
}
