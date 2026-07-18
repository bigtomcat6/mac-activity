import CoreAudio
import Foundation
@testable import MacActivityCore
import XCTest

final class NativeEvidenceTests: XCTestCase {
    func testCompletedExampleFixtureDecodesWithCoherentRuntimeEvidence() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/validation-matrix.example.json")
        let record = try JSONDecoder().decode(
            NativeAudioValidationRecord.self,
            from: Data(contentsOf: fixtureURL)
        )
        let before = try XCTUnwrap(record.callbackCountBeforeObservation)
        let after = try XCTUnwrap(record.callbackCountAfterObservation)
        let tap = try XCTUnwrap(record.tapResources.first)
        let runtimeValidationCompleted = record.sessionError == nil
            && before != after
            && record.rawFailures.isEmpty
            && record.teardown?.isReleased == true
            && record.tapMuteBehaviorObservations.map(\.observedState)
                == [.unmuted, .mutedWhenTapped, .unmuted]

        XCTAssertEqual(record.sustainedCallbacks, before != after)
        XCTAssertTrue(record.tapMuteBehaviorObservations.allSatisfy {
            $0.diagnosticOnlyObjectID == tap.diagnosticOnlyObjectID
                && $0.uuid == tap.uuid
        })
        XCTAssertTrue(record.resolvedTeardownProbeFailures.isEmpty)
        XCTAssertTrue(runtimeValidationCompleted)
        XCTAssertEqual(
            record.runtimeValidationCompleted,
            runtimeValidationCompleted
        )
    }

    @MainActor
    func testSuccessEvidenceSerializesOrderedPerTapMuteBehaviorObservations() async throws {
        let outputURL = try makeOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let tap = fixtureTap()
        let hardware = NativeRecordingAudioTapHardware(
            delegate: NativeMuteBehaviorProbeHardware(tap: tap)
        )
        let expected = [
            NativeTapMuteBehaviorObservation(
                diagnosticOnlyObjectID: tap.objectID,
                uuid: tap.uuid.uuidString,
                observedState: .unmuted
            ),
            NativeTapMuteBehaviorObservation(
                diagnosticOnlyObjectID: tap.objectID,
                uuid: tap.uuid.uuidString,
                observedState: .mutedWhenTapped
            ),
            NativeTapMuteBehaviorObservation(
                diagnosticOnlyObjectID: tap.objectID,
                uuid: tap.uuid.uuidString,
                observedState: .unmuted
            ),
        ]

        _ = try await persistNativeValidationEvidence(
            environment: environment(outputURL: outputURL),
            fingerprint: fingerprint,
            recordingSnapshot: {
                self.completedSnapshot(from: hardware.snapshot())
            },
            runSession: {
                let createdTap = try hardware.createTap(
                    processObjectID: 42,
                    source: tap.source,
                    uuid: tap.uuid
                )
                XCTAssertEqual(try hardware.readMuteState(for: createdTap), .unmuted)
                try hardware.setMuteState(.mutedWhenTapped, for: createdTap)
                XCTAssertEqual(
                    try hardware.readMuteState(for: createdTap),
                    .mutedWhenTapped
                )
                XCTAssertEqual(hardware.restoreOriginalAudio(for: createdTap), noErr)
            }
        )

        let record = try decodeRecord(at: outputURL)
        XCTAssertEqual(record.tapMuteBehaviorObservations, expected)
        XCTAssertTrue(record.runtimeValidationCompleted)
    }

    @MainActor
    func testMuteReadbackFailureWritesConservativeEvidenceBeforeRethrow() async throws {
        let outputURL = try makeOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let status = OSStatus(-32_003)
        let tap = fixtureTap()
        let failure = NativeRawFailure(
            seam: "readMuteState",
            status: status,
            operation: .getData,
            objectID: tap.objectID,
            selector: kAudioTapPropertyDescription,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        let observedInitialState = NativeTapMuteBehaviorObservation(
            diagnosticOnlyObjectID: tap.objectID,
            uuid: tap.uuid.uuidString,
            observedState: .unmuted
        )
        let hardware = NativeRecordingAudioTapHardware(
            delegate: NativeMuteBehaviorProbeHardware(
                tap: tap,
                readFailureOnInvocation: 2,
                readFailureStatus: status
            )
        )

        do {
            _ = try await persistNativeValidationEvidence(
                environment: environment(outputURL: outputURL),
                fingerprint: fingerprint,
                recordingSnapshot: hardware.snapshot,
                runSession: {
                    let createdTap = try hardware.createTap(
                        processObjectID: 42,
                        source: tap.source,
                        uuid: tap.uuid
                    )
                    XCTAssertEqual(
                        try hardware.readMuteState(for: createdTap),
                        .unmuted
                    )
                    try hardware.setMuteState(.mutedWhenTapped, for: createdTap)
                    _ = try hardware.readMuteState(for: createdTap)
                }
            )
            XCTFail("Expected mute readback failure")
        } catch let error as AudioHALError {
            XCTAssertEqual(error.status, status)
            let record = try decodeRecord(at: outputURL)
            XCTAssertEqual(record.tapMuteBehaviorObservations, [observedInitialState])
            XCTAssertEqual(record.rawFailures, [failure])
            XCTAssertFalse(record.runtimeValidationCompleted)
            XCTAssertTrue(record.sessionError?.contains("-32003") == true)
        }
    }

    @MainActor
    func testRestoreMuteReadbackFailureWritesConservativeEvidenceAndReturnsFailure() async throws {
        let outputURL = try makeOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let status = OSStatus(-32_004)
        let tap = fixtureTap()
        let hardware = NativeRecordingAudioTapHardware(
            delegate: NativeMuteBehaviorProbeHardware(
                tap: tap,
                readFailureOnInvocation: 3,
                readFailureStatus: status
            )
        )

        do {
            _ = try await persistNativeValidationEvidence(
                environment: environment(outputURL: outputURL),
                fingerprint: fingerprint,
                recordingSnapshot: hardware.snapshot,
                runSession: {
                    let createdTap = try hardware.createTap(
                        processObjectID: 42,
                        source: tap.source,
                        uuid: tap.uuid
                    )
                    XCTAssertEqual(
                        try hardware.readMuteState(for: createdTap),
                        .unmuted
                    )
                    try hardware.setMuteState(.mutedWhenTapped, for: createdTap)
                    XCTAssertEqual(
                        try hardware.readMuteState(for: createdTap),
                        .mutedWhenTapped
                    )
                    let restoreStatus = hardware.restoreOriginalAudio(for: createdTap)
                    guard restoreStatus == noErr else {
                        throw NativeValidationError.teardownUnproven(
                            "restore mute readback status \(restoreStatus)"
                        )
                    }
                }
            )
            XCTFail("Expected restore mute readback failure")
        } catch NativeValidationError.teardownUnproven {
            let record = try decodeRecord(at: outputURL)
            XCTAssertEqual(
                record.tapMuteBehaviorObservations.map(\.observedState),
                [.unmuted, .mutedWhenTapped]
            )
            XCTAssertEqual(record.rawFailures, [NativeRawFailure(
                seam: "readMuteState",
                status: status,
                operation: .getData,
                objectID: tap.objectID,
                selector: kAudioTapPropertyDescription,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            )])
            XCTAssertFalse(record.runtimeValidationCompleted)
            XCTAssertTrue(record.sessionError?.contains("-32004") == true)
        }
    }

    @MainActor
    func testRetainedCleanupFailureWritesCurrentEvidenceBeforeRethrow() async throws {
        let outputURL = try makeOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let teardown = NativeTeardownObservation(
            attempts: 1,
            callbackContextReleased: false,
            aggregateIdentityAbsent: false,
            tapIdentitiesAbsent: false
        )
        let status = OSStatus(-32_001)
        let cleanupFailure = AudioTeardownFailure(
            processObjectID: 42,
            operation: .destroyAggregate,
            objectID: 101,
            status: status
        )
        var latestTeardown: NativeTeardownObservation?
        var rawFailures: [NativeRawFailure] = []

        do {
            _ = try await persistNativeValidationEvidence(
                environment: environment(outputURL: outputURL),
                fingerprint: fingerprint,
                recordingSnapshot: { self.snapshot(
                    teardown: latestTeardown,
                    rawFailures: rawFailures
                ) },
                runSession: {
                    do {
                        _ = try await waitForNativeTeardownRelease(
                            maxAttempts: 1,
                            sleep: {},
                            advance: {
                                rawFailures = [NativeRawFailure(
                                    seam: "retainedCleanup.\(cleanupFailure.operation.rawValue)",
                                    status: cleanupFailure.status
                                )]
                                return [cleanupFailure]
                            },
                            observe: { attempt in
                                latestTeardown = teardown
                                XCTAssertEqual(attempt, teardown.attempts)
                                return teardown
                            }
                        )
                    } catch {
                        throw NativeValidationError.teardownUnproven(String(describing: error))
                    }
                }
            )
            XCTFail("Expected retained cleanup failure")
        } catch NativeValidationError.teardownUnproven {
            let record = try decodeRecord(at: outputURL)
            XCTAssertFalse(record.runtimeValidationCompleted)
            XCTAssertEqual(record.teardown, teardown)
            XCTAssertEqual(record.rawFailures, [NativeRawFailure(
                seam: "retainedCleanup.destroyAggregate",
                status: status
            )])
            XCTAssertTrue(record.sessionError?.contains("retainedFailures") == true)
        }
    }

    @MainActor
    func testTeardownTimeoutWritesLatestEvidenceBeforeRethrow() async throws {
        let outputURL = try makeOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let teardown = NativeTeardownObservation(
            attempts: 3,
            callbackContextReleased: true,
            aggregateIdentityAbsent: false,
            tapIdentitiesAbsent: true
        )
        var latestTeardown: NativeTeardownObservation?

        do {
            _ = try await persistNativeValidationEvidence(
                environment: environment(outputURL: outputURL),
                fingerprint: fingerprint,
                recordingSnapshot: { self.snapshot(teardown: latestTeardown) },
                runSession: {
                    do {
                        _ = try await waitForNativeTeardownRelease(
                            maxAttempts: 3,
                            sleep: {},
                            advance: { [] },
                            observe: { attempt in
                                let observation = NativeTeardownObservation(
                                    attempts: attempt,
                                    callbackContextReleased: true,
                                    aggregateIdentityAbsent: false,
                                    tapIdentitiesAbsent: true
                                )
                                latestTeardown = observation
                                return observation
                            }
                        )
                    } catch {
                        throw NativeValidationError.teardownUnproven(String(describing: error))
                    }
                }
            )
            XCTFail("Expected teardown timeout")
        } catch NativeValidationError.teardownUnproven {
            let record = try decodeRecord(at: outputURL)
            XCTAssertFalse(record.runtimeValidationCompleted)
            XCTAssertEqual(record.teardown, teardown)
            XCTAssertTrue(record.rawFailures.isEmpty)
            XCTAssertTrue(record.sessionError?.contains("timeout") == true)
        }
    }

    func testTopologyEvidenceMapsActiveUIDsMainStackedAndExpectedDrift() throws {
        let format = ProcessTapAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            bitsPerChannel: 32,
            interleaving: .interleaved
        )
        let source = AudioTapSource(
            deviceUID: "source",
            streamIndex: 0,
            expectedFormat: format,
            driftCompensation: .highQuality
        )
        let plan = AudioRoutePlan(
            processObjectID: 42,
            processIdentifier: 101,
            generation: 1,
            tapSources: [source],
            selectedTargetUIDs: ["main", "secondary"],
            subdevices: [
                subdevice(uid: "main", drift: .disabled, format: format, streamID: 101),
                subdevice(uid: "secondary", drift: .highQuality, format: format, streamID: 102),
            ],
            mainDeviceUID: "main",
            isStacked: true,
            aggregateUID: "aggregate",
            topologyFingerprint: AudioRouteTopologyFingerprint(
                osBuild: "build",
                sourceDeviceUIDs: ["source"],
                selectedTargetUIDs: ["main", "secondary"],
                devices: []
            ),
            sourceDeviceIDs: [42],
            referencedDeviceIDs: [42]
        )
        let tap = AudioTapResource(objectID: 200, uuid: UUID(), source: source)
        let snapshot = AudioAggregateTopologySnapshot(
            isAlive: true,
            inputStreamIDs: [301],
            inputFormats: [format],
            outputStreamIDs: [302, 303],
            outputFormats: [format, format],
            tapUUIDs: [tap.uuid],
            activeSubTapIDs: [400]
        )
        let layout = AudioAggregateLayout(
            inputFormats: [format],
            outputFormats: [format, format],
            channelMaps: [],
            inputStreamUsage: [1]
        )

        let evidence = try NativeTopologyEvidence.make(
            plan: plan,
            tap: tap,
            snapshot: snapshot,
            layout: layout,
            fullSubdeviceUIDs: ["main", "secondary"],
            activeSubdevices: [
                NativeObservedDrift(
                    uid: "secondary",
                    diagnosticOnlyObjectID: 502,
                    enabled: 1,
                    quality: kAudioAggregateDriftCompensationHighQuality
                ),
                NativeObservedDrift(
                    uid: "main",
                    diagnosticOnlyObjectID: 501,
                    enabled: 0,
                    quality: 0
                ),
            ],
            actualMainSubdeviceUID: "main",
            actualIsStacked: true,
            subTap: NativeObservedDrift(
                uid: tap.uuid.uuidString,
                diagnosticOnlyObjectID: 400,
                enabled: 1,
                quality: kAudioAggregateDriftCompensationHighQuality
            )
        )

        XCTAssertEqual(evidence.activeSubdeviceUIDs, ["secondary", "main"])
        XCTAssertTrue(evidence.activeSubdeviceMembershipMatchesExpected)
        XCTAssertTrue(evidence.fullSubdeviceOrderMatchesExpected)
        XCTAssertTrue(evidence.mainSubdeviceMatchesExpected)
        XCTAssertTrue(evidence.isStackedMatchesExpected)
        XCTAssertTrue(evidence.subdevices.allSatisfy(\.driftMatchesExpected))
        XCTAssertEqual(evidence.subTap.tapUUID, tap.uuid.uuidString)
        XCTAssertEqual(evidence.subTap.sourceDeviceUID, "source")
        XCTAssertTrue(evidence.subTap.driftMatchesExpected)
    }

    func testAggregateCompositionReadsSubdeviceDriftWithoutPhysicalDeviceProperties() throws {
        let composition: NSDictionary = [
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: "main",
                    kAudioSubDeviceDriftCompensationKey: false,
                ],
                [
                    kAudioSubDeviceUIDKey: "secondary",
                    kAudioSubDeviceDriftCompensationKey: true,
                    kAudioSubDeviceDriftCompensationQualityKey:
                        kAudioAggregateDriftCompensationHighQuality,
                ],
            ],
        ]

        XCTAssertEqual(
            try NativeAggregateComposition.subdeviceDrifts(from: composition),
            [
                NativeCompositionSubdeviceDrift(
                    uid: "main",
                    enabled: 0,
                    quality: 0
                ),
                NativeCompositionSubdeviceDrift(
                    uid: "secondary",
                    enabled: 1,
                    quality: kAudioAggregateDriftCompensationHighQuality
                ),
            ]
        )
    }

    func testAggregateCompositionReadsSubTapDriftWithoutSubTapObjectProperties() throws {
        let uuid = UUID().uuidString
        let composition: NSDictionary = [
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uuid,
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey:
                    kAudioAggregateDriftCompensationHighQuality,
            ]],
        ]

        XCTAssertEqual(
            try NativeAggregateComposition.subTapDrift(from: composition, uuid: uuid),
            NativeCompositionSubTapDrift(
                uuid: uuid,
                enabled: 1,
                quality: kAudioAggregateDriftCompensationHighQuality
            )
        )
    }

    func testAggregateCompositionRejectsMissingOrDuplicateSubTap() {
        let uuid = UUID().uuidString
        let duplicateTap: [String: Any] = [
            kAudioSubTapUIDKey: uuid,
            kAudioSubTapDriftCompensationKey: false,
        ]
        let composition: NSDictionary = [
            kAudioAggregateDeviceTapListKey: [duplicateTap, duplicateTap],
        ]

        XCTAssertThrowsError(
            try NativeAggregateComposition.subTapDrift(from: composition, uuid: uuid)
        )
    }

    func testAggregateCompositionRejectsFractionalDriftValue() {
        let composition: NSDictionary = [
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: "main",
                kAudioSubDeviceDriftCompensationKey: 1.5,
                kAudioSubDeviceDriftCompensationQualityKey:
                    kAudioAggregateDriftCompensationHighQuality,
            ]],
        ]

        XCTAssertThrowsError(try NativeAggregateComposition.subdeviceDrifts(from: composition))
    }

    func testAggregateCompositionRejectsOutOfRangeDriftQuality() {
        let composition: NSDictionary = [
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: "main",
                kAudioSubDeviceDriftCompensationKey: true,
                kAudioSubDeviceDriftCompensationQualityKey:
                    NSNumber(value: UInt64(UInt32.max) + 1),
            ]],
        ]

        XCTAssertThrowsError(try NativeAggregateComposition.subdeviceDrifts(from: composition))
    }

    func testDelegateTopologyWaitFailureRecordsDelegateSeam() throws {
        let tap = fixtureTap()
        let aggregate = AudioAggregateResource(objectID: 701, uid: "aggregate")
        let failure = AudioHALError(
            operation: .getData,
            objectID: aggregate.objectID,
            address: .init(selector: kAudioAggregateDevicePropertyComposition),
            reason: .status(kAudioHardwareUnknownPropertyError)
        )
        let hardware = NativeRecordingAudioTapHardware(
            delegate: NativeSessionProbeHardware(
                tap: tap,
                aggregate: aggregate,
                waitError: failure
            )
        )

        XCTAssertThrowsError(
            try hardware.waitForStableTopology(
                aggregate,
                deadline: .now() + .seconds(1),
                isCancelled: { false }
            )
        )
        XCTAssertEqual(hardware.snapshot().rawFailures, [NativeRawFailure(
            seam: "waitForStableTopology.delegate",
            status: kAudioHardwareUnknownPropertyError,
            operation: .getData,
            objectID: aggregate.objectID,
            selector: kAudioAggregateDevicePropertyComposition,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )])
    }

    func testTeardownPollingWaitsForDeferredIdentityDisappearance() async throws {
        let sequence = NativeTeardownSequence([
            NativeTeardownObservation(
                attempts: 1,
                callbackContextReleased: false,
                aggregateIdentityAbsent: false,
                tapIdentitiesAbsent: false
            ),
            NativeTeardownObservation(
                attempts: 2,
                callbackContextReleased: true,
                aggregateIdentityAbsent: false,
                tapIdentitiesAbsent: true
            ),
            NativeTeardownObservation(
                attempts: 3,
                callbackContextReleased: true,
                aggregateIdentityAbsent: true,
                tapIdentitiesAbsent: true
            ),
        ])

        let observation = try await waitForNativeTeardownRelease(
            maxAttempts: 3,
            sleep: {},
            advance: { [] },
            observe: { attempt in sequence.next(attempt: attempt) }
        )

        XCTAssertEqual(observation.attempts, 3)
        XCTAssertEqual(sequence.readCount, 3)
        XCTAssertTrue(observation.isReleased)
    }

    func testTeardownPollingRetriesIndeterminateIdentityUntilLaterPositiveAbsence() async throws {
        let status = OSStatus(-308)
        let sequence = NativeTeardownSequence([
            NativeTeardownObservation(
                attempts: 1,
                callbackContextReleased: true,
                aggregateIdentity: .indeterminate(status),
                tapIdentities: .absent
            ),
            NativeTeardownObservation(
                attempts: 2,
                callbackContextReleased: true,
                aggregateIdentity: .absent,
                tapIdentities: .absent
            ),
        ])

        let observation = try await waitForNativeTeardownRelease(
            maxAttempts: 2,
            sleep: {},
            advance: { [] },
            observe: { attempt in sequence.next(attempt: attempt) }
        )

        XCTAssertEqual(sequence.readCount, 2)
        XCTAssertEqual(observation.aggregateIdentity, .absent)
        XCTAssertEqual(observation.tapIdentities, .absent)
        XCTAssertTrue(observation.isReleased)
    }

    func testTeardownPollingTimesOutForPersistentIndeterminateIdentity() async throws {
        let status = OSStatus(-308)
        let sequence = NativeTeardownSequence([
            NativeTeardownObservation(
                attempts: 1,
                callbackContextReleased: true,
                aggregateIdentity: .indeterminate(status),
                tapIdentities: .absent
            ),
            NativeTeardownObservation(
                attempts: 2,
                callbackContextReleased: true,
                aggregateIdentity: .indeterminate(status),
                tapIdentities: .absent
            ),
        ])

        do {
            _ = try await waitForNativeTeardownRelease(
                maxAttempts: 2,
                sleep: {},
                advance: { [] },
                observe: { attempt in sequence.next(attempt: attempt) }
            )
            XCTFail("Expected indeterminate identity teardown to time out")
        } catch let NativeTeardownWaitError.timeout(observation) {
            XCTAssertEqual(sequence.readCount, 2)
            XCTAssertEqual(observation.aggregateIdentity, .indeterminate(status))
            XCTAssertFalse(observation.isReleased)
        }
    }

    @MainActor
    func testRunSessionRetainsResolvedTransientTeardownProbeFailureInEvidence() async throws {
        let outputURL = try makeOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let tap = fixtureTap()
        let aggregate = AudioAggregateResource(objectID: 701, uid: "aggregate")
        let status = OSStatus(-308)
        let probes = NativeTeardownProbeSequence(
            transientFailure: AudioHALError(
                operation: .getData,
                objectID: aggregate.objectID,
                address: .init(selector: kAudioObjectPropertyClass),
                reason: .status(status)
            ),
            aggregateID: aggregate.objectID
        )
        let hardware = NativeRecordingAudioTapHardware(
            delegate: NativeSessionProbeHardware(tap: tap, aggregate: aggregate),
            identityProbe: probes.observe
        )
        let plan = sessionPlan(source: tap.source, aggregateUID: aggregate.uid)
        var context: ProcessTapDSPContext? = try fixtureDSPContext()
        let engine = NativeSessionEngine(context: try XCTUnwrap(context))

        _ = try hardware.createTap(
            processObjectID: plan.processObjectID,
            source: tap.source,
            uuid: tap.uuid
        )
        _ = try hardware.createAggregate(plan: plan, taps: [tap])
        _ = try hardware.createIOProc(
            aggregate: aggregate,
            context: try XCTUnwrap(context)
        )
        context = nil

        try await runNativeSessionBody(
            environment: environment(outputURL: outputURL, observationSeconds: 0),
            plan: plan,
            hardware: hardware,
            engine: engine
        )

        let snapshot = hardware.snapshot()
        XCTAssertTrue(try XCTUnwrap(snapshot.teardown).isReleased)
        XCTAssertEqual(probes.aggregateProbeCount, 2)
        XCTAssertTrue(snapshot.unresolvedRawFailures.isEmpty)
        XCTAssertTrue(snapshot.rawFailures.isEmpty)
        XCTAssertEqual(snapshot.resolvedTeardownProbeFailures, [NativeRawFailure(
            seam: "observeTeardown.aggregateIdentity",
            status: status,
            operation: .getData,
            objectID: aggregate.objectID,
            selector: kAudioObjectPropertyClass,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )])
    }

    private func subdevice(
        uid: String,
        drift: AudioRouteDriftCompensation,
        format: ProcessTapAudioFormat,
        streamID: AudioStreamID
    ) -> AudioRouteSubdevice {
        AudioRouteSubdevice(
            uid: uid,
            driftCompensation: drift,
            inputStreams: [],
            outputStreams: [AudioRouteStream(
                streamObjectID: streamID,
                streamIndex: 0,
                format: format
            )]
        )
    }

    private func makeOutputURL() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("MacActivityNativeEvidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory.appendingPathComponent("evidence.json")
    }

    private func environment(
        outputURL: URL,
        observationSeconds: Double = 1
    ) -> NativeValidationEnvironment {
        NativeValidationEnvironment(
            processObjectID: 42,
            targetUIDs: ["output"],
            outputURL: outputURL,
            microphoneTCCObservation: "No prompt appeared.",
            observationSeconds: observationSeconds
        )
    }

    private func sessionPlan(
        source: AudioTapSource,
        aggregateUID: String
    ) -> AudioRoutePlan {
        AudioRoutePlan(
            processObjectID: 42,
            processIdentifier: 42,
            generation: 1,
            tapSources: [source],
            selectedTargetUIDs: ["output"],
            subdevices: [],
            mainDeviceUID: "output",
            isStacked: false,
            aggregateUID: aggregateUID,
            topologyFingerprint: fingerprint,
            sourceDeviceIDs: [42],
            referencedDeviceIDs: [42]
        )
    }

    private func fixtureDSPContext() throws -> ProcessTapDSPContext {
        let format = ProcessTapAudioFormat(
            sampleRate: 48_000,
            channelCount: 1,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            bitsPerChannel: 32,
            interleaving: .interleaved
        )
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
                channelMaps: [ProcessTapChannelMap(
                    input: address,
                    output: address,
                    mixCoefficient: 1
                )]
            ),
            initialGain: 1
        )
    }

    private var fingerprint: AudioRouteTopologyFingerprint {
        AudioRouteTopologyFingerprint(
            osBuild: "build",
            sourceDeviceUIDs: ["source"],
            selectedTargetUIDs: ["output"],
            devices: []
        )
    }

    private func snapshot(
        teardown: NativeTeardownObservation?,
        tapMuteBehaviorObservations: [NativeTapMuteBehaviorObservation] = [],
        rawFailures: [NativeRawFailure] = [],
        resolvedTeardownProbeFailures: [NativeRawFailure] = [],
        unresolvedRawFailures: [NativeRawFailure]? = nil
    ) -> NativeRecordingSnapshot {
        NativeRecordingSnapshot(
            taps: [],
            tapFormats: [],
            tapMuteBehaviorObservations: tapMuteBehaviorObservations,
            aggregate: nil,
            ioProc: nil,
            topology: nil,
            verifiedInputStreamUsage: [],
            callbackCountBeforeObservation: nil,
            callbackCountAfterObservation: nil,
            teardown: teardown,
            rawFailures: rawFailures,
            resolvedTeardownProbeFailures: resolvedTeardownProbeFailures,
            unresolvedRawFailures: unresolvedRawFailures ?? rawFailures
        )
    }

    private func completedSnapshot(
        from snapshot: NativeRecordingSnapshot
    ) -> NativeRecordingSnapshot {
        NativeRecordingSnapshot(
            taps: snapshot.taps,
            tapFormats: snapshot.tapFormats,
            tapMuteBehaviorObservations: snapshot.tapMuteBehaviorObservations,
            aggregate: snapshot.aggregate,
            ioProc: snapshot.ioProc,
            topology: snapshot.topology,
            verifiedInputStreamUsage: snapshot.verifiedInputStreamUsage,
            callbackCountBeforeObservation: 1,
            callbackCountAfterObservation: 2,
            teardown: NativeTeardownObservation(
                attempts: 1,
                callbackContextReleased: true,
                aggregateIdentity: .absent,
                tapIdentities: .absent
            ),
            rawFailures: snapshot.rawFailures,
            resolvedTeardownProbeFailures: snapshot.resolvedTeardownProbeFailures,
            unresolvedRawFailures: snapshot.unresolvedRawFailures
        )
    }

    private func decodeRecord(at outputURL: URL) throws -> NativeAudioValidationRecord {
        try JSONDecoder().decode(
            NativeAudioValidationRecord.self,
            from: Data(contentsOf: outputURL)
        )
    }

    private func fixtureTap() -> AudioTapResource {
        let format = ProcessTapAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            bitsPerChannel: 32,
            interleaving: .interleaved
        )
        return AudioTapResource(
            objectID: 700,
            uuid: UUID(uuidString: "4D414341-0000-4000-8000-000000000700")!,
            source: AudioTapSource(
                deviceUID: "source",
                streamIndex: 0,
                expectedFormat: format,
                driftCompensation: .disabled
            )
        )
    }
}

