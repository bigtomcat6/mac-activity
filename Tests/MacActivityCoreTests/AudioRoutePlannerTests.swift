import AudioToolbox
import CoreAudio
import XCTest
@testable import MacActivityCore

final class AudioRoutePlannerTests: XCTestCase {
    func testPlannerRejects257ChannelSourceFormat() {
        let request = fixtureRequest(
            devices: fixtureDevices(builtInOutputStreams: [
                AudioRouteStream(
                    streamObjectID: 10_000,
                    streamIndex: 0,
                    format: fixtureFormat(channelCount: 257)
                ),
            ])
        )

        assertPlanningError(
            .unsupportedFormat(deviceUID: "BuiltIn", streamIndex: 0),
            request: request
        )
    }

    func testFollowOriginalIgnoresDifferentSystemDefault() throws {
        let request = fixtureRequest(
            sourceDeviceUIDs: ["BuiltIn"],
            systemDefaultOutputDeviceUID: "HDMI",
            mode: .followOriginal
        )

        let plan = try planner().plan(request)

        XCTAssertEqual(plan.selectedTargetUIDs, ["BuiltIn"])
        XCTAssertEqual(Set(plan.tapSources.map(\.deviceUID)), ["BuiltIn"])
        XCTAssertFalse(plan.selectedTargetUIDs.contains("HDMI"))
    }

    func testFollowOriginalTracksSourceRouteChanges() throws {
        let planner = planner()

        let builtInPlan = try planner.plan(fixtureRequest(sourceDeviceUIDs: ["BuiltIn"]))
        let usbPlan = try planner.plan(fixtureRequest(sourceDeviceUIDs: ["USB"]))

        XCTAssertEqual(builtInPlan.selectedTargetUIDs, ["BuiltIn"])
        XCTAssertEqual(builtInPlan.tapSources.map(\.deviceUID), ["BuiltIn"])
        XCTAssertEqual(usbPlan.selectedTargetUIDs, ["USB"])
        XCTAssertEqual(usbPlan.tapSources.map(\.deviceUID), ["USB"])
    }

    func testExplicitRouteIsUnaffectedBySystemDefaultChanges() throws {
        let planner = planner()
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
        let plan = try planner().plan(fixtureRequest(
            systemDefaultOutputDeviceUID: "DefaultThatMustNotAppear",
            mode: .explicit(targetDeviceUIDs: ["USB", "HDMI", "USB"])
        ))

        XCTAssertEqual(plan.selectedTargetUIDs, ["USB", "HDMI"])
        XCTAssertEqual(plan.subdevices.map(\.uid), ["USB", "HDMI"])
        XCTAssertEqual(plan.mainDeviceUID, "USB")
        XCTAssertEqual(plan.subdevices.map(\.driftCompensation), [.disabled, .disabled])
    }

    func testExplicitMultiDeviceTargetsRetainEachDeviceOutputStreamOrder() throws {
        let usbStreams = [
            AudioRouteStream(streamObjectID: 108, streamIndex: 8, format: fixtureFormat(channelCount: 1)),
            AudioRouteStream(streamObjectID: 102, streamIndex: 2, format: fixtureFormat(channelCount: 2)),
        ]
        let hdmiStreams = [
            AudioRouteStream(streamObjectID: 205, streamIndex: 5, format: fixtureFormat(channelCount: 6)),
        ]
        let plan = try planner().plan(fixtureRequest(
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
            AudioRouteStream(streamObjectID: 104, streamIndex: 4, format: fixtureFormat(channelCount: 2)),
            AudioRouteStream(streamObjectID: 101, streamIndex: 1, format: fixtureFormat(channelCount: 1)),
        ]
        let hdmiStreams = [
            AudioRouteStream(streamObjectID: 207, streamIndex: 7, format: fixtureFormat(channelCount: 6)),
        ]
        let plan = try planner().plan(fixtureRequest(
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

    func testNestedAggregatesAreRejected() {
        let devices = fixtureDevices() + [
            fixtureDevice(
                objectID: 50,
                uid: "NestedAggregate",
                isAggregate: true,
                aggregateSubdeviceUIDs: ["StudioAggregate", "USB", "BuiltIn"]
            ),
        ]

        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["NestedAggregate", "HDMI"]),
                devices: devices
            )
        )
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

    func testDuplicateDeviceUIDsAreRejectedAndFailPreflight() {
        let request = fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["USB"]),
            devices: fixtureDevices() + [
                fixtureDevice(objectID: 62, uid: "USB", name: "Duplicate USB"),
            ]
        )

        assertPlanningError(.unsupportedTopology, request: request)
        XCTAssertFalse(planner().permits(request))
    }

