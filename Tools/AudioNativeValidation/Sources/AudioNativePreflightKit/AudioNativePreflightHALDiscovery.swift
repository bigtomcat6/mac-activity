import CoreAudio

struct AudioNativePreflightOutputDevice: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let outputStreamIDs: [AudioStreamID]
}

enum AudioNativePreflightHALDiscoveryError: Error, Equatable, Sendable {
    case missingRequiredProperty(String)
    case malformedRequiredProperty(String)
}

enum AudioNativePreflightHALDiscovery {
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
