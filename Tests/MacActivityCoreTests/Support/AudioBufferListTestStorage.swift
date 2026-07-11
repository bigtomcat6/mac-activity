import CoreAudio

@testable import MacActivityCore

final class AudioBufferListTestStorage {
    private let inputStorage: OwnedAudioBufferList
    private let outputStorage: OwnedAudioBufferList

    init(
        inputs: [[Float32]],
        inputChannelCounts: [UInt32],
        inputByteSizes: [UInt32]? = nil,
        outputs: [[Float32]],
        outputChannelCounts: [UInt32],
        outputByteSizes: [UInt32]? = nil
    ) {
        inputStorage = OwnedAudioBufferList(
            samples: inputs,
            channelCounts: inputChannelCounts,
            byteSizes: inputByteSizes
        )
        outputStorage = OwnedAudioBufferList(
            samples: outputs,
            channelCounts: outputChannelCounts,
            byteSizes: outputByteSizes
        )
    }

    static func interleavedStereo(
        input: [Float32],
        outputFrameCount: Int
    ) -> AudioBufferListTestStorage {
        AudioBufferListTestStorage(
            inputs: [input],
            inputChannelCounts: [2],
            outputs: [Array(repeating: 0, count: outputFrameCount * 2)],
            outputChannelCounts: [2]
        )
    }

    static func nonInterleaved(
        inputs: [[Float32]],
        outputs: [[Float32]]
    ) -> AudioBufferListTestStorage {
        AudioBufferListTestStorage(
            inputs: inputs,
            inputChannelCounts: Array(repeating: 1, count: inputs.count),
            outputs: outputs,
            outputChannelCounts: Array(repeating: 1, count: outputs.count)
        )
    }

    var inputByteSizes: [UInt32] {
        inputStorage.byteSizes
    }

    var outputByteSizes: [UInt32] {
        outputStorage.byteSizes
    }

    var outputBuffers: [[Float32]] {
        outputStorage.samples
    }

    var outputSamples: [Float32] {
        outputBuffers.flatMap { $0 }
    }

    func process(with context: ProcessTapDSPContext) {
        context.process(
            input: UnsafePointer(inputStorage.pointer),
            output: outputStorage.pointer
        )
    }

    func makeOutputDataUnavailable(at bufferIndex: Int) {
        outputStorage.makeDataUnavailable(at: bufferIndex)
    }
}

private final class OwnedAudioBufferList {
    let pointer: UnsafeMutablePointer<AudioBufferList>

    private let rawStorage: UnsafeMutableRawPointer
    private let samplePointers: [UnsafeMutablePointer<Float32>]
    private let allocationCounts: [Int]
    private let sampleCounts: [Int]

    init(
        samples: [[Float32]],
        channelCounts: [UInt32],
        byteSizes: [UInt32]?
    ) {
        precondition(samples.isEmpty == false)
        precondition(channelCounts.count == samples.count)
        precondition(byteSizes == nil || byteSizes?.count == samples.count)

        let additionalBufferCount = samples.count - 1
        let listByteCount = MemoryLayout<AudioBufferList>.size
            + additionalBufferCount * MemoryLayout<AudioBuffer>.stride
        rawStorage = UnsafeMutableRawPointer.allocate(
            byteCount: listByteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        pointer = rawStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
        pointer.initialize(to: AudioBufferList(
            mNumberBuffers: UInt32(samples.count),
            mBuffers: AudioBuffer(
                mNumberChannels: 0,
                mDataByteSize: 0,
                mData: nil
            )
        ))

        var ownedPointers: [UnsafeMutablePointer<Float32>] = []
        var ownedAllocationCounts: [Int] = []
        var ownedSampleCounts: [Int] = []
        ownedPointers.reserveCapacity(samples.count)
        ownedAllocationCounts.reserveCapacity(samples.count)
        ownedSampleCounts.reserveCapacity(samples.count)

        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        for index in samples.indices {
            let dataByteSize: UInt32
            if let byteSizes {
                dataByteSize = byteSizes[index]
            } else {
                precondition(
                    samples[index].count
                        <= Int(UInt32.max) / MemoryLayout<Float32>.stride
                )
                dataByteSize = UInt32(samples[index].count * MemoryLayout<Float32>.stride)
            }
            let advertisedByteCount = Int(dataByteSize)
            let fullAdvertisedSampleCount = advertisedByteCount / MemoryLayout<Float32>.stride
            let partialSampleCount = advertisedByteCount % MemoryLayout<Float32>.stride == 0 ? 0 : 1
            let advertisedAllocationCount = fullAdvertisedSampleCount + partialSampleCount
            let allocationCount = max(
                1,
                max(samples[index].count, advertisedAllocationCount)
            )
            let samplePointer = UnsafeMutablePointer<Float32>.allocate(capacity: allocationCount)
            samplePointer.initialize(repeating: 0, count: allocationCount)
            for sampleIndex in samples[index].indices {
                samplePointer[sampleIndex] = samples[index][sampleIndex]
            }

            ownedPointers.append(samplePointer)
            ownedAllocationCounts.append(allocationCount)
            ownedSampleCounts.append(max(samples[index].count, fullAdvertisedSampleCount))
            buffers[index] = AudioBuffer(
                mNumberChannels: channelCounts[index],
                mDataByteSize: dataByteSize,
                mData: UnsafeMutableRawPointer(samplePointer)
            )
        }

        samplePointers = ownedPointers
        allocationCounts = ownedAllocationCounts
        sampleCounts = ownedSampleCounts
    }

    deinit {
        for index in samplePointers.indices {
            samplePointers[index].deinitialize(count: allocationCounts[index])
            samplePointers[index].deallocate()
        }
        pointer.deinitialize(count: 1)
        rawStorage.deallocate()
    }

    var byteSizes: [UInt32] {
        UnsafeMutableAudioBufferListPointer(pointer).map(\.mDataByteSize)
    }

    var samples: [[Float32]] {
        samplePointers.indices.map { bufferIndex in
            (0..<sampleCounts[bufferIndex]).map { sampleIndex in
                samplePointers[bufferIndex][sampleIndex]
            }
        }
    }

    func makeDataUnavailable(at bufferIndex: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        var buffer = buffers[bufferIndex]
        buffer.mData = nil
        buffers[bufferIndex] = buffer
    }
}
