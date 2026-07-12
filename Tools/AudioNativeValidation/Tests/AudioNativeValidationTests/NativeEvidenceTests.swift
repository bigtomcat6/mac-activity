import CoreAudio
import Foundation
@testable import MacActivityCore
import XCTest

final class NativeEvidenceTests: XCTestCase {
    @MainActor
    func testOwnedObjectScanFailureWritesCurrentConservativeEvidenceBeforeRethrow() async throws {
        let outputURL = try makeOutputURL()
        defer { try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent()) }
        let status = OSStatus(-32_002)
        let hardware = NativeRecordingAudioTapHardware(teardownOwnedObjects: {
            throw AudioHALError(
                operation: .getData,
                objectID: AudioObjectID(kAudioObjectSystemObject),
                address: nil,
                reason: .status(status)
            )
        })
        let expectedTeardown = NativeTeardownObservation(
            attempts: 7,
            callbackContextReleased: true,
            aggregateIdentityAbsent: false,
            tapIdentitiesAbsent: false
        )

        do {
            _ = try await persistNativeValidationEvidence(
                environment: environment(outputURL: outputURL),
                fingerprint: fingerprint,
                recordingSnapshot: hardware.snapshot,
                runSession: {
                    do {
                        _ = try hardware.observeTeardown(attempt: expectedTeardown.attempts)
                    } catch {
                        throw NativeValidationError.teardownUnproven(String(describing: error))
                    }
                }
            )
            XCTFail("Expected owned object scan failure")
        } catch NativeValidationError.teardownUnproven {
            let record = try decodeRecord(at: outputURL)
            XCTAssertFalse(record.eligibleForPolicyPromotion)
            XCTAssertEqual(record.teardown, expectedTeardown)
            XCTAssertEqual(record.rawFailures, [NativeRawFailure(
                seam: "ownedObjects",
                status: status
            )])
            XCTAssertTrue(record.sessionError?.contains("-32002") == true)
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
            XCTAssertFalse(record.eligibleForPolicyPromotion)
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
            XCTAssertFalse(record.eligibleForPolicyPromotion)
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
            )
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

    private func environment(outputURL: URL) -> NativeValidationEnvironment {
        NativeValidationEnvironment(
            processObjectID: 42,
            targetUIDs: ["output"],
            outputURL: outputURL,
            microphoneTCCObservation: "No prompt appeared.",
            observationSeconds: 1
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
        rawFailures: [NativeRawFailure] = []
    ) -> NativeRecordingSnapshot {
        NativeRecordingSnapshot(
            taps: [],
            tapFormats: [],
            aggregate: nil,
            ioProc: nil,
            topology: nil,
            verifiedInputStreamUsage: [],
            callbackCountBeforeObservation: nil,
            callbackCountAfterObservation: nil,
            teardown: teardown,
            rawFailures: rawFailures
        )
    }

    private func decodeRecord(at outputURL: URL) throws -> NativeAudioValidationRecord {
        try JSONDecoder().decode(
            NativeAudioValidationRecord.self,
            from: Data(contentsOf: outputURL)
        )
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
