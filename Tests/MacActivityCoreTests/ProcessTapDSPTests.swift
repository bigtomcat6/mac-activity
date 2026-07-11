import CoreAudio
import XCTest

@testable import MacActivityCore

final class ProcessTapDSPTests: XCTestCase {
    func testCallbackCountChangesOnlyWhenCallbacksAreObserved() throws {
        let context = try makeMonoContext(outputBufferCount: 1)
        XCTAssertEqual(context.callbackCount, 0)
        context.setTargetGain(0.5)
        context.setOutputGateOpen(true)
        XCTAssertEqual(context.callbackCount, 0)

        context.markCallbackObserved()
        context.markCallbackObserved()
        XCTAssertEqual(context.callbackCount, 2)
        XCTAssertTrue(context.hasObservedCallback)
    }
    func testInterleavedStereoMappingPreservesHALByteSizes() throws {
        let storage = AudioBufferListTestStorage.interleavedStereo(
            input: [1, -1, 0.5, -0.5],
            outputFrameCount: 2
        )
        let inputSizesBefore = storage.inputByteSizes
        let outputSizesBefore = storage.outputByteSizes
        let context = try makeInterleavedContext(
            channelCount: 2,
            maps: [
                map(inputChannel: 0, outputChannel: 0, interleavedChannelCount: 2),
                map(inputChannel: 1, outputChannel: 1, interleavedChannelCount: 2),
            ],
            initialGain: 0.5
        )
        context.setOutputGateOpen(true)

        storage.process(with: context)

        XCTAssertEqual(storage.outputSamples, [0.5, -0.5, 0.25, -0.25])
        XCTAssertEqual(storage.inputByteSizes, inputSizesBefore)
        XCTAssertEqual(storage.outputByteSizes, outputSizesBefore)
    }

    func testNonInterleavedMonoDuplicatesToStereoAndZerosUnmappedBuffer() throws {
        let storage = AudioBufferListTestStorage.nonInterleaved(
            inputs: [[0.25, 0.5]],
            outputs: [[9, 9], [9, 9], [9, 9]]
        )
        let format = audioFormat(channelCount: 1, interleaving: .nonInterleaved)
        let configuration = try ProcessTapDSPConfiguration.validated(
            sampleRate: 48_000,
            inputFormats: [format],
            outputFormats: [format, format, format],
            channelMaps: [
                map(inputBuffer: 0, outputBuffer: 0),
                map(inputBuffer: 0, outputBuffer: 1),
            ]
        )
        let context = ProcessTapDSPContext(configuration: configuration, initialGain: 1)
        context.setOutputGateOpen(true)

        storage.process(with: context)

        XCTAssertEqual(storage.outputBuffers[0], [0.25, 0.5])
        XCTAssertEqual(storage.outputBuffers[1], [0.25, 0.5])
        XCTAssertEqual(storage.outputBuffers[2], [0, 0])
    }

    func testRampLengthUsesActualSampleRate() throws {
        for (sampleRate, expectedFrames) in [(48_000.0, 1_440), (44_100.0, 1_323)] {
            let context = try makeInterleavedContext(
                sampleRate: sampleRate,
                channelCount: 1,
                maps: [map()],
                initialGain: 1
            )
            context.setOutputGateOpen(true)
            context.setTargetGain(0)

            processConstantOne(frameCount: expectedFrames - 1, through: context)
            XCTAssertGreaterThan(context.testingCurrentGain, 0)

            processConstantOne(frameCount: 1, through: context)
            XCTAssertEqual(context.testingCurrentGain, 0, accuracy: 0.000_001)
        }
    }

    func testTargetChangeRestartsRampFromCurrentGain() throws {
        let context = try makeInterleavedContext(
            channelCount: 1,
            maps: [map()],
            initialGain: 1
        )
        context.setOutputGateOpen(true)
        context.setTargetGain(0)
        processConstantOne(frameCount: 720, through: context)
        let midpoint = context.testingCurrentGain

        context.setTargetGain(0.75)
        processConstantOne(frameCount: 1, through: context)

        XCTAssertGreaterThan(context.testingCurrentGain, midpoint)
        XCTAssertLessThan(context.testingCurrentGain - midpoint, 0.001)
    }

