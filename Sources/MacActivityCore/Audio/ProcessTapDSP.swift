import CoreAudio
import Darwin

public struct ProcessGainState: Equatable, Sendable {
    public private(set) var volume: Double
    public var isMuted: Bool

    public init(volume: Double = 1, isMuted: Bool = false) {
        self.volume = Self.clamped(volume)
        self.isMuted = isMuted
    }

    public var targetGain: Float32 {
        isMuted ? 0 : Float32(volume)
    }

    public mutating func setVolume(_ value: Double) {
        volume = Self.clamped(value)
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 1))
    }
}

struct ProcessTapChannelAddress: Equatable, Sendable {
    let bufferIndex: Int
    let channelIndex: Int
    let interleavedChannelCount: Int
}

struct ProcessTapChannelMap: Equatable, Sendable {
    let input: ProcessTapChannelAddress
    let output: ProcessTapChannelAddress
    let mixCoefficient: Float32
}

struct ProcessTapMappedOutputCapacity: Equatable, Sendable {
    let bufferIndex: Int
    let interleavedChannelCount: Int
}

struct ProcessTapDSPConfiguration: Equatable, Sendable {
    let sampleRate: Double
    let inputFormats: [ProcessTapAudioFormat]
    let outputFormats: [ProcessTapAudioFormat]
    let channelMaps: [ProcessTapChannelMap]
    let mappedOutputCapacities: [ProcessTapMappedOutputCapacity]

    private init(
        sampleRate: Double,
        inputFormats: [ProcessTapAudioFormat],
        outputFormats: [ProcessTapAudioFormat],
        channelMaps: [ProcessTapChannelMap],
        mappedOutputCapacities: [ProcessTapMappedOutputCapacity]
    ) {
        self.sampleRate = sampleRate
        self.inputFormats = inputFormats
        self.outputFormats = outputFormats
        self.channelMaps = channelMaps
        self.mappedOutputCapacities = mappedOutputCapacities
    }

    static func validated(
        sampleRate: Double,
        inputFormats: [ProcessTapAudioFormat],
        outputFormats: [ProcessTapAudioFormat],
        channelMaps: [ProcessTapChannelMap]
    ) throws -> Self {
        guard sampleRate.isFinite,
              sampleRate > 0,
              sampleRate * 0.030 <= Double(Int.max),
              inputFormats.isEmpty == false,
              outputFormats.isEmpty == false,
              channelMaps.isEmpty == false,
              inputFormats.allSatisfy({ isSupported($0, sampleRate: sampleRate) }),
              outputFormats.allSatisfy({ isSupported($0, sampleRate: sampleRate) })
        else {
            throw ProcessTapDSPValidationError.unsupportedConfiguration
        }

        var mappedOutputCapacities: [ProcessTapMappedOutputCapacity] = []
        mappedOutputCapacities.reserveCapacity(min(channelMaps.count, outputFormats.count))
        for map in channelMaps {
            guard map.mixCoefficient.isFinite,
                  isValid(map.input, in: inputFormats),
                  isValid(map.output, in: outputFormats)
            else {
                throw ProcessTapDSPValidationError.unsupportedConfiguration
            }

            if mappedOutputCapacities.contains(where: {
                $0.bufferIndex == map.output.bufferIndex
            }) == false {
                mappedOutputCapacities.append(ProcessTapMappedOutputCapacity(
                    bufferIndex: map.output.bufferIndex,
                    interleavedChannelCount: map.output.interleavedChannelCount
                ))
            }
        }

        return Self(
            sampleRate: sampleRate,
            inputFormats: inputFormats,
            outputFormats: outputFormats,
            channelMaps: channelMaps,
            mappedOutputCapacities: mappedOutputCapacities
        )
    }

