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
public protocol AudioDeviceVolumeProviding: AnyObject {
    func outputDevices() -> [AudioOutputDeviceVolume]
    func setVolume(_ volume: Double, for id: AudioOutputDeviceVolume.ID) -> Bool
    func setMuted(_ isMuted: Bool, for id: AudioOutputDeviceVolume.ID) -> Bool
}

@MainActor
public final class AudioDeviceVolumeService: AudioDeviceVolumeProviding {
    public init() {}

    public func outputDevices() -> [AudioOutputDeviceVolume] {
        Self.readOutputDeviceIDs().compactMap(Self.deviceVolume)
    }

    public func setVolume(_ volume: Double, for id: AudioOutputDeviceVolume.ID) -> Bool {
        guard let deviceID = Self.deviceID(forUID: id) else { return false }
        var value = Float32(Self.clampedVolume(volume))
        return Self.setFloat32(
            value: &value,
            deviceID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    public func setMuted(_ isMuted: Bool, for id: AudioOutputDeviceVolume.ID) -> Bool {
        guard let deviceID = Self.deviceID(forUID: id) else { return false }
        var value: UInt32 = isMuted ? 1 : 0
        return Self.setUInt32(
            value: &value,
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        )
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
    static func readOutputDeviceIDs() -> [AudioDeviceID] {
        let address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard let deviceIDs = getArray(
            for: AudioObjectID(kAudioObjectSystemObject),
            address: address,
            as: AudioDeviceID.self
        ) else {
            return []
        }

        return deviceIDs.filter(deviceHasOutput)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        readOutputDeviceIDs().first { deviceUID(for: $0) == uid }
    }

    static func deviceVolume(_ deviceID: AudioDeviceID) -> AudioOutputDeviceVolume? {
        guard let id = deviceUID(for: deviceID), let name = deviceName(for: deviceID) else {
            return nil
        }

        let volumeAddress = propertyAddress(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        )
        let canSetVolume = isPropertySettable(deviceID: deviceID, address: volumeAddress)
        let volume = canSetVolume ? getFloat32(deviceID: deviceID, address: volumeAddress).map(Double.init) : nil

        let muteAddress = propertyAddress(
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        )
        let canSetMute = isPropertySettable(deviceID: deviceID, address: muteAddress)
        let isMuted = canSetMute ? getUInt32(deviceID: deviceID, address: muteAddress).map { $0 != 0 } : nil

        return makeDevice(
            id: id,
            name: name,
            volume: volume,
            isMuted: isMuted,
            canSetVolume: canSetVolume,
            canSetMute: canSetMute
        )
    }

    static func deviceHasOutput(_ deviceID: AudioDeviceID) -> Bool {
        var address = propertyAddress(
            selector: kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeOutput
        )
        var byteCount: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount) == noErr else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, buffer) == noErr else {
            return false
        }

        let bufferList = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        let address = propertyAddress(
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )

        guard let cfString = getCFString(deviceID: deviceID, address: address) else {
            return nil
        }

        return cfString as String
    }

    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        let address = propertyAddress(
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        )

        guard let cfString = getCFString(deviceID: deviceID, address: address) else {
            return nil
        }

        return cfString as String
    }

    static func getFloat32(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var value = Float32.zero
        var byteCount = UInt32(MemoryLayout<Float32>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value) == noErr else {
            return nil
        }

        return value
    }

    static func getUInt32(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value = UInt32.zero
        var byteCount = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value) == noErr else {
            return nil
        }

        return value
    }

    static func getCFString(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) -> CFString? {
        var address = address
        let pointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var byteCount = UInt32(MemoryLayout<CFString?>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, pointer) == noErr else {
            return nil
        }

        return pointer.pointee
    }

    static func setFloat32(
        value: inout Float32,
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = propertyAddress(selector: selector, scope: scope)
        let byteCount = UInt32(MemoryLayout<Float32>.size)

        guard isPropertySettable(deviceID: deviceID, address: address) else {
            return false
        }

        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, byteCount, &value) == noErr
    }

    static func setUInt32(
        value: inout UInt32,
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = propertyAddress(selector: selector, scope: scope)
        let byteCount = UInt32(MemoryLayout<UInt32>.size)

        guard isPropertySettable(deviceID: deviceID, address: address) else {
            return false
        }

        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, byteCount, &value) == noErr
    }

    static func isPropertySettable(deviceID: AudioDeviceID, address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var isSettable: DarwinBoolean = false

        guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr else {
            return false
        }

        return isSettable.boolValue
    }

    static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func getArray<T>(
        for objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        as type: T.Type
    ) -> [T]? {
        var address = address
        var byteCount: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &byteCount) == noErr else {
            return nil
        }

        let itemSize = UInt32(MemoryLayout<T>.stride)
        guard itemSize > 0 else { return nil }
        let count = Int(byteCount / itemSize)
        guard count > 0 else { return [] }
        var values = Array<T>(unsafeUninitializedCapacity: count) { _, initializedCount in
            initializedCount = count
        }

        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, buffer.baseAddress!)
        }

        guard status == noErr else {
            return nil
        }

        return values
    }
}