    func testClosedGateOutputsSilenceWithoutAdvancingRamp() throws {
        let storage = AudioBufferListTestStorage(
            inputs: [[1, 1, 1, 1]],
            inputChannelCounts: [1],
            outputs: [[9, 9, 9, 9]],
            outputChannelCounts: [1]
        )
        let context = try makeInterleavedContext(
            channelCount: 1,
            maps: [map()],
            initialGain: 1
        )
        context.setTargetGain(0)

        storage.process(with: context)

        XCTAssertEqual(storage.outputSamples, [0, 0, 0, 0])
        XCTAssertEqual(context.testingCurrentGain, 1)
    }

    func testRealByteCapacitiesBoundUnequalInputAndOutputBuffers() throws {
        let context = try makeInterleavedContext(
            channelCount: 1,
            maps: [map()],
            initialGain: 1
        )
        context.setOutputGateOpen(true)
        let shortInput = AudioBufferListTestStorage(
            inputs: [[1, 2]],
            inputChannelCounts: [1],
            outputs: [[9, 9, 9, 9]],
            outputChannelCounts: [1]
        )

        shortInput.process(with: context)

        XCTAssertEqual(shortInput.outputSamples, [1, 2, 0, 0])

        let shortOutput = AudioBufferListTestStorage(
            inputs: [[1, 2, 3, 4]],
            inputChannelCounts: [1],
            outputs: [[9, 9, 7, 7]],
            outputChannelCounts: [1],
            outputByteSizes: [UInt32(2 * MemoryLayout<Float32>.stride)]
        )
        let outputSizesBefore = shortOutput.outputByteSizes

        shortOutput.process(with: context)

        XCTAssertEqual(shortOutput.outputSamples, [1, 2, 7, 7])
        XCTAssertEqual(shortOutput.outputByteSizes, outputSizesBefore)
    }

    func testUnavailableOutputDataDoesNotAdvanceRamp() throws {
        let storage = AudioBufferListTestStorage(
            inputs: [[1]],
            inputChannelCounts: [1],
            outputs: [[9]],
            outputChannelCounts: [1]
        )
        storage.makeOutputDataUnavailable(at: 0)
        let context = try makeInterleavedContext(
            channelCount: 1,
            maps: [map()],
            initialGain: 1
        )
        context.setOutputGateOpen(true)
        context.setTargetGain(0)

        storage.process(with: context)

        XCTAssertEqual(context.testingCurrentGain, 1)
    }

    func testUnavailableMappedOutputWithValidUnmappedOutputDoesNotAdvanceRamp() throws {
        let storage = AudioBufferListTestStorage(
            inputs: [[1]],
            inputChannelCounts: [1],
            outputs: [[9], [9]],
            outputChannelCounts: [1, 1]
        )
        storage.makeOutputDataUnavailable(at: 0)
        let context = try makeMonoContext(outputBufferCount: 2)
        context.setOutputGateOpen(true)
        context.setTargetGain(0)

        storage.process(with: context)

        XCTAssertEqual(context.testingCurrentGain, 1)
        XCTAssertEqual(storage.outputBuffers[1], [0])
    }

    func testLongerUnmappedOutputDoesNotExtendRampPastMappedCapacity() throws {
        let storage = AudioBufferListTestStorage(
            inputs: [[1, 1, 1, 1]],
            inputChannelCounts: [1],
            outputs: [[9, 9, 7, 7], [9, 9, 9, 9]],
            outputChannelCounts: [1, 1],
            outputByteSizes: [
                UInt32(2 * MemoryLayout<Float32>.stride),
                UInt32(4 * MemoryLayout<Float32>.stride),
            ]
        )
        let context = try makeMonoContext(outputBufferCount: 2)
        context.setOutputGateOpen(true)
        context.setTargetGain(0)

        storage.process(with: context)

        let expectedGain = 1 - Float32(2) / Float32(1_440)
        XCTAssertEqual(context.testingCurrentGain, expectedGain, accuracy: 0.000_001)
        XCTAssertEqual(storage.outputBuffers[1], [0, 0, 0, 0])
    }

    func testDifferingMappedOutputsAdvanceRampThroughLongestSafeCapacity() throws {
        let storage = AudioBufferListTestStorage(
            inputs: [[1, 1, 1, 1]],
            inputChannelCounts: [1],
            outputs: [[9, 9, 7, 7], [9, 9, 9, 9]],
            outputChannelCounts: [1, 1],
            outputByteSizes: [
                UInt32(2 * MemoryLayout<Float32>.stride),
                UInt32(4 * MemoryLayout<Float32>.stride),
            ]
        )
        let mono = audioFormat(channelCount: 1)
        let configuration = try ProcessTapDSPConfiguration.validated(
            sampleRate: 48_000,
            inputFormats: [mono],
            outputFormats: [mono, mono],
            channelMaps: [
                map(outputBuffer: 0),
                map(outputBuffer: 1),
            ]
        )
        let context = ProcessTapDSPContext(configuration: configuration, initialGain: 1)
        context.setOutputGateOpen(true)
        context.setTargetGain(0)

        storage.process(with: context)

        let expectedGain = 1 - Float32(4) / Float32(1_440)
        XCTAssertEqual(context.testingCurrentGain, expectedGain, accuracy: 0.000_001)
    }

