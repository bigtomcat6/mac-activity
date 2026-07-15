import CoreAudio
import Foundation
import MacActivityCore

public struct AudioNativePreflightStreamFormat: Codable, Equatable, Sendable {
    public let sampleRate: Double
    public let formatID: AudioFormatID
    public let formatFlags: AudioFormatFlags
    public let bytesPerPacket: UInt32
    public let framesPerPacket: UInt32
    public let bytesPerFrame: UInt32
    public let channelsPerFrame: UInt32
    public let bitsPerChannel: UInt32
    public let reserved: UInt32

    public init(
        sampleRate: Double,
        formatID: AudioFormatID,
        formatFlags: AudioFormatFlags,
        bytesPerPacket: UInt32,
        framesPerPacket: UInt32,
        bytesPerFrame: UInt32,
        channelsPerFrame: UInt32,
        bitsPerChannel: UInt32,
        reserved: UInt32
    ) {
        self.sampleRate = sampleRate
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.bytesPerPacket = bytesPerPacket
        self.framesPerPacket = framesPerPacket
        self.bytesPerFrame = bytesPerFrame
        self.channelsPerFrame = channelsPerFrame
        self.bitsPerChannel = bitsPerChannel
        self.reserved = reserved
    }

    init(_ format: AudioStreamBasicDescription) {
        self.init(
            sampleRate: format.mSampleRate,
            formatID: format.mFormatID,
            formatFlags: format.mFormatFlags,
            bytesPerPacket: format.mBytesPerPacket,
            framesPerPacket: format.mFramesPerPacket,
            bytesPerFrame: format.mBytesPerFrame,
            channelsPerFrame: format.mChannelsPerFrame,
            bitsPerChannel: format.mBitsPerChannel,
            reserved: format.mReserved
        )
    }
}

public struct AudioNativePreflightStreamObservation: Equatable, Sendable {
    public let diagnosticObjectID: AudioStreamID
    public let index: UInt
    public let format: AudioNativePreflightStreamFormat

    public init(
        diagnosticObjectID: AudioStreamID,
        index: UInt,
        format: AudioNativePreflightStreamFormat
    ) {
        self.diagnosticObjectID = diagnosticObjectID
        self.index = index
        self.format = format
    }
}

public enum AudioNativePreflightPropertyObservation<Value: Equatable & Sendable>:
    Equatable,
    Sendable {
    case value(Value, isWritable: Bool)
    case notObserved
    case unsupported
    case unavailable
    case failed(String)
}

public struct AudioNativePreflightControlInspectionPolicy: Sendable {
    public let includeDeviceControls: Bool

    public init(includeDeviceControls: Bool = false) {
        self.includeDeviceControls = includeDeviceControls
    }

    public func observations(
        volume: () -> AudioNativePreflightPropertyObservation<Double>,
        mute: () -> AudioNativePreflightPropertyObservation<Bool>
    ) -> (
        volume: AudioNativePreflightPropertyObservation<Double>,
        mute: AudioNativePreflightPropertyObservation<Bool>
    ) {
        guard includeDeviceControls else {
            return (.notObserved, .notObserved)
        }
        return (volume(), mute())
    }
}

public enum AudioNativePreflightObservationError: Error, Equatable, Sendable {
    case deviceChanged(
        uid: String,
        routeObjectID: AudioDeviceID,
        controlObjectID: AudioDeviceID
    )
}

public struct AudioNativePreflightDeviceObservation: Equatable, Sendable {
    public let diagnosticObjectID: AudioDeviceID
    public let uid: String
    public let name: String
    public let alive: Bool
    public let isAggregate: Bool
    public let aggregateComposition: AudioRouteAggregateComposition?
    public let modelUID: String?
    public let driverIdentity: AudioRouteDriverIdentity?
    public let transportType: UInt32?
    public let clockDomain: UInt32?
    public let inputStreams: [AudioNativePreflightStreamObservation]
    public let outputStreams: [AudioNativePreflightStreamObservation]
    public let volume: AudioNativePreflightPropertyObservation<Double>
    public let mute: AudioNativePreflightPropertyObservation<Bool>