    func testAggregateCycleIsRejectedAsUnsupportedTopology() {
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
            .unsupportedTopology,
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
            .unsupportedTopology,
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
            .unsupportedTopology,
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

        let plan = try planner().plan(fixtureRequest(
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
        let planner = planner()

        let first = try planner.plan(request)
        let second = try planner.plan(request)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.processObjectID, 77)
        XCTAssertEqual(first.generation, 9)
        XCTAssertEqual(
            first.aggregateUID,
            AudioRoutePlanner.aggregateUIDPrefix + "77.9"
        )
        XCTAssertFalse(first.isStacked)
    }

    func testPlannerRejectsEveryMultipleSourceTapMatrix() {
        let multiStream = fixtureDevice(
            objectID: 90,
            uid: "MultiStream",
            outputStreams: [
                AudioRouteStream(streamObjectID: 901, streamIndex: 0, format: fixtureFormat()),
                AudioRouteStream(streamObjectID: 902, streamIndex: 1, format: fixtureFormat()),
            ]
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(
                sourceDeviceUIDs: ["MultiStream"],
                mode: .explicit(targetDeviceUIDs: ["USB"]),
                devices: fixtureDevices() + [multiStream]
            )
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(
                sourceDeviceUIDs: ["BuiltIn", "USB"],
                mode: .explicit(targetDeviceUIDs: ["USB", "HDMI"])
            )
        )
    }

    func testPlannerSeparatesSubTapAndSubdeviceDrift() throws {
        let devices = [
            fixtureDevice(objectID: 91, uid: "Source", clockDomain: 100),
            fixtureDevice(objectID: 92, uid: "Main", clockDomain: 200),
            fixtureDevice(objectID: 93, uid: "Peer", clockDomain: 200),
            fixtureDevice(objectID: 94, uid: "Other", clockDomain: 0),
        ]
        let plan = try planner().plan(fixtureRequest(
            sourceDeviceUIDs: ["Source"],
            mode: .explicit(targetDeviceUIDs: ["Main", "Peer", "Other"]),
            devices: devices
        ))

        XCTAssertEqual(try XCTUnwrap(plan.tapSources.first).driftCompensation, .highQuality)
        XCTAssertEqual(plan.tapSources.count, 1)
        XCTAssertEqual(plan.subdevices.map(\.driftCompensation), [
            .disabled, .disabled, .highQuality,
        ])
    }

    func testPreflightFingerprintIsTheExactFingerprintCarriedByPlan() throws {
        let request = fixtureRequest(mode: .explicit(targetDeviceUIDs: ["USB", "HDMI"]))
        let planner = planner()

        XCTAssertEqual(
            try planner.topologyFingerprint(for: request),
            try planner.plan(request).topologyFingerprint
        )
    }

    func testProductionFingerprintIgnoresProcessAndGeneration() throws {
        let planner = planner()
        let lhs = try planner.topologyFingerprint(for: fixtureRequest(
            processObjectID: 77,
            generation: 1
        ))
        let rhs = try planner.topologyFingerprint(for: fixtureRequest(
            processObjectID: 88,
            generation: 9
        ))

        XCTAssertEqual(lhs, rhs)
    }

    func testPlannerSupportsOneSourceTapToOneOrManyTargets() throws {
        let planner = planner()

        let oneToOne = try planner.plan(fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["USB"])
        ))
        let oneToMany = try planner.plan(fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["USB", "HDMI"])
        ))

        XCTAssertEqual(oneToOne.tapSources.count, 1)
        XCTAssertEqual(oneToOne.subdevices.map(\.uid), ["USB"])
        XCTAssertFalse(oneToOne.isStacked)
        XCTAssertEqual(oneToMany.tapSources.count, 1)
        XCTAssertEqual(oneToMany.subdevices.map(\.uid), ["USB", "HDMI"])
        XCTAssertTrue(oneToMany.isStacked)
    }

    func testSingleAggregateLeafUsesValidatedMainAndOnlyStacksForMultipleStreams() throws {
        let singleLeaf = fixtureDevice(
            objectID: 95,
            uid: "SingleLeafAggregate",
            isAggregate: true,
            aggregateSubdeviceUIDs: ["USB"]
        )
        let planner = planner()
        let simple = try planner.plan(fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["SingleLeafAggregate"]),
            devices: fixtureDevices() + [singleLeaf]
        ))
        XCTAssertEqual(simple.mainDeviceUID, "USB")
        XCTAssertEqual(simple.subdevices.map(\.uid), ["USB"])
        XCTAssertFalse(simple.isStacked)

        let multiStreamUSB = fixtureDevice(
            objectID: 20,
            uid: "USB",
            outputStreams: [
                AudioRouteStream(streamObjectID: 201, streamIndex: 0, format: fixtureFormat()),
                AudioRouteStream(streamObjectID: 202, streamIndex: 1, format: fixtureFormat()),
            ]
        )
        let devices = fixtureDevices().filter { $0.uid != "USB" }
            + [multiStreamUSB, singleLeaf]
        XCTAssertTrue(try planner.plan(fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["SingleLeafAggregate"]),
            devices: devices
        )).isStacked)
    }

    func testAggregateFlatteningRequiresCompleteLiveTapFreeComposition() {
        let invalidCompositions = [
            AudioRouteAggregateComposition(
                fullSubdeviceUIDs: ["USB", "HDMI"],
                activeSubdeviceUIDs: ["USB"],
                mainSubdeviceUID: "USB",
                isStacked: true,
                tapUUIDs: []
            ),
            AudioRouteAggregateComposition(
                fullSubdeviceUIDs: ["USB", "HDMI"],
                activeSubdeviceUIDs: ["USB", "HDMI"],
                mainSubdeviceUID: "Missing",
                isStacked: true,
                tapUUIDs: []
            ),
            AudioRouteAggregateComposition(
                fullSubdeviceUIDs: ["USB", "HDMI"],
                activeSubdeviceUIDs: ["USB", "HDMI"],
                mainSubdeviceUID: nil,
                isStacked: true,
                tapUUIDs: []
            ),
            AudioRouteAggregateComposition(
                fullSubdeviceUIDs: ["USB", "HDMI"],
                activeSubdeviceUIDs: ["USB", "HDMI"],
                mainSubdeviceUID: "USB",
                isStacked: nil,
                tapUUIDs: []
            ),
            AudioRouteAggregateComposition(
                fullSubdeviceUIDs: ["USB", "HDMI"],
                activeSubdeviceUIDs: ["USB", "HDMI"],
                mainSubdeviceUID: "USB",
                isStacked: true,
                tapUUIDs: ["existing-tap"]
            ),
        ]

        for (index, composition) in invalidCompositions.enumerated() {
            let aggregate = fixtureDevice(
                objectID: AudioObjectID(100 + index),
                uid: "InvalidAggregate",
                isAggregate: true,
                aggregateSubdeviceUIDs: ["USB", "HDMI"],
                aggregateComposition: composition
            )
            assertPlanningError(
                .unsupportedTopology,
                request: fixtureRequest(
                    mode: .explicit(targetDeviceUIDs: ["InvalidAggregate"]),
                    devices: fixtureDevices() + [aggregate]
                )
            )
        }

        let incomplete = fixtureDevice(
            objectID: 110,
            uid: "IncompleteAggregate",
            isAggregate: true,
            aggregateSubdeviceUIDs: ["USB", "HDMI"],
            hasCompleteAggregateComposition: false
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["IncompleteAggregate"]),
                devices: fixtureDevices() + [incomplete]
            )
        )
    }

    func testSourceAndTargetAggregatesRejectExtraOrDuplicateActiveMembership() {
        let invalidActiveLists = [
            ["USB", "HDMI", "BuiltIn"],
            ["USB", "HDMI", "USB"],
        ]

        for (index, activeUIDs) in invalidActiveLists.enumerated() {
            let targetUID = "InvalidActiveTargetAggregate\(index)"
            let target = fixtureDevice(
                objectID: AudioObjectID(150 + index),
                uid: targetUID,
                isAggregate: true,
                aggregateSubdeviceUIDs: ["USB", "HDMI"],
                aggregateComposition: AudioRouteAggregateComposition(
                    fullSubdeviceUIDs: ["USB", "HDMI"],
                    activeSubdeviceUIDs: activeUIDs,
                    mainSubdeviceUID: "USB",
                    isStacked: true,
                    tapUUIDs: []
                )
            )
            assertPlanningError(
                .unsupportedTopology,
                request: fixtureRequest(
                    mode: .explicit(targetDeviceUIDs: [targetUID]),
                    devices: fixtureDevices() + [target]
                )
            )

            let sourceUID = "InvalidActiveSourceAggregate\(index)"
            let source = fixtureDevice(
                objectID: AudioObjectID(160 + index),
                uid: sourceUID,
                isAggregate: true,
                aggregateSubdeviceUIDs: ["USB", "HDMI"],
                aggregateComposition: AudioRouteAggregateComposition(
                    fullSubdeviceUIDs: ["USB", "HDMI"],
                    activeSubdeviceUIDs: activeUIDs,
                    mainSubdeviceUID: "USB",
                    isStacked: true,
                    tapUUIDs: []
                )
            )
            assertPlanningError(
                .unsupportedTopology,
                request: fixtureRequest(
                    sourceDeviceUIDs: [sourceUID],
                    mode: .explicit(targetDeviceUIDs: ["USB"]),
                    devices: fixtureDevices() + [source]
                )
            )
        }
    }

    func testAggregateFullListControlsOrderWhileActiveListOnlyValidatesMembership() throws {
        let composition = AudioRouteAggregateComposition(
            fullSubdeviceUIDs: ["HDMI", "USB"],
            activeSubdeviceUIDs: ["USB", "HDMI"],
            mainSubdeviceUID: "USB",
            isStacked: true,
            tapUUIDs: []
        )
        let aggregate = fixtureDevice(
            objectID: 111,
            uid: "OrderedAggregate",
            isAggregate: true,
            aggregateSubdeviceUIDs: ["USB", "HDMI"],
            aggregateComposition: composition
        )
        let plan = try planner().plan(fixtureRequest(
            mode: .explicit(targetDeviceUIDs: ["OrderedAggregate"]),
            devices: fixtureDevices() + [aggregate]
        ))

        XCTAssertEqual(plan.subdevices.map(\.uid), ["HDMI", "USB"])
        XCTAssertEqual(plan.mainDeviceUID, "USB")
    }

    func testFingerprintCanonicalizesAggregateActiveMembership() throws {
        let lhs = fixtureDevice(
            objectID: 116,
            uid: "Aggregate",
            isAggregate: true,
            aggregateSubdeviceUIDs: ["USB", "HDMI"],
            outputStreams: [AudioRouteStream(
                streamObjectID: 116_000,
                streamIndex: 0,
                format: fixtureFormat()
            )],
            aggregateComposition: AudioRouteAggregateComposition(
                fullSubdeviceUIDs: ["USB", "HDMI"],
                activeSubdeviceUIDs: ["HDMI", "USB"],
                mainSubdeviceUID: "USB",
                isStacked: true,
                tapUUIDs: []
            )
        )
        let rhs = fixtureDevice(
            objectID: 999,
            uid: "Aggregate",
            isAggregate: true,
            aggregateSubdeviceUIDs: ["USB", "HDMI"],
            outputStreams: [AudioRouteStream(
                streamObjectID: 116_000,
                streamIndex: 0,
                format: fixtureFormat()
            )],
            aggregateComposition: AudioRouteAggregateComposition(
                fullSubdeviceUIDs: ["USB", "HDMI"],
                activeSubdeviceUIDs: ["USB", "HDMI"],
                mainSubdeviceUID: "USB",
                isStacked: true,
                tapUUIDs: []
            )
        )
        let base = fixtureDevices().filter { $0.uid != "StudioAggregate" }
        let planner = planner()

        XCTAssertEqual(
            try planner.topologyFingerprint(for: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["Aggregate"]),
                devices: base + [lhs]
            )),
            try planner.topologyFingerprint(for: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["Aggregate"]),
                devices: base + [rhs]
            ))
        )
    }

    func testExactPublicFingerprintAllowancePermitsPlan() throws {
        let request = fixtureRequest(mode: .explicit(targetDeviceUIDs: ["USB"]))
        let preflight = planner()
        let fingerprint = try preflight.topologyFingerprint(for: request)
        let exact = AudioRoutePlanner(
            policy: AudioRouteNativeValidationPolicy(
                validatedFingerprints: [fingerprint]
            ),
            osBuildProvider: { "25A123" }
        )

        XCTAssertEqual(try exact.plan(request).topologyFingerprint, fingerprint)
    }

    func testEmptyOSBuildFailsClosedBeforePolicyLookup() {
        let planner = AudioRoutePlanner(
            policy: .allowingAllForTesting,
            osBuildProvider: { "" }
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(mode: .explicit(targetDeviceUIDs: ["USB"])),
            planner: planner
        )
    }

    func testUnreadableOSBuildFailsClosedBeforePolicyLookup() {
        let planner = AudioRoutePlanner(
            policy: .allowingAllForTesting,
            osBuildProvider: { throw AudioRouteOSBuild.ReadError.unavailable }
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(mode: .explicit(targetDeviceUIDs: ["USB"])),
            planner: planner
        )
    }

    func testPlannerRejectsUnknownStreamIdentitiesForSourceAndTarget() {
        let unknownSource = fixtureDevice(
            objectID: 120,
            uid: "UnknownSource",
            outputStreams: [AudioRouteStream(
                streamObjectID: kAudioObjectUnknown,
                streamIndex: 0,
                format: fixtureFormat()
            )]
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(
                sourceDeviceUIDs: ["UnknownSource"],
                mode: .explicit(targetDeviceUIDs: ["USB"]),
                devices: fixtureDevices() + [unknownSource]
            )
        )

        let unknownTarget = fixtureDevice(
            objectID: 121,
            uid: "UnknownTarget",
            outputStreams: [AudioRouteStream(
                streamObjectID: kAudioObjectUnknown,
                streamIndex: 0,
                format: fixtureFormat()
            )]
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: ["UnknownTarget"]),
                devices: fixtureDevices() + [unknownTarget]
            )
        )
    }

    func testPlannerRejectsDuplicateStreamObjectIDsAndIndexesPerDirection() {
        let duplicateSourceIDs = fixtureDevice(
            objectID: 122,
            uid: "DuplicateSourceIDs",
            outputStreams: [
                AudioRouteStream(streamObjectID: 1_220, streamIndex: 0, format: fixtureFormat()),
                AudioRouteStream(streamObjectID: 1_220, streamIndex: 1, format: fixtureFormat()),
            ]
        )
        let duplicateSourceIndexes = fixtureDevice(
            objectID: 123,
            uid: "DuplicateSourceIndexes",
            outputStreams: [
                AudioRouteStream(streamObjectID: 1_231, streamIndex: 0, format: fixtureFormat()),
                AudioRouteStream(streamObjectID: 1_232, streamIndex: 0, format: fixtureFormat()),
            ]
        )
        for source in [duplicateSourceIDs, duplicateSourceIndexes] {
            assertPlanningError(
                .unsupportedTopology,
                request: fixtureRequest(
                    sourceDeviceUIDs: [source.uid],
                    mode: .explicit(targetDeviceUIDs: ["USB"]),
                    devices: fixtureDevices() + [source]
                )
            )
        }

        let duplicateTargetIDs = fixtureDevice(
            objectID: 124,
            uid: "DuplicateTargetIDs",
            outputStreams: [
                AudioRouteStream(streamObjectID: 1_240, streamIndex: 0, format: fixtureFormat()),
                AudioRouteStream(streamObjectID: 1_240, streamIndex: 1, format: fixtureFormat()),
            ]
        )
        let duplicateTargetIndexes = fixtureDevice(
            objectID: 125,
            uid: "DuplicateTargetIndexes",
            outputStreams: [
                AudioRouteStream(streamObjectID: 1_251, streamIndex: 0, format: fixtureFormat()),
                AudioRouteStream(streamObjectID: 1_252, streamIndex: 0, format: fixtureFormat()),
            ]
        )
        for target in [duplicateTargetIDs, duplicateTargetIndexes] {
            assertPlanningError(
                .unsupportedTopology,
                request: fixtureRequest(
                    mode: .explicit(targetDeviceUIDs: [target.uid]),
                    devices: fixtureDevices() + [target]
                )
            )
        }
    }

    func testPlannerRejectsInvalidInputStreamIdentitiesOnParticipatingDevice() {
        let target = fixtureDevice(
            objectID: 126,
            uid: "InvalidInputTarget",
            inputStreams: [
                AudioRouteStream(streamObjectID: 1_261, streamIndex: 0, format: fixtureFormat()),
                AudioRouteStream(streamObjectID: 1_262, streamIndex: 0, format: fixtureFormat()),
            ]
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: [target.uid]),
                devices: fixtureDevices() + [target]
            )
        )
    }

    func testPlannerRejectsStreamObjectIDReusedAcrossParticipatingDevices() {
        let sharedID: AudioStreamID = 1_270
        let source = fixtureDevice(
            objectID: 127,
            uid: "ReusedIDSource",
            outputStreams: [AudioRouteStream(
                streamObjectID: sharedID,
                streamIndex: 0,
                format: fixtureFormat()
            )]
        )
        let target = fixtureDevice(
            objectID: 128,
            uid: "ReusedIDTarget",
            outputStreams: [AudioRouteStream(
                streamObjectID: sharedID,
                streamIndex: 0,
                format: fixtureFormat()
            )]
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(
                sourceDeviceUIDs: [source.uid],
                mode: .explicit(targetDeviceUIDs: [target.uid]),
                devices: fixtureDevices() + [source, target]
            )
        )
    }

    func testPlannerRejectsStreamObjectIDSharedByInputAndOutput() {
        let sharedID: AudioStreamID = 1_280
        let target = fixtureDevice(
            objectID: 128,
            uid: "CrossDirectionReusedIDTarget",
            inputStreams: [AudioRouteStream(
                streamObjectID: sharedID,
                streamIndex: 0,
                format: fixtureFormat()
            )],
            outputStreams: [AudioRouteStream(
                streamObjectID: sharedID,
                streamIndex: 0,
                format: fixtureFormat()
            )]
        )
        assertPlanningError(
            .unsupportedTopology,
            request: fixtureRequest(
                mode: .explicit(targetDeviceUIDs: [target.uid]),
                devices: fixtureDevices() + [target]
            )
        )
    }

    func testCompleteSourceAggregatePlansOnePresentationTapAndFingerprintsPhysicalLeaves() throws {
        let leaves = [
            fixtureDevice(objectID: 127, uid: "SourceLeafA"),
            fixtureDevice(objectID: 128, uid: "SourceLeafB"),
        ]
        let presentation = AudioRouteStream(
            streamObjectID: 1_290,
            streamIndex: 4,
            format: fixtureFormat(channelCount: 4)
        )
        let sourceAggregate = fixtureDevice(
            objectID: 129,
            uid: "SourceAggregate",
            isAggregate: true,
            aggregateSubdeviceUIDs: leaves.map(\.uid),
            outputStreams: [presentation]
        )
        let request = fixtureRequest(
            sourceDeviceUIDs: [sourceAggregate.uid],
            mode: .explicit(targetDeviceUIDs: ["USB"]),
            devices: fixtureDevices() + leaves + [sourceAggregate]
        )
        let plan = try planner().plan(request)

        XCTAssertEqual(plan.tapSources.map(\.deviceUID), ["SourceAggregate"])
        XCTAssertEqual(plan.tapSources.map(\.streamIndex), [4])
        XCTAssertEqual(
            plan.topologyFingerprint.devices.map(\.uid),
            ["SourceAggregate", "SourceLeafA", "SourceLeafB", "USB"]
        )
        XCTAssertEqual(plan.topologyFingerprint.devices[0].outputStreams, [presentation])
        XCTAssertEqual(
            plan.topologyFingerprint.devices
                .filter { ["SourceLeafA", "SourceLeafB"].contains($0.uid) }
                .flatMap(\.outputStreams).count,
            2
        )
    }

    func testIncompleteTappedNestedOwnedAndInactiveSourceAggregatesAreRejected() {
        let leaf = fixtureDevice(objectID: 130, uid: "SourceLeaf")
        let inactiveLeaf = fixtureDevice(objectID: 131, uid: "InactiveLeaf", isAlive: false)
        let nestedLeaf = fixtureDevice(
            objectID: 132,
            uid: "NestedSourceLeaf",
            isAggregate: true,
            aggregateSubdeviceUIDs: [leaf.uid]
        )
        let ownedUID = "com.how.macactivity.audio.source-leaf"
        let ownedLeaf = fixtureDevice(objectID: 133, uid: ownedUID)
        let cases: [(AudioRouteDevice, [AudioRouteDevice])] = [
            (
                fixtureDevice(
                    objectID: 134,
                    uid: "IncompleteSourceAggregate",
                    isAggregate: true,
                    aggregateSubdeviceUIDs: [leaf.uid],
                    hasCompleteAggregateComposition: false
                ),
                [leaf]
            ),
            (
                fixtureDevice(
                    objectID: 135,
                    uid: "TappedSourceAggregate",
                    isAggregate: true,
                    aggregateSubdeviceUIDs: [leaf.uid],
                    aggregateComposition: AudioRouteAggregateComposition(
                        fullSubdeviceUIDs: [leaf.uid],
                        activeSubdeviceUIDs: [leaf.uid],
                        mainSubdeviceUID: leaf.uid,
                        isStacked: false,
                        tapUUIDs: ["existing-tap"]
                    )
                ),
                [leaf]
            ),
            (
                fixtureDevice(
                    objectID: 1351,
                    uid: "InactiveMembershipSourceAggregate",
                    isAggregate: true,
                    aggregateSubdeviceUIDs: [leaf.uid],
                    aggregateComposition: AudioRouteAggregateComposition(
                        fullSubdeviceUIDs: [leaf.uid],
                        activeSubdeviceUIDs: [],
                        mainSubdeviceUID: leaf.uid,
                        isStacked: false,
                        tapUUIDs: []
                    )
                ),
                [leaf]
            ),
            (
                fixtureDevice(
                    objectID: 1352,
                    uid: "DuplicateFullListSourceAggregate",
                    isAggregate: true,
                    aggregateSubdeviceUIDs: [leaf.uid],
                    aggregateComposition: AudioRouteAggregateComposition(
                        fullSubdeviceUIDs: [leaf.uid, leaf.uid],
                        activeSubdeviceUIDs: [leaf.uid],
                        mainSubdeviceUID: leaf.uid,
                        isStacked: true,
                        tapUUIDs: []
                    )
                ),
                [leaf]
            ),
            (
                fixtureDevice(
                    objectID: 136,
                    uid: "NestedSourceAggregate",
                    isAggregate: true,
                    aggregateSubdeviceUIDs: [nestedLeaf.uid]
                ),
                [leaf, nestedLeaf]
            ),
            (
                fixtureDevice(
                    objectID: 137,
                    uid: "OwnedSourceAggregate",
                    isAggregate: true,
                    aggregateSubdeviceUIDs: [ownedUID]
                ),
                [ownedLeaf]
            ),
            (
                fixtureDevice(
                    objectID: 138,
                    uid: "InactiveSourceAggregate",
                    isAggregate: true,
                    aggregateSubdeviceUIDs: [inactiveLeaf.uid]
                ),
                [inactiveLeaf]
            ),
        ]

        for (source, dependencies) in cases {
            XCTAssertThrowsError(try planner().plan(fixtureRequest(
                sourceDeviceUIDs: [source.uid],
                mode: .explicit(targetDeviceUIDs: ["USB"]),
                devices: fixtureDevices() + dependencies + [source]
            )))
        }
    }

    func testSourceAggregatePresentationOrLeafFormatChangesFingerprint() throws {
        func request(
            presentationSampleRate: Double,
            leafChannels: Int
        ) -> AudioRouteRequest {
            let leaf = fixtureDevice(
                objectID: 139,
                uid: "SourceLeaf",
                format: fixtureFormat(channelCount: leafChannels)
            )
            let source = fixtureDevice(
                objectID: 140,
                uid: "SourceAggregate",
                isAggregate: true,
                aggregateSubdeviceUIDs: [leaf.uid],
                format: fixtureFormat(sampleRate: presentationSampleRate)
            )
            return fixtureRequest(
                sourceDeviceUIDs: [source.uid],
                mode: .explicit(targetDeviceUIDs: ["USB"]),
                devices: fixtureDevices() + [leaf, source]
            )
        }

        let planner = planner()
        let baseline = try planner.topologyFingerprint(for: request(
            presentationSampleRate: 48_000,
            leafChannels: 2
        ))
        XCTAssertNotEqual(baseline, try planner.topologyFingerprint(for: request(
            presentationSampleRate: 96_000,
            leafChannels: 2
        )))
        XCTAssertNotEqual(baseline, try planner.topologyFingerprint(for: request(
            presentationSampleRate: 48_000,
            leafChannels: 6
        )))
    }

    func testSubTapDriftDirectMatrix() throws {
        func drift(
            sourceUID: String = "Source",
            sourceClock: UInt32?,
            sourceTransport: UInt32? = kAudioDeviceTransportTypeUSB,
            mainUID: String = "Main",
            mainClock: UInt32?,
            mainTransport: UInt32? = kAudioDeviceTransportTypeUSB
        ) throws -> AudioRouteDriftCompensation {
            let devices = [
                fixtureDevice(
                    objectID: 141,
                    uid: sourceUID,
                    clockDomain: sourceClock,
                    transportType: sourceTransport
                ),
                fixtureDevice(
                    objectID: 142,
                    uid: mainUID,
                    clockDomain: mainClock,
                    transportType: mainTransport
                ),
            ]
            return try planner().plan(fixtureRequest(
                sourceDeviceUIDs: [sourceUID],
                mode: .explicit(targetDeviceUIDs: [mainUID]),
                devices: sourceUID == mainUID ? [devices[0]] : devices
            )).tapSources[0].driftCompensation
        }

        XCTAssertEqual(try drift(
            sourceUID: "Same",
            sourceClock: 0,
            mainUID: "Same",
            mainClock: 0
        ), .disabled)
        XCTAssertEqual(try drift(sourceClock: 42, mainClock: 42), .disabled)
        XCTAssertEqual(try drift(sourceClock: 0, mainClock: 0), .highQuality)
        XCTAssertEqual(try drift(
            sourceClock: 1,
            mainClock: 2,
            mainTransport: kAudioDeviceTransportTypeBluetooth
        ), .disabled)
        XCTAssertEqual(try drift(
            sourceClock: 1,
            mainClock: 2,
            mainTransport: kAudioDeviceTransportTypeBluetoothLE
        ), .disabled)
        XCTAssertEqual(try drift(
            sourceClock: 1,
            sourceTransport: kAudioDeviceTransportTypeVirtual,
            mainClock: 2
        ), .disabled)
    }

    func testConservativePolicyDeniesEveryEmpiricalTransportWithExactFingerprint() throws {
        let cases: [(UInt32?, UInt32?)] = [
            (kAudioDeviceTransportTypeBluetooth, 100),
            (kAudioDeviceTransportTypeBluetoothLE, 100),
            (kAudioDeviceTransportTypeVirtual, 100),
            (kAudioDeviceTransportTypeUSB, 0),
            (kAudioDeviceTransportTypeUSB, 100),
        ]
        for (transport, clock) in cases {
            let target = fixtureDevice(
                objectID: 143,
                uid: "EmpiricalTarget",
                clockDomain: clock,
                transportType: transport
            )
            let request = fixtureRequest(
                mode: .explicit(targetDeviceUIDs: [target.uid]),
                devices: fixtureDevices() + [target]
            )
            let conservative = AudioRoutePlanner()
            let fingerprint = try conservative.topologyFingerprint(for: request)
            XCTAssertThrowsError(try conservative.plan(request)) { error in
                XCTAssertEqual(
                    error as? AudioRoutePlanningError,
                    .nativeValidationRequired(fingerprint)
                )
            }
        }
    }

    func testExactAllowanceDoesNotPermitNearbyFingerprint() throws {
        let allowedRequest = fixtureRequest(mode: .explicit(targetDeviceUIDs: ["USB"]))
        let preflight = planner()
        let allowedFingerprint = try preflight.topologyFingerprint(for: allowedRequest)
        let exact = AudioRoutePlanner(
            policy: AudioRouteNativeValidationPolicy(
                validatedFingerprints: [allowedFingerprint]
            ),
            osBuildProvider: { "25A123" }
        )
        let nearbyRequest = fixtureRequest(mode: .explicit(targetDeviceUIDs: ["HDMI"]))

        XCTAssertTrue(exact.permits(allowedRequest))
        XCTAssertFalse(exact.permits(nearbyRequest))
        XCTAssertNoThrow(try exact.plan(allowedRequest))
        let nearbyFingerprint = try exact.topologyFingerprint(for: nearbyRequest)
        XCTAssertThrowsError(try exact.plan(nearbyRequest)) { error in
            XCTAssertEqual(
                error as? AudioRoutePlanningError,
                .nativeValidationRequired(nearbyFingerprint)
            )
        }
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
        builtInOutputStreams: [AudioRouteStream]? = nil,
        usbOutputStreams: [AudioRouteStream]? = nil,
        hdmiOutputStreams: [AudioRouteStream]? = nil
    ) -> [AudioRouteDevice] {
        [
            fixtureDevice(
                objectID: 10,
                uid: "BuiltIn",
                name: "MacBook Speakers",
                outputStreams: builtInOutputStreams
            ),
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
        clockDomain: UInt32? = 100,
        transportType: UInt32? = kAudioDeviceTransportTypeUSB,
        format: ProcessTapAudioFormat? = nil,
        inputStreams: [AudioRouteStream] = [],
        outputStreams: [AudioRouteStream]? = nil,
        aggregateComposition: AudioRouteAggregateComposition? = nil,
        hasCompleteAggregateComposition: Bool = true
    ) -> AudioRouteDevice {
        AudioRouteDevice(
            objectID: objectID,
            uid: uid,
            name: name ?? uid,
            isAlive: isAlive,
            isAggregate: isAggregate,
            aggregateSubdeviceUIDs: aggregateSubdeviceUIDs,
            inputStreams: inputStreams,
            outputStreams: outputStreams ?? [
                AudioRouteStream(
                    streamObjectID: AudioStreamID(objectID &* 1_000),
                    streamIndex: 0,
                    format: format ?? fixtureFormat()
                ),
            ],
            clockDomain: clockDomain,
            transportType: transportType,
            modelUID: "model.\(uid)",
            driverIdentity: AudioRouteDriverIdentity(
                plugInBundleID: "driver.\(uid)",
                availableVersion: nil
            ),
            aggregateComposition: aggregateComposition ?? (isAggregate && hasCompleteAggregateComposition
                ? AudioRouteAggregateComposition(
                    fullSubdeviceUIDs: aggregateSubdeviceUIDs,
                    activeSubdeviceUIDs: aggregateSubdeviceUIDs,
                    mainSubdeviceUID: aggregateSubdeviceUIDs.first,
                    isStacked: true,
                    tapUUIDs: []
                )
                : nil)
        )
    }

    func planner() -> AudioRoutePlanner {
        AudioRoutePlanner(
            policy: .allowingAllForTesting,
            osBuildProvider: { "25A123" }
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
        planner: AudioRoutePlanner? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try (planner ?? self.planner()).plan(request),
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