    func testBufferListStorageOwnsAdvertisedOutputByteCapacity() {
        let storage = AudioBufferListTestStorage(
            inputs: [[1]],
            inputChannelCounts: [1],
            outputs: [[9]],
            outputChannelCounts: [1],
            outputByteSizes: [UInt32(3 * MemoryLayout<Float32>.stride)]
        )

        XCTAssertEqual(storage.outputByteSizes, [UInt32(3 * MemoryLayout<Float32>.stride)])
        XCTAssertEqual(storage.outputSamples, [9, 0, 0])
    }

    func testMultichannelMappingUsesExplicitInterleavedAddresses() throws {
        let storage = AudioBufferListTestStorage(
            inputs: [[1, 2, 3, 4, 5, 6]],
            inputChannelCounts: [3],
            outputs: [[9, 9, 9, 9, 9, 9, 9, 9]],
            outputChannelCounts: [4]
        )
        let inputFormat = audioFormat(channelCount: 3)
        let outputFormat = audioFormat(channelCount: 4)
        let configuration = try ProcessTapDSPConfiguration.validated(
            sampleRate: 48_000,
            inputFormats: [inputFormat],
            outputFormats: [outputFormat],
            channelMaps: [
                ProcessTapChannelMap(
                    input: address(channelIndex: 2, interleavedChannelCount: 3),
                    output: address(channelIndex: 0, interleavedChannelCount: 4),
                    mixCoefficient: 1
                ),
                ProcessTapChannelMap(
                    input: address(channelIndex: 0, interleavedChannelCount: 3),
                    output: address(channelIndex: 3, interleavedChannelCount: 4),
                    mixCoefficient: 0.5
                ),
            ]
        )
        let context = ProcessTapDSPContext(configuration: configuration, initialGain: 1)
        context.setOutputGateOpen(true)

        storage.process(with: context)

        XCTAssertEqual(storage.outputSamples, [3, 0, 0, 0.5, 6, 0, 0, 2])
    }

    func testMultipleInputContributionsMixIntoOneOutputChannel() throws {
        let storage = AudioBufferListTestStorage.nonInterleaved(
            inputs: [[1, 3], [3, 1]],
            outputs: [[9, 9]]
        )
        let mono = audioFormat(channelCount: 1, interleaving: .nonInterleaved)
        let configuration = try ProcessTapDSPConfiguration.validated(
            sampleRate: 48_000,
            inputFormats: [mono, mono],
            outputFormats: [mono],
            channelMaps: [
                map(inputBuffer: 0, outputBuffer: 0, mixCoefficient: 0.25),
                map(inputBuffer: 1, outputBuffer: 0, mixCoefficient: 0.75),
            ]
        )
        let context = ProcessTapDSPContext(configuration: configuration, initialGain: 1)
        context.setOutputGateOpen(true)

        storage.process(with: context)

        XCTAssertEqual(storage.outputSamples, [2.5, 1.5])
    }

    func testMuteTargetsZeroWithoutLosingStoredVolume() {
        var state = ProcessGainState(volume: 0.6)

        state.isMuted = true
        XCTAssertEqual(state.targetGain, 0)
        XCTAssertEqual(state.volume, 0.6)

        state.setVolume(0.4)
        XCTAssertEqual(state.targetGain, 0)
        XCTAssertEqual(state.volume, 0.4)

        state.isMuted = false
        XCTAssertEqual(state.targetGain, 0.4, accuracy: 0.000_001)
    }

    func testGainStateClampsFiniteValuesAndDefaultsNonfiniteValues() {
        XCTAssertEqual(ProcessGainState(volume: -1).volume, 0)
        XCTAssertEqual(ProcessGainState(volume: 2).volume, 1)
        XCTAssertEqual(ProcessGainState(volume: .nan).volume, 1)

        var state = ProcessGainState(volume: 0.5)
        state.setVolume(.infinity)
        XCTAssertEqual(state.volume, 1)
    }

