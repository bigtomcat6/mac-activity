import CoreAudio
import Foundation

struct AudioAggregateTopologySnapshot: Equatable, Sendable {
    let isAlive: Bool
    let inputStreamIDs: [AudioStreamID]
    let inputFormats: [ProcessTapAudioFormat]
    let outputStreamIDs: [AudioStreamID]
    let outputFormats: [ProcessTapAudioFormat]
    let tapUUIDs: [UUID]
    let activeSubTapIDs: [AudioObjectID]
}

enum AudioAggregateTopologyError: Error, Equatable, Sendable {
    case unsupportedTopology
}

struct AudioAggregateLayout: Equatable, Sendable {
    let inputFormats: [ProcessTapAudioFormat]
    let outputFormats: [ProcessTapAudioFormat]
    let channelMaps: [ProcessTapChannelMap]
    let inputStreamUsage: [UInt32]
}

struct AudioAggregatePlannedTopology: Equatable, Sendable {
    let outputChannelCounts: [UInt32]
    let outputStreamCount: Int
}

enum AudioAggregateTopologyResolver {
    static func checkedChannelTotal<S: Sequence>(
        _ formats: S
    ) throws -> Int where S.Element == ProcessTapAudioFormat {
        var total = 0
        for format in formats {
            guard (1...ProcessTapAudioFormat.maximumChannelCount).contains(
                format.channelCount
            ) else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            let result = total.addingReportingOverflow(format.channelCount)
            guard result.overflow == false,
                  result.partialValue <= ProcessTapAudioFormat.maximumChannelCount
            else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            total = result.partialValue
        }
        return total
    }

    static func checkedSum(_ values: [Int]) throws -> Int {
        var total = 0
        for value in values {
            guard value >= 0 else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            let result = total.addingReportingOverflow(value)
            guard result.overflow == false else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            total = result.partialValue
        }
        return total
    }

    static func plannedTopology(
        for plan: AudioRoutePlan
    ) throws -> AudioAggregatePlannedTopology {
        guard plan.tapSources.count == 1,
              plan.subdevices.isEmpty == false
        else {
            throw AudioAggregateTopologyError.unsupportedTopology
        }

        var outputChannelCounts: [UInt32] = []
        var totalOutputChannels = 0
        outputChannelCounts.reserveCapacity(plan.subdevices.count)
        for subdevice in plan.subdevices {
            guard subdevice.outputStreams.isEmpty == false
            else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            let channelCount = try checkedChannelTotal(
                subdevice.outputStreams.lazy.map(\.format)
            )
            let totalResult = totalOutputChannels.addingReportingOverflow(channelCount)
            guard totalResult.overflow == false,
                  totalResult.partialValue <= ProcessTapAudioFormat.maximumChannelCount
            else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            totalOutputChannels = totalResult.partialValue
            guard let encodedChannelCount = UInt32(exactly: channelCount) else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            outputChannelCounts.append(encodedChannelCount)
        }

        let outputStreamCount = try checkedSum(
            plan.subdevices.map { $0.outputStreams.count }
        )
        guard outputStreamCount > 0 else {
            throw AudioAggregateTopologyError.unsupportedTopology
        }
        return AudioAggregatePlannedTopology(
            outputChannelCounts: outputChannelCounts,
            outputStreamCount: outputStreamCount
        )
    }