    private static func isSupported(
        _ format: ProcessTapAudioFormat,
        sampleRate: Double
    ) -> Bool {
        let supportedFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved
        guard format.formatFlags & ~supportedFlags == 0 else { return false }

        let isFlaggedNonInterleaved = format.formatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let layoutMatches: Bool
        switch format.interleaving {
        case .interleaved:
            layoutMatches = isFlaggedNonInterleaved == false
        case .nonInterleaved:
            layoutMatches = isFlaggedNonInterleaved
        }

        return format.sampleRate == sampleRate
            && format.isSupportedFloat32LinearPCM
            && format.formatFlags & kAudioFormatFlagIsPacked != 0
            && layoutMatches
    }

    private static func isValid(
        _ address: ProcessTapChannelAddress,
        in formats: [ProcessTapAudioFormat]
    ) -> Bool {
        guard address.bufferIndex >= 0,
              address.bufferIndex < formats.count,
              address.channelIndex >= 0
        else {
            return false
        }

        let format = formats[address.bufferIndex]
        let expectedInterleavedChannelCount = format.interleaving == .interleaved
            ? format.channelCount
            : 1
        return address.interleavedChannelCount == expectedInterleavedChannelCount
            && address.channelIndex < expectedInterleavedChannelCount
    }
}

final class ProcessTapDSPContext: @unchecked Sendable {
    private static let gateOpenMask: Int32 = 1 << 0
    private static let callbackObservedMask: Int32 = 1 << 1

    private let configuration: ProcessTapDSPConfiguration
    private let targetGainBits: UnsafeMutablePointer<Int32>
    private let gateStateBits: UnsafeMutablePointer<Int32>

    // These values are owned by the single HAL callback invocation stream.
    private var currentGain: Float32
    private var lastTargetGain: Float32
    private var gainStep: Float32 = 0
    private var remainingRampFrames = 0

    init(configuration: ProcessTapDSPConfiguration, initialGain: Float32) {
        let gain = Self.clampedGain(initialGain)
        self.configuration = configuration
        currentGain = gain
        lastTargetGain = gain

        targetGainBits = .allocate(capacity: 1)
        targetGainBits.initialize(to: Int32(bitPattern: gain.bitPattern))
        gateStateBits = .allocate(capacity: 1)
        gateStateBits.initialize(to: 0)
    }

    deinit {
        targetGainBits.deinitialize(count: 1)
        targetGainBits.deallocate()
        gateStateBits.deinitialize(count: 1)
        gateStateBits.deallocate()
    }

    func setTargetGain(_ gain: Float32) {
        let newValue = Int32(bitPattern: Self.clampedGain(gain).bitPattern)
        var didSwap = false
        repeat {
            let currentValue = OSAtomicOr32Barrier(0, targetGainBits)
            didSwap = OSAtomicCompareAndSwap32Barrier(currentValue, newValue, targetGainBits)
        } while didSwap == false
    }

    func setOutputGateOpen(_ isOpen: Bool) {
        var didSwap = false
        repeat {
            let currentValue = OSAtomicOr32Barrier(0, gateStateBits)
            let newValue = isOpen
                ? currentValue | Self.gateOpenMask
                : currentValue & ~Self.gateOpenMask
            didSwap = OSAtomicCompareAndSwap32Barrier(currentValue, newValue, gateStateBits)
        } while didSwap == false
    }

    var hasObservedCallback: Bool {
        OSAtomicOr32Barrier(0, gateStateBits) & Self.callbackObservedMask != 0
    }

    func markCallbackObserved() {
        OSAtomicOr32Barrier(UInt32(bitPattern: Self.callbackObservedMask), gateStateBits)
    }

    var testingCurrentGain: Float32 {
        currentGain
    }

    func process(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(output)

        for index in outputBuffers.indices {
            guard let data = outputBuffers[index].mData else { continue }
            memset(data, 0, Int(outputBuffers[index].mDataByteSize))
        }
        guard atomicGateIsOpen() else { return }

        let target = atomicTargetGain()
        if target != lastTargetGain {
            lastTargetGain = target
            remainingRampFrames = max(1, Int(configuration.sampleRate * 0.030))
            gainStep = (target - currentGain) / Float32(remainingRampFrames)
        }

        let frameCount = maximumSafeOutputFrameCount(in: outputBuffers)
        for frame in 0..<frameCount {
            if remainingRampFrames > 0 {
                currentGain += gainStep
                remainingRampFrames -= 1
                if remainingRampFrames == 0 {
                    currentGain = lastTargetGain
                }
            }

            for map in configuration.channelMaps {
                guard let inputSample = sample(
                    atFrame: frame,
                    address: map.input,
                    buffers: inputBuffers
                ), let outputPointer = mutableSample(
                    atFrame: frame,
                    address: map.output,
                    buffers: outputBuffers
                ) else {
                    continue
                }
                outputPointer.pointee += inputSample * map.mixCoefficient * currentGain
            }
        }
    }

    @inline(__always)
    private static func clampedGain(_ gain: Float32) -> Float32 {
        min(1, max(0, gain.isFinite ? gain : 1))
    }

    @inline(__always)
    private func atomicGateIsOpen() -> Bool {
        OSAtomicOr32Barrier(0, gateStateBits) & Self.gateOpenMask != 0
    }

    @inline(__always)
    private func atomicTargetGain() -> Float32 {
        let bitPattern = OSAtomicOr32Barrier(0, targetGainBits)
        return Float32(bitPattern: UInt32(bitPattern: bitPattern))
    }

    @inline(__always)
    private func maximumSafeOutputFrameCount(
        in buffers: UnsafeMutableAudioBufferListPointer
    ) -> Int {
        var maximumFrameCount = 0
        for capacity in configuration.mappedOutputCapacities {
            guard capacity.bufferIndex < buffers.count else { continue }
            let buffer = buffers[capacity.bufferIndex]
            guard Int(buffer.mNumberChannels) == capacity.interleavedChannelCount,
                  let data = buffer.mData,
                  Int(bitPattern: data) % MemoryLayout<Float32>.alignment == 0
            else {
                continue
            }
            let frameCount = Int(buffer.mDataByteSize)
                / MemoryLayout<Float32>.stride
                / capacity.interleavedChannelCount
            if frameCount > maximumFrameCount {
                maximumFrameCount = frameCount
            }
        }
        return maximumFrameCount
    }

    @inline(__always)
    private func sample(
        atFrame frame: Int,
        address: ProcessTapChannelAddress,
        buffers: UnsafeMutableAudioBufferListPointer
    ) -> Float32? {
        guard address.bufferIndex < buffers.count else { return nil }
        let buffer = buffers[address.bufferIndex]
        guard Int(buffer.mNumberChannels) == address.interleavedChannelCount,
              let data = buffer.mData,
              Int(bitPattern: data) % MemoryLayout<Float32>.alignment == 0
        else {
            return nil
        }

        let frameCapacity = Int(buffer.mDataByteSize)
            / MemoryLayout<Float32>.stride
            / address.interleavedChannelCount
        guard frame < frameCapacity else { return nil }
        let sampleIndex = frame * address.interleavedChannelCount + address.channelIndex
        return data.assumingMemoryBound(to: Float32.self)[sampleIndex]
    }

    @inline(__always)
    private func mutableSample(
        atFrame frame: Int,
        address: ProcessTapChannelAddress,
        buffers: UnsafeMutableAudioBufferListPointer
    ) -> UnsafeMutablePointer<Float32>? {
        guard address.bufferIndex < buffers.count else { return nil }
        let buffer = buffers[address.bufferIndex]
        guard Int(buffer.mNumberChannels) == address.interleavedChannelCount,
              let data = buffer.mData,
              Int(bitPattern: data) % MemoryLayout<Float32>.alignment == 0
        else {
            return nil
        }

        let frameCapacity = Int(buffer.mDataByteSize)
            / MemoryLayout<Float32>.stride
            / address.interleavedChannelCount
        guard frame < frameCapacity else { return nil }
        let sampleIndex = frame * address.interleavedChannelCount + address.channelIndex
        return data.assumingMemoryBound(to: Float32.self).advanced(by: sampleIndex)
    }
}

private enum ProcessTapDSPValidationError: Error {
    case unsupportedConfiguration
}