    func testConfigurationRejectsInvalidBufferChannelAndInterleavingIndices() {
        let stereo = audioFormat(channelCount: 2)
        let validOutput = address(channelIndex: 0, interleavedChannelCount: 2)
        let invalidAddresses = [
            ProcessTapChannelAddress(bufferIndex: -1, channelIndex: 0, interleavedChannelCount: 2),
            ProcessTapChannelAddress(bufferIndex: 1, channelIndex: 0, interleavedChannelCount: 2),
            ProcessTapChannelAddress(bufferIndex: 0, channelIndex: -1, interleavedChannelCount: 2),
            ProcessTapChannelAddress(bufferIndex: 0, channelIndex: 2, interleavedChannelCount: 2),
            ProcessTapChannelAddress(bufferIndex: 0, channelIndex: 0, interleavedChannelCount: 1),
        ]

        for invalidInput in invalidAddresses {
            XCTAssertThrowsError(try ProcessTapDSPConfiguration.validated(
                sampleRate: 48_000,
                inputFormats: [stereo],
                outputFormats: [stereo],
                channelMaps: [ProcessTapChannelMap(
                    input: invalidInput,
                    output: validOutput,
                    mixCoefficient: 1
                )]
            ))
        }

        XCTAssertThrowsError(try ProcessTapDSPConfiguration.validated(
            sampleRate: 48_000,
            inputFormats: [stereo],
            outputFormats: [stereo],
            channelMaps: [ProcessTapChannelMap(
                input: address(channelIndex: 0, interleavedChannelCount: 2),
                output: ProcessTapChannelAddress(
                    bufferIndex: 1,
                    channelIndex: 0,
                    interleavedChannelCount: 2
                ),
                mixCoefficient: 1
            )]
        ))
    }

    func testConfigurationRejectsZeroChannelsMixedSampleRatesAndNonFloat32() {
        let stereo = audioFormat(channelCount: 2)
        let zeroChannel = audioFormat(channelCount: 0)
        let differentRate = audioFormat(sampleRate: 44_100, channelCount: 2)
        let integerPCM = audioFormat(
            channelCount: 2,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        )
        let contradictoryFloatFlags = audioFormat(
            channelCount: 2,
            formatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
        )

        for invalidInput in [zeroChannel, differentRate, integerPCM, contradictoryFloatFlags] {
            XCTAssertThrowsError(try ProcessTapDSPConfiguration.validated(
                sampleRate: 48_000,
                inputFormats: [invalidInput],
                outputFormats: [stereo],
                channelMaps: [
                    map(inputChannel: 0, outputChannel: 0, interleavedChannelCount: 2),
                ]
            ))
        }
    }

    func testConfigurationRejectsUnsupportedLayoutSampleRateMapsAndCoefficients() {
        let stereo = audioFormat(channelCount: 2)
        let mismatchedLayout = audioFormat(
            channelCount: 2,
            interleaving: .nonInterleaved,
            formatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        )
        let validMap = map(inputChannel: 0, outputChannel: 0, interleavedChannelCount: 2)

        XCTAssertThrowsError(try ProcessTapDSPConfiguration.validated(
            sampleRate: .nan,
            inputFormats: [stereo],
            outputFormats: [stereo],
            channelMaps: [validMap]
        ))
        XCTAssertThrowsError(try ProcessTapDSPConfiguration.validated(
            sampleRate: 48_000,
            inputFormats: [mismatchedLayout],
            outputFormats: [stereo],
            channelMaps: [validMap]
        ))
        XCTAssertThrowsError(try ProcessTapDSPConfiguration.validated(
            sampleRate: 48_000,
            inputFormats: [stereo],
            outputFormats: [stereo],
            channelMaps: []
        ))
        XCTAssertThrowsError(try ProcessTapDSPConfiguration.validated(
            sampleRate: 48_000,
            inputFormats: [stereo],
            outputFormats: [stereo],
            channelMaps: [ProcessTapChannelMap(
                input: validMap.input,
                output: validMap.output,
                mixCoefficient: .nan
            )]
        ))
    }