    static func resolve(
        plan: AudioRoutePlan,
        tap: AudioTapResource,
        snapshot: AudioAggregateTopologySnapshot
    ) throws -> AudioAggregateLayout {
        guard snapshot.isAlive,
              plan.tapSources.count == 1,
              plan.tapSources[0] == tap.source,
              snapshot.inputStreamIDs.count == 1,
              snapshot.inputStreamIDs[0] != kAudioObjectUnknown,
              snapshot.inputFormats == [tap.source.expectedFormat],
              ProcessTapDSPConfiguration.supports(
                  snapshot.inputFormats[0],
                  sampleRate: tap.source.expectedFormat.sampleRate
              ),
              snapshot.tapUUIDs == [tap.uuid],
              snapshot.activeSubTapIDs.count == 1,
              snapshot.activeSubTapIDs[0] != kAudioObjectUnknown
        else {
            throw AudioAggregateTopologyError.unsupportedTopology
        }

        let plannedTopology = try plannedTopology(for: plan)
        let plannedOutputCount = plannedTopology.outputStreamCount
        guard snapshot.outputStreamIDs.count == plannedOutputCount,
              snapshot.outputFormats.count == plannedOutputCount,
              snapshot.outputStreamIDs.allSatisfy({ $0 != kAudioObjectUnknown }),
              Set(snapshot.outputStreamIDs).count == snapshot.outputStreamIDs.count,
              snapshot.outputStreamIDs.contains(snapshot.inputStreamIDs[0]) == false,
              snapshot.outputFormats.allSatisfy({
                  ProcessTapDSPConfiguration.supports(
                      $0,
                      sampleRate: tap.source.expectedFormat.sampleRate
                  )
              })
        else {
            throw AudioAggregateTopologyError.unsupportedTopology
        }

        _ = try checkedChannelTotal(snapshot.inputFormats)
        _ = try checkedChannelTotal(snapshot.outputFormats)

        let inputLayout = expandABLFormats(
            snapshot.inputFormats,
            startingBufferIndex: 0
        )
        var outputFormats: [ProcessTapAudioFormat] = []
        var channelMaps: [ProcessTapChannelMap] = []
        var outputStreamIndex = 0
        var outputBufferIndex = 0

        for subdevice in plan.subdevices {
            let streamCount = subdevice.outputStreams.count
            let endIndex = outputStreamIndex + streamCount
            guard endIndex <= snapshot.outputFormats.count else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            let actualGroupFormats = Array(
                snapshot.outputFormats[outputStreamIndex..<endIndex]
            )
            for actualFormat in actualGroupFormats {
                let targetLayout = expandABLFormats(
                    [actualFormat],
                    startingBufferIndex: outputBufferIndex
                )
                outputFormats.append(contentsOf: targetLayout.formats)
                channelMaps.append(contentsOf: makeChannelMaps(
                    from: inputLayout.channels,
                    to: targetLayout.channels
                ))
                outputBufferIndex = targetLayout.nextBufferIndex
            }
            outputStreamIndex = endIndex
        }

        guard outputStreamIndex == snapshot.outputFormats.count else {
            throw AudioAggregateTopologyError.unsupportedTopology
        }
        return AudioAggregateLayout(
            inputFormats: inputLayout.formats,
            outputFormats: outputFormats,
            channelMaps: channelMaps,
            inputStreamUsage: [1]
        )
    }

    private static func expandABLFormats(
        _ formats: [ProcessTapAudioFormat],
        startingBufferIndex: Int
    ) -> (
        formats: [ProcessTapAudioFormat],
        channels: [ProcessTapChannelAddress],
        nextBufferIndex: Int
    ) {
        var expandedFormats: [ProcessTapAudioFormat] = []
        var channels: [ProcessTapChannelAddress] = []
        var bufferIndex = startingBufferIndex

        for format in formats where format.channelCount > 0 {
            switch format.interleaving {
            case .interleaved:
                expandedFormats.append(format)
                for channelIndex in 0..<format.channelCount {
                    channels.append(ProcessTapChannelAddress(
                        bufferIndex: bufferIndex,
                        channelIndex: channelIndex,
                        interleavedChannelCount: format.channelCount
                    ))
                }
                bufferIndex += 1
            case .nonInterleaved:
                let bufferFormat = ProcessTapAudioFormat(
                    sampleRate: format.sampleRate,
                    channelCount: 1,
                    formatID: format.formatID,
                    formatFlags: format.formatFlags,
                    bitsPerChannel: format.bitsPerChannel,
                    interleaving: .nonInterleaved
                )
                for _ in 0..<format.channelCount {
                    expandedFormats.append(bufferFormat)
                    channels.append(ProcessTapChannelAddress(
                        bufferIndex: bufferIndex,
                        channelIndex: 0,
                        interleavedChannelCount: 1
                    ))
                    bufferIndex += 1
                }
            }
        }
        return (expandedFormats, channels, bufferIndex)
    }

    private static func makeChannelMaps(
        from sourceChannels: [ProcessTapChannelAddress],
        to targetChannels: [ProcessTapChannelAddress]
    ) -> [ProcessTapChannelMap] {
        guard sourceChannels.isEmpty == false,
              targetChannels.isEmpty == false
        else {
            return []
        }

        if sourceChannels.count == 1 {
            return targetChannels.map {
                ProcessTapChannelMap(
                    input: sourceChannels[0],
                    output: $0,
                    mixCoefficient: 1
                )
            }
        }
        if targetChannels.count == 1 {
            let coefficient = Float32(1) / Float32(sourceChannels.count)
            return sourceChannels.map {
                ProcessTapChannelMap(
                    input: $0,
                    output: targetChannels[0],
                    mixCoefficient: coefficient
                )
            }
        }
        return zip(sourceChannels, targetChannels).map {
            ProcessTapChannelMap(
                input: $0.0,
                output: $0.1,
                mixCoefficient: 1
            )
        }
    }
}