    public init(
        diagnosticObjectID: AudioDeviceID,
        uid: String,
        name: String,
        alive: Bool,
        isAggregate: Bool,
        aggregateComposition: AudioRouteAggregateComposition?,
        modelUID: String?,
        driverIdentity: AudioRouteDriverIdentity?,
        transportType: UInt32?,
        clockDomain: UInt32?,
        inputStreams: [AudioNativePreflightStreamObservation],
        outputStreams: [AudioNativePreflightStreamObservation],
        volume: AudioNativePreflightPropertyObservation<Double>,
        mute: AudioNativePreflightPropertyObservation<Bool>
    ) {
        self.diagnosticObjectID = diagnosticObjectID
        self.uid = uid
        self.name = name
        self.alive = alive
        self.isAggregate = isAggregate
        self.aggregateComposition = aggregateComposition
        self.modelUID = modelUID
        self.driverIdentity = driverIdentity
        self.transportType = transportType
        self.clockDomain = clockDomain
        self.inputStreams = inputStreams
        self.outputStreams = outputStreams
        self.volume = volume
        self.mute = mute
    }

    public init(
        routeDevice: AudioRouteDevice,
        controlSnapshot: AudioOutputDeviceSnapshot,
        exactFormat: (AudioStreamID) throws -> AudioStreamBasicDescription
    ) throws {
        guard controlSnapshot.id == routeDevice.uid,
              controlSnapshot.objectID == routeDevice.objectID else {
            throw AudioNativePreflightObservationError.deviceChanged(
                uid: routeDevice.uid,
                routeObjectID: routeDevice.objectID,
                controlObjectID: controlSnapshot.objectID
            )
        }
        self.init(
            diagnosticObjectID: routeDevice.objectID,
            uid: routeDevice.uid,
            name: routeDevice.name,
            alive: routeDevice.isAlive,
            isAggregate: routeDevice.isAggregate,
            aggregateComposition: routeDevice.aggregateComposition,
            modelUID: routeDevice.modelUID,
            driverIdentity: routeDevice.driverIdentity,
            transportType: routeDevice.transportType,
            clockDomain: routeDevice.clockDomain,
            inputStreams: try routeDevice.inputStreams.map {
                try AudioNativePreflightStreamObservation(
                    diagnosticObjectID: $0.streamObjectID,
                    index: $0.streamIndex,
                    format: AudioNativePreflightStreamFormat(exactFormat($0.streamObjectID))
                )
            },
            outputStreams: try routeDevice.outputStreams.map {
                try AudioNativePreflightStreamObservation(
                    diagnosticObjectID: $0.streamObjectID,
                    index: $0.streamIndex,
                    format: AudioNativePreflightStreamFormat(exactFormat($0.streamObjectID))
                )
            },
            volume: AudioNativePreflightPropertyObservation(controlSnapshot.volume),
            mute: AudioNativePreflightPropertyObservation(controlSnapshot.mute)
        )
    }
}

public struct AudioNativePreflightProcessObservation: Equatable, Sendable {
    public let diagnosticProcessObjectID: AudioObjectID
    public let pid: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let outputDeviceIDs: [AudioDeviceID]

    public init(
        diagnosticProcessObjectID: AudioObjectID,
        pid: pid_t,
        name: String,
        bundleIdentifier: String?,
        outputDeviceIDs: [AudioDeviceID]
    ) {
        self.diagnosticProcessObjectID = diagnosticProcessObjectID
        self.pid = pid
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.outputDeviceIDs = outputDeviceIDs
    }
}

public struct AudioNativePreflightReport: Encodable, Sendable {
    public let schemaVersion: Int
    public let operatingSystem: OperatingSystem
    public let processDiscoveryAvailable: Bool
    public let devices: [Device]
    public let processes: [Process]

    public struct OperatingSystem: Encodable, Sendable {
        public let version: String
        public let build: String
    }