private final class NativeMuteBehaviorProbeHardware: AudioTapHardware, @unchecked Sendable {
    private let tap: AudioTapResource
    private let readFailureOnInvocation: Int?
    private let readFailureStatus: OSStatus
    private var state: AudioTapMuteState = .unmuted
    private var readInvocationCount = 0

    init(
        tap: AudioTapResource,
        readFailureOnInvocation: Int? = nil,
        readFailureStatus: OSStatus = kAudioHardwareUnspecifiedError
    ) {
        self.tap = tap
        self.readFailureOnInvocation = readFailureOnInvocation
        self.readFailureStatus = readFailureStatus
    }

    func validateFreshRoutePlan(_ plan: AudioRoutePlan) throws {
        // This evidence-only fake never creates or mutates an audio route.
    }

    func createTap(
        processObjectID: AudioObjectID,
        source: AudioTapSource,
        uuid: UUID
    ) throws -> AudioTapResource {
        tap
    }

    func readTapFormat(_ tap: AudioTapResource) throws -> ProcessTapAudioFormat {
        fatalError("unreachable")
    }

    func readMuteState(for tap: AudioTapResource) throws -> AudioTapMuteState {
        readInvocationCount += 1
        if readInvocationCount == readFailureOnInvocation {
            throw AudioHALError(
                operation: .getData,
                objectID: tap.objectID,
                address: .init(selector: kAudioTapPropertyDescription),
                reason: .status(readFailureStatus)
            )
        }
        return state
    }