    func testProcessingNeverMutatesInputOrOutputByteSizes() throws {
        let storage = AudioBufferListTestStorage(
            inputs: [[1, 2, 3, 4]],
            inputChannelCounts: [1],
            inputByteSizes: [UInt32(3 * MemoryLayout<Float32>.stride)],
            outputs: [[9, 9, 8, 8]],
            outputChannelCounts: [1],
            outputByteSizes: [UInt32(2 * MemoryLayout<Float32>.stride)]
        )
        let inputSizesBefore = storage.inputByteSizes
        let outputSizesBefore = storage.outputByteSizes
        let context = try makeInterleavedContext(
            channelCount: 1,
            maps: [map()],
            initialGain: 1
        )
        context.setOutputGateOpen(true)

        storage.process(with: context)

        XCTAssertEqual(storage.inputByteSizes, inputSizesBefore)
        XCTAssertEqual(storage.outputByteSizes, outputSizesBefore)
        XCTAssertEqual(storage.outputSamples, [1, 2, 8, 8])
    }

    func testCallbackObservationSharesGateStateWithoutChangingIt() throws {
        let context = try makeInterleavedContext(
            channelCount: 1,
            maps: [map()],
            initialGain: 1
        )
        XCTAssertFalse(context.hasObservedCallback)
        context.setOutputGateOpen(true)

        context.markCallbackObserved()

        XCTAssertTrue(context.hasObservedCallback)
        let storage = AudioBufferListTestStorage(
            inputs: [[1]],
            inputChannelCounts: [1],
            outputs: [[9]],
            outputChannelCounts: [1]
        )
        storage.process(with: context)
        XCTAssertEqual(storage.outputSamples, [1])
    }
}

private extension ProcessTapDSPTests {
    func audioFormat(
        sampleRate: Double = 48_000,
        channelCount: Int,
        interleaving: AudioPCMInterleaving = .interleaved,
        formatFlags: AudioFormatFlags? = nil
    ) -> ProcessTapAudioFormat {
        let defaultFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | (interleaving == .nonInterleaved ? kAudioFormatFlagIsNonInterleaved : 0)
        return ProcessTapAudioFormat(
            sampleRate: sampleRate,
            channelCount: channelCount,
            formatID: kAudioFormatLinearPCM,
            formatFlags: formatFlags ?? defaultFlags,
            bitsPerChannel: 32,
            interleaving: interleaving
        )
    }

    func address(
        bufferIndex: Int = 0,
        channelIndex: Int = 0,
        interleavedChannelCount: Int = 1
    ) -> ProcessTapChannelAddress {
        ProcessTapChannelAddress(
            bufferIndex: bufferIndex,
            channelIndex: channelIndex,
            interleavedChannelCount: interleavedChannelCount
        )
    }

    func map(
        inputBuffer: Int = 0,
        inputChannel: Int = 0,
        outputBuffer: Int = 0,
        outputChannel: Int = 0,
        interleavedChannelCount: Int = 1,
        mixCoefficient: Float32 = 1
    ) -> ProcessTapChannelMap {
        ProcessTapChannelMap(
            input: address(
                bufferIndex: inputBuffer,
                channelIndex: inputChannel,
                interleavedChannelCount: interleavedChannelCount
            ),
            output: address(
                bufferIndex: outputBuffer,
                channelIndex: outputChannel,
                interleavedChannelCount: interleavedChannelCount
            ),
            mixCoefficient: mixCoefficient
        )
    }

    func makeInterleavedContext(
        sampleRate: Double = 48_000,
        channelCount: Int,
        maps: [ProcessTapChannelMap],
        initialGain: Float32
    ) throws -> ProcessTapDSPContext {
        let format = audioFormat(sampleRate: sampleRate, channelCount: channelCount)
        let configuration = try ProcessTapDSPConfiguration.validated(
            sampleRate: sampleRate,
            inputFormats: [format],
            outputFormats: [format],
            channelMaps: maps
        )
        return ProcessTapDSPContext(configuration: configuration, initialGain: initialGain)
    }

    func makeMonoContext(
        outputBufferCount: Int,
        mappedOutputBuffer: Int = 0
    ) throws -> ProcessTapDSPContext {
        let mono = audioFormat(channelCount: 1)
        let configuration = try ProcessTapDSPConfiguration.validated(
            sampleRate: 48_000,
            inputFormats: [mono],
            outputFormats: Array(repeating: mono, count: outputBufferCount),
            channelMaps: [map(outputBuffer: mappedOutputBuffer)]
        )
        return ProcessTapDSPContext(configuration: configuration, initialGain: 1)
    }

    func processConstantOne(
        frameCount: Int,
        through context: ProcessTapDSPContext
    ) {
        let storage = AudioBufferListTestStorage(
            inputs: [Array(repeating: 1, count: frameCount)],
            inputChannelCounts: [1],
            outputs: [Array(repeating: 0, count: frameCount)],
            outputChannelCounts: [1]
        )
        storage.process(with: context)
    }
}