    public struct Device: Encodable, Sendable {
        public let diagnosticObjectID: AudioDeviceID
        public let uid: String
        public let name: String
        public let alive: Bool
        public let isAggregate: Bool
        public let aggregateComposition: AudioRouteAggregateComposition?
        public let modelUID: String?
        public let driverIdentity: AudioRouteDriverIdentity?
        public let transportType: UInt32?
        public let clockDomain: UInt32?
        public let inputStreams: [Stream]
        public let outputStreams: [Stream]
        public let volume: Property<Double>
        public let mute: Property<Bool>

        private enum CodingKeys: String, CodingKey {
            case diagnosticObjectID
            case uid
            case name
            case alive
            case isAggregate
            case aggregateComposition
            case modelUID
            case driverIdentity
            case transportType
            case clockDomain
            case inputStreams
            case outputStreams
            case volume
            case mute
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(diagnosticObjectID, forKey: .diagnosticObjectID)
            try container.encode(uid, forKey: .uid)
            try container.encode(name, forKey: .name)
            try container.encode(alive, forKey: .alive)
            try container.encode(isAggregate, forKey: .isAggregate)
            try container.encodeOptional(aggregateComposition, forKey: .aggregateComposition)
            try container.encodeOptional(modelUID, forKey: .modelUID)
            try container.encodeOptional(driverIdentity, forKey: .driverIdentity)
            try container.encodeOptional(transportType, forKey: .transportType)
            try container.encodeOptional(clockDomain, forKey: .clockDomain)
            try container.encode(inputStreams, forKey: .inputStreams)
            try container.encode(outputStreams, forKey: .outputStreams)
            try container.encode(volume, forKey: .volume)
            try container.encode(mute, forKey: .mute)
        }
    }

    public struct Stream: Encodable, Sendable {
        public let diagnosticObjectID: AudioStreamID
        public let index: UInt
        public let format: AudioNativePreflightStreamFormat
    }

    public struct Property<Value: Encodable & Equatable & Sendable>: Encodable, Sendable {
        public let status: String
        public let value: Value?
        public let isWritable: Bool?
        public let failure: String?

        private enum CodingKeys: String, CodingKey {
            case status
            case value
            case isWritable
            case failure
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(status, forKey: .status)
            guard status != "notObserved" else { return }
            try container.encodeOptional(value, forKey: .value)
            try container.encodeOptional(isWritable, forKey: .isWritable)
            try container.encodeOptional(failure, forKey: .failure)
        }
    }

    public struct Process: Encodable, Sendable {
        public let diagnosticProcessObjectID: AudioObjectID
        public let pid: pid_t
        public let name: String
        public let bundleIdentifier: String?
        public let outputDeviceIDs: [AudioDeviceID]
        public let outputDeviceUIDs: [String]
        public let unmappedOutputDeviceIDs: [AudioDeviceID]
    }

    public static func make(
        schemaVersion: Int,
        operatingSystemVersion: String,
        osBuild: String,
        processDiscoveryAvailable: Bool,
        devices observations: [AudioNativePreflightDeviceObservation],
        processes processObservations: [AudioNativePreflightProcessObservation]
    ) -> Self {
        let devices = observations
            .sorted {
                ($0.uid, $0.diagnosticObjectID) < ($1.uid, $1.diagnosticObjectID)
            }
            .map(Device.init)
        let deviceUIDByObjectID = observations.reduce(into: [AudioDeviceID: String]()) {
            $0[$1.diagnosticObjectID] = $1.uid
        }
        let processes = processObservations
            .sorted { $0.diagnosticProcessObjectID < $1.diagnosticProcessObjectID }
            .map {
                Process(
                    diagnosticProcessObjectID: $0.diagnosticProcessObjectID,
                    pid: $0.pid,
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    outputDeviceIDs: $0.outputDeviceIDs,
                    outputDeviceUIDs: $0.outputDeviceIDs.compactMap {
                        deviceUIDByObjectID[$0]
                    },
                    unmappedOutputDeviceIDs: $0.outputDeviceIDs.filter {
                        deviceUIDByObjectID[$0] == nil
                    }
                )
            }
        return Self(
            schemaVersion: schemaVersion,
            operatingSystem: OperatingSystem(
                version: operatingSystemVersion,
                build: osBuild
            ),
            processDiscoveryAvailable: processDiscoveryAvailable,
            devices: devices,
            processes: processes
        )
    }
}

enum AudioNativePreflightProcessDiscovery {
    static func observations(
        processObjectIDs: [AudioObjectID],
        apps: [AudioProcessAppSnapshot],
        snapshot: (AudioObjectID) throws -> AudioProcessSnapshot
    ) rethrows -> [AudioNativePreflightProcessObservation] {
        let snapshots = try processObjectIDs.map(snapshot)
        return AudioProcessService.makeEntries(
            processObjects: snapshots,
            apps: apps
        ).map {
            AudioNativePreflightProcessObservation(
                diagnosticProcessObjectID: $0.processObjectID,
                pid: $0.processIdentifier,
                name: $0.name,
                bundleIdentifier: $0.bundleIdentifier,
                outputDeviceIDs: $0.outputDeviceIDs
            )
        }
    }
}

public enum AudioNativePreflightJSON {
    public static func encode(_ report: AudioNativePreflightReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report)
        data.append(0x0A)
        return data
    }
}

private extension AudioNativePreflightReport.Device {
    init(_ observation: AudioNativePreflightDeviceObservation) {
        self.init(
            diagnosticObjectID: observation.diagnosticObjectID,
            uid: observation.uid,
            name: observation.name,
            alive: observation.alive,
            isAggregate: observation.isAggregate,
            aggregateComposition: observation.aggregateComposition,
            modelUID: observation.modelUID,
            driverIdentity: observation.driverIdentity,
            transportType: observation.transportType,
            clockDomain: observation.clockDomain,
            inputStreams: observation.inputStreams
                .sorted { ($0.index, $0.diagnosticObjectID) < ($1.index, $1.diagnosticObjectID) }
                .map(AudioNativePreflightReport.Stream.init),
            outputStreams: observation.outputStreams
                .sorted { ($0.index, $0.diagnosticObjectID) < ($1.index, $1.diagnosticObjectID) }
                .map(AudioNativePreflightReport.Stream.init),
            volume: .init(observation: observation.volume),
            mute: .init(observation: observation.mute)
        )
    }
}

private extension AudioNativePreflightReport.Stream {
    init(_ observation: AudioNativePreflightStreamObservation) {
        self.init(
            diagnosticObjectID: observation.diagnosticObjectID,
            index: observation.index,
            format: observation.format
        )
    }
}

extension AudioNativePreflightReport.Property {
    init(observation: AudioNativePreflightPropertyObservation<Value>) {
        switch observation {
        case .value(let value, let isWritable):
            self.init(status: "value", value: value, isWritable: isWritable, failure: nil)
        case .notObserved:
            self.init(status: "notObserved", value: nil, isWritable: nil, failure: nil)
        case .unsupported:
            self.init(status: "unsupported", value: nil, isWritable: nil, failure: nil)
        case .unavailable:
            self.init(status: "unavailable", value: nil, isWritable: nil, failure: nil)
        case .failed(let failure):
            self.init(status: "failed", value: nil, isWritable: nil, failure: failure)
        }
    }
}

private extension AudioNativePreflightPropertyObservation {
    init(_ value: AudioPropertyValue<Value>) {
        switch value {
        case .value(let value, let isWritable):
            self = .value(value, isWritable: isWritable)
        case .unsupported:
            self = .unsupported
        case .unavailable:
            self = .unavailable
        case .failed(let error):
            self = .failed(Self.describe(error))
        }
    }

    static func describe(_ error: AudioHALError) -> String {
        let detail: String
        switch error.reason {
        case .status(let status):
            detail = "status \(status)"
        case .invalidDataSize(let byteCount, let elementStride):
            detail = "invalid data size \(byteCount) for stride \(elementStride)"
        case .retryLimitExceeded:
            detail = "retry limit exceeded"
        case .missingValue:
            detail = "missing value"
        case .processTapsUnavailable:
            detail = "process taps unavailable"
        }
        return "\(error.operation.rawValue) \(detail)"
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeOptional<T: Encodable>(
        _ value: T?,
        forKey key: Key
    ) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