    func createAggregate(
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateResource {
        fatalError("unreachable")
    }

    func waitForStableTopology(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AudioAggregateTopologySnapshot {
        fatalError("unreachable")
    }

    func createIOProc(
        aggregate: AudioAggregateResource,
        context: ProcessTapDSPContext
    ) throws -> AudioIOProcResource {
        fatalError("unreachable")
    }

    func start(_ ioProc: AudioIOProcResource) throws {
        fatalError("unreachable")
    }

    func configureInputStreamUsage(
        _ usage: [UInt32],
        for ioProc: AudioIOProcResource
    ) throws -> [UInt32] {
        fatalError("unreachable")
    }

    func setMuteState(
        _ state: AudioTapMuteState,
        for tap: AudioTapResource
    ) throws {
        self.state = state
    }

    func restoreOriginalAudio(for tap: AudioTapResource) -> OSStatus {
        state = .unmuted
        return noErr
    }

    func stop(_ ioProc: AudioIOProcResource) -> OSStatus {
        fatalError("unreachable")
    }

    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus {
        fatalError("unreachable")
    }

    func destroyAggregate(_ aggregate: AudioAggregateResource) -> OSStatus {
        fatalError("unreachable")
    }

    func aggregateIdentityIsPresent(_ aggregate: AudioAggregateResource) throws -> Bool {
        false
    }

    func destroyTap(_ tap: AudioTapResource) -> OSStatus {
        fatalError("unreachable")
    }

}

private final class NativeTeardownSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [NativeTeardownObservation]
    private var readCountStorage = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCountStorage
    }

