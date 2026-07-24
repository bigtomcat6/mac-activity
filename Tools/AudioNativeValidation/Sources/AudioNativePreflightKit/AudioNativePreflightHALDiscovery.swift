import CoreAudio
import Foundation

struct AudioNativePreflightOutputDevice: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let outputStreamIDs: [AudioStreamID]
}

enum AudioNativePreflightHALDiscoveryError: LocalizedError, Equatable, Sendable {
    case hardwareInventoryUnavailable
    case missingRequiredProperty(String)
    case malformedRequiredProperty(String)

    var errorDescription: String? {
        switch self {
        case .hardwareInventoryUnavailable:
            return "Global HAL physical hardware device inventory is unavailable"
        case .missingRequiredProperty(let name):
            return "Required HAL property '\(name)' is unavailable"
        case .malformedRequiredProperty(let name):
            return "Required HAL property '\(name)' returned malformed data"
        }
    }
}

enum AudioNativePreflightHALDiscovery {
    static func requireHardwareDeviceInventory(
        _ deviceIDs: [AudioDeviceID]
    ) throws -> [AudioDeviceID] {
        guard !deviceIDs.isEmpty else {
            throw AudioNativePreflightHALDiscoveryError.hardwareInventoryUnavailable
        }
        return deviceIDs
    }

    static func aggregateTapUUIDs(
        isAvailableOnPlatform: Bool,
        read: () throws -> [String]
    ) rethrows -> [String] {
        guard isAvailableOnPlatform else { return [] }
        return try read()
    }

    static func outputDevices(
        deviceIDs: [AudioDeviceID],
        outputStreams: (AudioDeviceID) throws -> [AudioStreamID]
    ) rethrows -> [AudioNativePreflightOutputDevice] {
        try deviceIDs.compactMap { deviceID in
            let streamIDs = try outputStreams(deviceID)
            guard !streamIDs.isEmpty else { return nil }
            return AudioNativePreflightOutputDevice(
                deviceID: deviceID,
                outputStreamIDs: streamIDs
            )
        }
    }

    static func optionalProperty<Value>(
        isPresent: Bool,
        read: () throws -> Value
    ) rethrows -> Value? {
        guard isPresent else { return nil }
        return try read()
    }

    static func requiredProperty<Value>(
        isPresent: Bool,
        name: String,
        read: () throws -> Value
    ) throws -> Value {
        guard isPresent else {
            throw AudioNativePreflightHALDiscoveryError.missingRequiredProperty(name)
        }
        return try read()
    }
}
