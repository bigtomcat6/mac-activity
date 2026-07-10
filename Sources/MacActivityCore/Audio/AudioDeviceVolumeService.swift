import AudioToolbox
import CoreAudio
import Foundation

public enum AudioControlAvailability: Equatable, Sendable {
    case writable
    case unsupported
}

public struct AudioOutputDeviceVolume: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let volume: Double
    public let isMuted: Bool
    public let volumeAvailability: AudioControlAvailability
    public let muteAvailability: AudioControlAvailability

    public init(
        id: String,
        name: String,
        volume: Double,
        isMuted: Bool,
        volumeAvailability: AudioControlAvailability,
        muteAvailability: AudioControlAvailability
    ) {
        self.id = id
        self.name = name
        self.volume = volume
        self.isMuted = isMuted
        self.volumeAvailability = volumeAvailability
        self.muteAvailability = muteAvailability
    }
}

@MainActor
public protocol AudioDeviceControlProviding: AnyObject {
    func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot]
    func outputDeviceSnapshot(forUID uid: String) throws -> AudioOutputDeviceSnapshot
    func writeVolume(_ volume: Double, forUID uid: String) throws -> Double
    func writeMute(_ isMuted: Bool, forUID uid: String) throws -> Bool
}

@MainActor
public protocol AudioDeviceVolumeProviding: AnyObject {
    func outputDevices() -> [AudioOutputDeviceVolume]
    func setVolume(_ volume: Double, for id: AudioOutputDeviceVolume.ID) -> Bool
    func setMuted(_ isMuted: Bool, for id: AudioOutputDeviceVolume.ID) -> Bool
}

@MainActor
public final class AudioDeviceVolumeService:
    AudioDeviceControlProviding,
    AudioDeviceVolumeProviding {
    private static let internalDeviceUIDPrefix = "com.how.macactivity.audio."

    private let client: AudioHALClient

    public convenience init() {
        self.init(client: .system)
    }

    init(client: AudioHALClient) {
        self.client = client
    }

    public func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot] {
        var snapshots: [AudioOutputDeviceSnapshot] = []
        for deviceID in try outputDeviceIDs() {
            let uid = try client.readRetainedString(
                from: deviceID,
                address: Self.deviceUIDAddress
            )
            guard !Self.isInternalDeviceUID(uid) else { continue }
            snapshots.append(try snapshot(deviceID: deviceID, uid: uid))
        }
        return snapshots
    }

    public func outputDeviceSnapshot(forUID uid: String) throws -> AudioOutputDeviceSnapshot {
        let deviceID = try deviceID(forUID: uid)
        return try snapshot(deviceID: deviceID, uid: uid)
    }

    public func writeVolume(_ volume: Double, forUID uid: String) throws -> Double {
        let deviceID = try deviceID(forUID: uid)
        let value = Float32(Self.clampedVolume(volume))
        try client.writeScalar(value, to: deviceID, address: Self.volumeAddress)
        let confirmed = try client.readScalar(
            Float32.self,
            from: deviceID,
            address: Self.volumeAddress
        )
        return Self.doubleValue(confirmed)
    }

    public func writeMute(_ isMuted: Bool, forUID uid: String) throws -> Bool {
        let deviceID = try deviceID(forUID: uid)
        let value: UInt32 = isMuted ? 1 : 0
        try client.writeScalar(value, to: deviceID, address: Self.muteAddress)
        let confirmed = try client.readScalar(
            UInt32.self,
            from: deviceID,
            address: Self.muteAddress
        )
        return confirmed != 0
    }

    public func outputDevices() -> [AudioOutputDeviceVolume] {
        (try? outputDeviceSnapshots().map(Self.legacyDevice)) ?? []
    }

    public func setVolume(_ volume: Double, for id: AudioOutputDeviceVolume.ID) -> Bool {
        (try? writeVolume(volume, forUID: id)) != nil
    }

    public func setMuted(_ isMuted: Bool, for id: AudioOutputDeviceVolume.ID) -> Bool {
        (try? writeMute(isMuted, forUID: id)) != nil
    }

    public nonisolated static func clampedVolume(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    public nonisolated static func makeDevice(
        id: String,
        name: String,
        volume: Double?,
        isMuted: Bool?,
        canSetVolume: Bool,
        canSetMute: Bool
    ) -> AudioOutputDeviceVolume {
        AudioOutputDeviceVolume(
            id: id,
            name: name,
            volume: clampedVolume(volume ?? 1.0),
            isMuted: isMuted ?? false,
            volumeAvailability: canSetVolume ? .writable : .unsupported,
            muteAvailability: canSetMute ? .writable : .unsupported
        )
    }
}