    init(_ observations: [NativeTeardownObservation]) {
        self.observations = observations
    }

    func next(attempt: Int) -> NativeTeardownObservation {
        lock.lock()
        defer { lock.unlock() }
        readCountStorage += 1
        return observations.removeFirst()
    }
}

private final class NativeTeardownProbeSequence: @unchecked Sendable {
    private let transientFailure: AudioHALError
    private let aggregateID: AudioObjectID
    private let lock = NSLock()
    private var aggregateProbeCountStorage = 0

    var aggregateProbeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return aggregateProbeCountStorage
    }

    init(transientFailure: AudioHALError, aggregateID: AudioObjectID) {
        self.transientFailure = transientFailure
        self.aggregateID = aggregateID
    }

    func observe(
        objectID: AudioObjectID,
        _: AudioClassID,
        _: String
    ) throws -> NativeTeardownIdentityObservation {
        guard objectID == aggregateID else { return .absent }
        lock.lock()
        defer { lock.unlock() }
        aggregateProbeCountStorage += 1
        if aggregateProbeCountStorage == 1 { throw transientFailure }
        return .absent
    }
}

private final class NativeSessionEngine: ProcessTapVolumeControlling, @unchecked Sendable {
    let sessionSnapshots: AsyncStream<ProcessTapSessionSnapshot>
    private var context: ProcessTapDSPContext?

