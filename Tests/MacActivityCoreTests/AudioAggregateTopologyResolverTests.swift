import CoreAudio
import XCTest
@testable import MacActivityCore

final class AudioAggregateTopologyResolverTests: XCTestCase {
    func testResolverAcceptsOneTapInputAndPreservesPlannedOutputGroups() throws {
        let plan = fixturePlan(outputGroups: [[stereo], [sixChannel]])
        let tap = fixtureTap(source: try XCTUnwrap(plan.tapSources.first))

        let layout = try AudioAggregateTopologyResolver.resolve(
            plan: plan,
            tap: tap,
            snapshot: fixtureSnapshot(
                inputFormats: [stereo],
                outputFormats: [stereo, sixChannel]
            )
        )

        XCTAssertEqual(layout.inputFormats, [stereo])
        XCTAssertEqual(layout.outputFormats, [stereo, sixChannel])
        XCTAssertEqual(layout.inputStreamUsage, [1])
    }

    func testResolverRejectsAnyExtraAggregateInput() {
        assertUnsupported(
            snapshot: fixtureSnapshot(
                inputStreamIDs: [51, 52],
                inputFormats: [stereo, stereo]
            )
        )
    }

    func testResolverRejectsMismatchedTapUUID() {
        assertUnsupported(
            snapshot: fixtureSnapshot(
                tapUUIDs: [UUID(uuidString: "4D414341-0000-4000-8000-000000000099")!]
            )
        )
    }

    func testResolverRejectsSubTapCardinalityOtherThanOne() {
        for ids in [[], [AudioObjectID(900), 901]] {
            assertUnsupported(snapshot: fixtureSnapshot(activeSubTapIDs: ids))
        }
    }

    func testResolverRejectsInputFormatDifferentFromPlannedTap() {
        assertUnsupported(
            snapshot: fixtureSnapshot(
                inputFormats: [fixtureFormat(sampleRate: 44_100, channelCount: 2)]
            )
        )
    }

    func testResolverRejectsOutputCardinalityChange() {
        let plan = fixturePlan(outputGroups: [[stereo], [sixChannel]])
        assertUnsupported(
            plan: plan,
            snapshot: fixtureSnapshot(outputFormats: [stereo])
        )
    }

    func testResolverRejectsUnsupportedActualOutputFormat() {
        let unsupported = ProcessTapAudioFormat(
            sampleRate: 48_000,
            channelCount: 2,
            formatID: kAudioFormatLinearPCM,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            bitsPerChannel: 32,
            interleaving: .interleaved
        )
        let plan = fixturePlan(outputGroups: [[stereo]])
        assertUnsupported(
            plan: plan,
            snapshot: fixtureSnapshot(outputFormats: [unsupported])
        )
    }

    func testResolverRejectsDeadZeroDuplicateAndMismatchedStreamTopology() {
        let plan = fixturePlan(outputGroups: [[stereo], [stereo]])
        let cases = [
            fixtureSnapshot(isAlive: false, outputFormats: [stereo, stereo]),
            fixtureSnapshot(inputStreamIDs: [0], outputFormats: [stereo, stereo]),
            fixtureSnapshot(outputStreamIDs: [61, 61], outputFormats: [stereo, stereo]),
            fixtureSnapshot(outputStreamIDs: [61, 0], outputFormats: [stereo, stereo]),
            fixtureSnapshot(outputStreamIDs: [61], outputFormats: [stereo, stereo]),
        ]
        for snapshot in cases {
            assertUnsupported(plan: plan, snapshot: snapshot)
        }
    }

    func testResolverRejectsMoreThanOnePlannedTapOrWrongTapResource() {
        let source = fixtureSource()
        let extraSource = AudioTapSource(
            deviceUID: "Source.Second",
            streamIndex: 1,
            expectedFormat: stereo,
            driftCompensation: .disabled
        )
        let multiTapPlan = fixturePlan(tapSources: [source, extraSource])
        assertUnsupported(plan: multiTapPlan, tap: fixtureTap(source: source))

        let plan = fixturePlan(tapSources: [source])
        assertUnsupported(plan: plan, tap: fixtureTap(source: extraSource))
    }

