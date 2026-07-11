import CoreAudio
import Foundation

public enum AudioRouteMode: Equatable, Sendable {
    case followOriginal
    case explicit(targetDeviceUIDs: [String])
}

extension AudioRouteMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case targetDeviceUIDs
    }

    private enum Kind: String, Codable {
        case followOriginal
        case explicit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .followOriginal:
            self = .followOriginal
        case .explicit:
            let targets = try container.decode([String].self, forKey: .targetDeviceUIDs)
            let normalized = targets.reduce(into: [String]()) { result, uid in
                if uid.isEmpty == false && result.contains(uid) == false {
                    result.append(uid)
                }
            }
            guard normalized.isEmpty == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .targetDeviceUIDs,
                    in: container,
                    debugDescription: "An explicit route requires at least one UID"
                )
            }
            self = .explicit(targetDeviceUIDs: normalized)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .followOriginal:
            try container.encode(Kind.followOriginal, forKey: .kind)
        case .explicit(let targetDeviceUIDs):
            try container.encode(Kind.explicit, forKey: .kind)
            try container.encode(targetDeviceUIDs, forKey: .targetDeviceUIDs)
        }
    }
}

public enum AudioPCMInterleaving: Equatable, Sendable {
    case interleaved
    case nonInterleaved
}

public struct ProcessTapAudioFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let formatID: AudioFormatID
    public let formatFlags: AudioFormatFlags
    public let bitsPerChannel: UInt32
    public let interleaving: AudioPCMInterleaving

    public init(
        sampleRate: Double,
        channelCount: Int,
        formatID: AudioFormatID,
        formatFlags: AudioFormatFlags,
        bitsPerChannel: UInt32,
        interleaving: AudioPCMInterleaving
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bitsPerChannel = bitsPerChannel
        self.interleaving = interleaving
    }

    public var isSupportedFloat32LinearPCM: Bool {
        formatID == kAudioFormatLinearPCM
            && formatFlags & kAudioFormatFlagIsFloat != 0
            && bitsPerChannel == 32
            && sampleRate.isFinite
            && sampleRate > 0
            && channelCount > 0
    }
}

public struct AudioRouteStream: Equatable, Sendable {
    public let streamIndex: UInt
    public let format: ProcessTapAudioFormat

    public init(streamIndex: UInt, format: ProcessTapAudioFormat) {
        self.streamIndex = streamIndex
        self.format = format
    }
}

public struct AudioRouteDevice: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let uid: String
    public let name: String
    public let isAlive: Bool
    public let isAggregate: Bool
    public let aggregateSubdeviceUIDs: [String]
    public let outputStreams: [AudioRouteStream]

    public init(
        objectID: AudioObjectID,
        uid: String,
        name: String,
        isAlive: Bool,
        isAggregate: Bool,
        aggregateSubdeviceUIDs: [String],
        outputStreams: [AudioRouteStream]
    ) {
        self.objectID = objectID
        self.uid = uid
        self.name = name
        self.isAlive = isAlive
        self.isAggregate = isAggregate
        self.aggregateSubdeviceUIDs = aggregateSubdeviceUIDs
        self.outputStreams = outputStreams
    }
}

public struct AudioRouteRequest: Equatable, Sendable {
    public let processObjectID: AudioObjectID
    public let generation: UInt64
    public let sourceDeviceUIDs: [String]
    public let systemDefaultOutputDeviceUID: String?
    public let mode: AudioRouteMode
    public let devices: [AudioRouteDevice]

    public init(
        processObjectID: AudioObjectID,
        generation: UInt64,
        sourceDeviceUIDs: [String],
        systemDefaultOutputDeviceUID: String?,
        mode: AudioRouteMode,
        devices: [AudioRouteDevice]
    ) {
        self.processObjectID = processObjectID
        self.generation = generation
        self.sourceDeviceUIDs = sourceDeviceUIDs
        self.systemDefaultOutputDeviceUID = systemDefaultOutputDeviceUID
        self.mode = mode
        self.devices = devices
    }
}

public struct AudioTapSource: Equatable, Sendable {
    public let deviceUID: String
    public let streamIndex: UInt
    public let expectedFormat: ProcessTapAudioFormat

    public init(
        deviceUID: String,
        streamIndex: UInt,
        expectedFormat: ProcessTapAudioFormat
    ) {
        self.deviceUID = deviceUID
        self.streamIndex = streamIndex
        self.expectedFormat = expectedFormat
    }
}

public struct AudioRouteSubdevice: Equatable, Sendable {
    public let uid: String
    public let usesDriftCompensation: Bool
    public let outputStreams: [AudioRouteStream]

    public init(
        uid: String,
        usesDriftCompensation: Bool,
        outputStreams: [AudioRouteStream]
    ) {
        self.uid = uid
        self.usesDriftCompensation = usesDriftCompensation
        self.outputStreams = outputStreams
    }
}

public struct AudioRoutePlan: Equatable, Sendable {
    public let processObjectID: AudioObjectID
    public let generation: UInt64
    public let tapSources: [AudioTapSource]
    public let selectedTargetUIDs: [String]
    public let subdevices: [AudioRouteSubdevice]
    public let mainDeviceUID: String
    public let isStacked: Bool
    public let aggregateUID: String

    public init(
        processObjectID: AudioObjectID,
        generation: UInt64,
        tapSources: [AudioTapSource],
        selectedTargetUIDs: [String],
        subdevices: [AudioRouteSubdevice],
        mainDeviceUID: String,
        isStacked: Bool,
        aggregateUID: String
    ) {
        self.processObjectID = processObjectID
        self.generation = generation
        self.tapSources = tapSources
        self.selectedTargetUIDs = selectedTargetUIDs
        self.subdevices = subdevices
        self.mainDeviceUID = mainDeviceUID
        self.isStacked = isStacked
        self.aggregateUID = aggregateUID
    }
}

public enum AudioRoutePlanningError: Error, Equatable, Sendable {
    case noSourceRoute
    case emptyExplicitTargets
    case missingDevice(String)
    case unavailableDevice(String)
    case recursiveAggregate(String)
    case macActivityAggregateSelected(String)
    case unsupportedFormat(deviceUID: String, streamIndex: UInt)
    case incompatibleTarget(deviceUID: String)
}

@MainActor
public protocol AudioRouteDeviceProviding: AnyObject {
    func routeDevices() throws -> [AudioRouteDevice]
}