    init(context: ProcessTapDSPContext) {
        self.context = context
        sessionSnapshots = AsyncStream { continuation in continuation.finish() }
    }

    func apply(
        plan: AudioRoutePlan,
        gain _: ProcessGainState
    ) async -> ProcessTapSessionSnapshot {
        ProcessTapSessionSnapshot(
            processObjectID: plan.processObjectID,
            generation: plan.generation,
            state: .running,
            error: nil
        )
    }

    func updateGain(_: ProcessGainState, for _: AudioObjectID) async {}

    func stop(
        processObjectID: AudioObjectID,
        generation: UInt64
    ) async -> ProcessTapSessionSnapshot {
        context = nil
        return ProcessTapSessionSnapshot(
            processObjectID: processObjectID,
            generation: generation,
            state: .idle,
            error: nil
        )
    }

    func stopAll() async {}

    func prepareRuntime() async -> ProcessTapRuntimePreparation {
        .ready(cleanupFailures: [])
    }

    func shutdown() async {}
}

private final class NativeSessionProbeHardware: AudioTapHardware, @unchecked Sendable {
    private let tap: AudioTapResource
    private let aggregate: AudioAggregateResource
    private let waitError: AudioHALError?

    init(
        tap: AudioTapResource,
        aggregate: AudioAggregateResource,
        waitError: AudioHALError? = nil
    ) {
        self.tap = tap
        self.aggregate = aggregate
        self.waitError = waitError
    }

