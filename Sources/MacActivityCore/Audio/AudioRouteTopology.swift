import Darwin
import Foundation

public struct AudioRouteTopologyFingerprint: Equatable, Hashable, Codable, Sendable {
    public let osBuild: String
    public let sourceDeviceUIDs: [String]
    public let selectedTargetUIDs: [String]
    public let devices: [AudioRouteDeviceFingerprint]

    public init(
        osBuild: String,
        sourceDeviceUIDs: [String],
        selectedTargetUIDs: [String],
        devices: [AudioRouteDeviceFingerprint]
    ) {
        self.osBuild = osBuild
        self.sourceDeviceUIDs = sourceDeviceUIDs
        self.selectedTargetUIDs = selectedTargetUIDs
        self.devices = devices
    }
}

public struct AudioRouteDeviceFingerprint: Equatable, Hashable, Codable, Sendable {
    public let uid: String
    public let modelUID: String?
    public let driverIdentity: AudioRouteDriverIdentity?
    public let inputStreams: [AudioRouteStream]
    public let outputStreams: [AudioRouteStream]
    public let fullSubdeviceUIDs: [String]
    public let activeSubdeviceUIDs: [String]
    public let aggregateMainSubdeviceUID: String?
    public let aggregateIsStacked: Bool?
    public let aggregateTapUUIDs: [String]
    public let clockDomain: UInt32?
    public let transportType: UInt32?
    public let isAlive: Bool

    public init(
        uid: String,
        modelUID: String?,
        driverIdentity: AudioRouteDriverIdentity?,
        inputStreams: [AudioRouteStream],
        outputStreams: [AudioRouteStream],
        fullSubdeviceUIDs: [String],
        activeSubdeviceUIDs: [String],
        aggregateMainSubdeviceUID: String?,
        aggregateIsStacked: Bool?,
        aggregateTapUUIDs: [String],
        clockDomain: UInt32?,
        transportType: UInt32?,
        isAlive: Bool
    ) {
        self.uid = uid
        self.modelUID = modelUID
        self.driverIdentity = driverIdentity
        self.inputStreams = inputStreams
        self.outputStreams = outputStreams
        self.fullSubdeviceUIDs = fullSubdeviceUIDs
        self.activeSubdeviceUIDs = activeSubdeviceUIDs
        self.aggregateMainSubdeviceUID = aggregateMainSubdeviceUID
        self.aggregateIsStacked = aggregateIsStacked
        self.aggregateTapUUIDs = aggregateTapUUIDs
        self.clockDomain = clockDomain
        self.transportType = transportType
        self.isAlive = isAlive
    }
}

enum AudioRouteOSBuild {
    enum ReadError: Error {
        case unavailable
    }

    static func current() throws -> String {
        var byteCount = 0
        guard sysctlbyname("kern.osversion", nil, &byteCount, nil, 0) == 0,
              byteCount > 1 else {
            throw ReadError.unavailable
        }

        var bytes = [CChar](repeating: 0, count: byteCount)
        guard sysctlbyname("kern.osversion", &bytes, &byteCount, nil, 0) == 0 else {
            throw ReadError.unavailable
        }
        if bytes.last == 0 {
            bytes.removeLast()
        }
        guard let value = String(
            bytes: bytes.map(UInt8.init(bitPattern:)),
            encoding: .utf8
        ), !value.isEmpty else {
            throw ReadError.unavailable
        }
        return value
    }
}