    func testResolverDuplicatesMonoToStereoAndAveragesStereoToMono() throws {
        let mono = fixtureFormat(channelCount: 1)
        let monoSourcePlan = fixturePlan(
            tapSources: [fixtureSource(format: mono)],
            outputGroups: [[stereo]]
        )
        let duplicated = try resolve(
            plan: monoSourcePlan,
            snapshot: fixtureSnapshot(inputFormats: [mono], outputFormats: [stereo])
        )
        XCTAssertEqual(duplicated.channelMaps.count, 2)
        XCTAssertEqual(duplicated.channelMaps.map(\.mixCoefficient), [1, 1])
        XCTAssertEqual(duplicated.channelMaps.map(\.input.channelIndex), [0, 0])
        XCTAssertEqual(duplicated.channelMaps.map(\.output.channelIndex), [0, 1])

        let monoTargetPlan = fixturePlan(outputGroups: [[mono]])
        let averaged = try resolve(
            plan: monoTargetPlan,
            snapshot: fixtureSnapshot(outputFormats: [mono])
        )
        XCTAssertEqual(averaged.channelMaps.count, 2)
        XCTAssertEqual(averaged.channelMaps.map(\.mixCoefficient), [0.5, 0.5])
        XCTAssertEqual(averaged.channelMaps.map(\.input.channelIndex), [0, 1])
        XCTAssertEqual(averaged.channelMaps.map(\.output.channelIndex), [0, 0])
    }

    func testResolverMapsCommonChannelsAndLeavesExtraOutputsDeterministicallyUnmapped() throws {
        let fourChannel = fixtureFormat(channelCount: 4)
        let plan = fixturePlan(outputGroups: [[fourChannel]])
        let layout = try resolve(
            plan: plan,
            snapshot: fixtureSnapshot(outputFormats: [fourChannel])
        )

        XCTAssertEqual(layout.channelMaps.count, 2)
        XCTAssertEqual(layout.channelMaps.map(\.input.channelIndex), [0, 1])
        XCTAssertEqual(layout.channelMaps.map(\.output.channelIndex), [0, 1])
    }

    func testResolverExpandsNoninterleavedStreamsIntoSingleChannelABLBuffers() throws {
        let noninterleaved = fixtureFormat(
            channelCount: 3,
            interleaving: .nonInterleaved
        )
        let plan = fixturePlan(
            tapSources: [fixtureSource(format: noninterleaved)],
            outputGroups: [[noninterleaved]]
        )
        let layout = try resolve(
            plan: plan,
            snapshot: fixtureSnapshot(
                inputFormats: [noninterleaved],
                outputFormats: [noninterleaved]
            )
        )
        let oneChannel = fixtureFormat(
            channelCount: 1,
            interleaving: .nonInterleaved
        )

        XCTAssertEqual(layout.inputFormats, Array(repeating: oneChannel, count: 3))
        XCTAssertEqual(layout.outputFormats, Array(repeating: oneChannel, count: 3))
        XCTAssertEqual(layout.channelMaps.map(\.input.bufferIndex), [0, 1, 2])
        XCTAssertEqual(layout.channelMaps.map(\.output.bufferIndex), [0, 1, 2])
    }
}

private extension AudioAggregateTopologyResolverTests {
    var stereo: ProcessTapAudioFormat { fixtureFormat(channelCount: 2) }
    var sixChannel: ProcessTapAudioFormat { fixtureFormat(channelCount: 6) }
    var fixtureTapUUID: UUID {
        UUID(uuidString: "4D414341-0000-4000-8000-000000000001")!
    }

    func resolve(
        plan: AudioRoutePlan,
        snapshot: AudioAggregateTopologySnapshot
    ) throws -> AudioAggregateLayout {
        try AudioAggregateTopologyResolver.resolve(
            plan: plan,
            tap: fixtureTap(source: try XCTUnwrap(plan.tapSources.first)),
            snapshot: snapshot
        )
    }

    func assertUnsupported(
        plan: AudioRoutePlan? = nil,
        tap: AudioTapResource? = nil,
        snapshot: AudioAggregateTopologySnapshot? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let plan = plan ?? fixturePlan()
        let tap = tap ?? fixtureTap(source: plan.tapSources[0])
        XCTAssertThrowsError(
            try AudioAggregateTopologyResolver.resolve(
                plan: plan,
                tap: tap,
                snapshot: snapshot ?? fixtureSnapshot()
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AudioAggregateTopologyError,
                .unsupportedTopology,
                file: file,
                line: line
            )
        }
    }

    func fixturePlan(
        tapSources: [AudioTapSource]? = nil,
        outputGroups: [[ProcessTapAudioFormat]] = [[fixtureFormat()]]
    ) -> AudioRoutePlan {
        let sources = tapSources ?? [fixtureSource()]
        return AudioRoutePlan(
            processObjectID: 77,
            generation: 1,
            tapSources: sources,
            selectedTargetUIDs: outputGroups.indices.map { "Target.\($0)" },
            subdevices: outputGroups.enumerated().map { groupIndex, formats in
                AudioRouteSubdevice(
                    uid: "Target.\(groupIndex)",
                    driftCompensation: groupIndex == 0 ? .disabled : .highQuality,
                    inputStreams: [],
                    outputStreams: formats.enumerated().map { streamIndex, format in
                        AudioRouteStream(
                            streamObjectID: AudioStreamID(100 + groupIndex * 10 + streamIndex),
                            streamIndex: UInt(streamIndex),
                            format: format
                        )
                    }
                )
            },
            mainDeviceUID: "Target.0",
            isStacked: outputGroups.count > 1,
            aggregateUID: "com.how.macactivity.audio.aggregate.fixture",
            topologyFingerprint: AudioRouteTopologyFingerprint(
                osBuild: "25A123",
                sourceDeviceUIDs: ["Source.Device"],
                selectedTargetUIDs: ["Target.0"],
                devices: []
            )
        )
    }

    func fixtureSource(
        format: ProcessTapAudioFormat = fixtureFormat()
    ) -> AudioTapSource {
        AudioTapSource(
            deviceUID: "Source.Device",
            streamIndex: 0,
            expectedFormat: format,
            driftCompensation: .disabled
        )
    }

    func fixtureTap(source: AudioTapSource) -> AudioTapResource {
        AudioTapResource(objectID: 700, uuid: fixtureTapUUID, source: source)
    }

    func fixtureSnapshot(
        isAlive: Bool = true,
        inputStreamIDs: [AudioStreamID] = [51],
        inputFormats: [ProcessTapAudioFormat]? = nil,
        outputStreamIDs: [AudioStreamID]? = nil,
        outputFormats: [ProcessTapAudioFormat]? = nil,
        tapUUIDs: [UUID]? = nil,
        activeSubTapIDs: [AudioObjectID] = [900]
    ) -> AudioAggregateTopologySnapshot {
        let actualOutputs = outputFormats ?? [stereo]
        return AudioAggregateTopologySnapshot(
            isAlive: isAlive,
            inputStreamIDs: inputStreamIDs,
            inputFormats: inputFormats ?? [stereo],
            outputStreamIDs: outputStreamIDs
                ?? actualOutputs.indices.map { AudioStreamID(61 + $0) },
            outputFormats: actualOutputs,
            tapUUIDs: tapUUIDs ?? [fixtureTapUUID],
            activeSubTapIDs: activeSubTapIDs
        )
    }
}

private func fixtureFormat(
    sampleRate: Double = 48_000,
    channelCount: Int = 2,
    interleaving: AudioPCMInterleaving = .interleaved
) -> ProcessTapAudioFormat {
    ProcessTapAudioFormat(
        sampleRate: sampleRate,
        channelCount: channelCount,
        formatID: kAudioFormatLinearPCM,
        formatFlags: kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | (interleaving == .nonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0),
        bitsPerChannel: 32,
        interleaving: interleaving
    )
}