    func validateFreshRoutePlan(_: AudioRoutePlan) throws {}

    func createTap(
        processObjectID _: AudioObjectID,
        source _: AudioTapSource,
        uuid _: UUID
    ) throws -> AudioTapResource {
        tap
    }

    func readTapFormat(_: AudioTapResource) throws -> ProcessTapAudioFormat { fatalError("unreachable") }

    func readMuteState(for _: AudioTapResource) throws -> AudioTapMuteState { fatalError("unreachable") }

    func createAggregate(
        plan _: AudioRoutePlan,
        taps _: [AudioTapResource]
    ) throws -> AudioAggregateResource {
        aggregate
    }

    func waitForStableTopology(
        _: AudioAggregateResource,
        deadline _: DispatchTime,
        isCancelled _: @escaping @Sendable () -> Bool
    ) throws -> AudioAggregateTopologySnapshot {
        if let waitError { throw waitError }
        fatalError("unreachable")
    }

    func createIOProc(
        aggregate _: AudioAggregateResource,
        context _: ProcessTapDSPContext
    ) throws -> AudioIOProcResource {
        AudioIOProcResource(
            aggregateDeviceID: aggregate.objectID,
            aggregateUID: aggregate.uid,
            ioProcID: nativeSessionIOProc
        )
    }

    func start(_: AudioIOProcResource) throws {}

    func configureInputStreamUsage(
        _: [UInt32],
        for _: AudioIOProcResource
    ) throws -> [UInt32] {
        fatalError("unreachable")
    }

    func setMuteState(_: AudioTapMuteState, for _: AudioTapResource) throws {}

    func restoreOriginalAudio(for _: AudioTapResource) -> OSStatus { noErr }

    func stop(_: AudioIOProcResource) -> OSStatus { noErr }

    func destroyIOProc(_: AudioIOProcResource) -> OSStatus { noErr }

    func destroyAggregate(_: AudioAggregateResource) -> OSStatus { noErr }

    func aggregateIdentityIsPresent(_: AudioAggregateResource) throws -> Bool { false }

    func destroyTap(_: AudioTapResource) -> OSStatus { noErr }
}

private let nativeSessionIOProc: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }
