import CoreAudio
import Foundation
@testable import MacActivityCore
import XCTest

final class NativeEvidenceTests: XCTestCase {
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