private extension AudioDeviceVolumeService {
    static var devicesAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioHardwarePropertyDevices)
    }

    static var outputStreamsAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    static var deviceUIDAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyDeviceUID)
    }

    static var deviceNameAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
    }

    static var volumeAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    static var muteAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    static func isInternalDeviceUID(_ uid: String) -> Bool {
        uid.hasPrefix(internalDeviceUIDPrefix)
    }

    static func doubleValue(_ value: Float32) -> Double {
        Double(String(value)) ?? Double(value)
    }

    static func legacyDevice(
        from snapshot: AudioOutputDeviceSnapshot
    ) -> AudioOutputDeviceVolume {
        makeDevice(
            id: snapshot.id,
            name: snapshot.name,
            volume: snapshot.volume.value,
            isMuted: snapshot.mute.value,
            canSetVolume: snapshot.volume.isWritable,
            canSetMute: snapshot.mute.isWritable
        )
    }

    func outputDeviceIDs() throws -> [AudioDeviceID] {
        let deviceIDs = try client.readArray(
            AudioDeviceID.self,
            from: AudioObjectID(kAudioObjectSystemObject),
            address: Self.devicesAddress
        )
        return deviceIDs.filter(hasOutputStreams)
    }

    func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        guard client.hasProperty(objectID: deviceID, address: Self.outputStreamsAddress) else {
            return false
        }
        guard let streams = try? client.readArray(
            AudioStreamID.self,
            from: deviceID,
            address: Self.outputStreamsAddress
        ) else {
            return false
        }
        return !streams.isEmpty
    }

    func deviceID(forUID uid: String) throws -> AudioDeviceID {
        guard !Self.isInternalDeviceUID(uid) else {
            throw missingDeviceError()
        }

        for deviceID in try outputDeviceIDs() {
            guard let candidateUID = try? client.readRetainedString(
                from: deviceID,
                address: Self.deviceUIDAddress
            ) else {
                continue
            }
            if candidateUID == uid, !Self.isInternalDeviceUID(candidateUID) {
                return deviceID
            }
        }
        throw missingDeviceError()
    }

    func snapshot(
        deviceID: AudioDeviceID,
        uid: String
    ) throws -> AudioOutputDeviceSnapshot {
        let name = try client.readRetainedString(
            from: deviceID,
            address: Self.deviceNameAddress
        )
        return AudioOutputDeviceSnapshot(
            id: uid,
            objectID: deviceID,
            name: name,
            volume: volumeValue(for: deviceID),
            mute: muteValue(for: deviceID)
        )
    }

    func volumeValue(for deviceID: AudioDeviceID) -> AudioPropertyValue<Double> {
        guard client.hasProperty(objectID: deviceID, address: Self.volumeAddress) else {
            return .unsupported
        }
        do {
            let value = try client.readScalar(
                Float32.self,
                from: deviceID,
                address: Self.volumeAddress
            )
            let isWritable = try client.isPropertySettable(
                objectID: deviceID,
                address: Self.volumeAddress
            )
            return .value(Self.doubleValue(value), isWritable: isWritable)
        } catch {
            return propertyFailure(error)
        }
    }

    func muteValue(for deviceID: AudioDeviceID) -> AudioPropertyValue<Bool> {
        guard client.hasProperty(objectID: deviceID, address: Self.muteAddress) else {
            return .unsupported
        }
        do {
            let value = try client.readScalar(
                UInt32.self,
                from: deviceID,
                address: Self.muteAddress
            )
            let isWritable = try client.isPropertySettable(
                objectID: deviceID,
                address: Self.muteAddress
            )
            return .value(value != 0, isWritable: isWritable)
        } catch {
            return propertyFailure(error)
        }
    }

    func propertyFailure<Value>(_ error: any Error) -> AudioPropertyValue<Value> {
        guard let halError = error as? AudioHALError else {
            preconditionFailure("AudioHALClient must throw AudioHALError")
        }
        if halError.status == kAudioHardwareBadObjectError {
            return .unavailable
        }
        return .failed(halError)
    }

    func missingDeviceError() -> AudioHALError {
        AudioHALError(
            operation: .getData,
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: Self.devicesAddress,
            reason: .missingValue
        )
    }
}
