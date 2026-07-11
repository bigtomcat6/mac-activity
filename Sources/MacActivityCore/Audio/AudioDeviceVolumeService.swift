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
    AudioDeviceVolumeProviding,
    AudioRouteDeviceProviding {
    private static let internalDeviceUIDPrefix = "com.how.macactivity.audio."

    private let client: AudioHALClient

    public convenience init() {
        self.init(client: .system)
    }

    init(client: AudioHALClient) {
        self.client = client
    }

    public func routeDevices() throws -> [AudioRouteDevice] {
        try outputDeviceIDs().map(routeDevice)
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

    static var inputStreamsAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        )
    }

    static var deviceUIDAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyDeviceUID)
    }

    static var deviceNameAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
    }

    static var deviceAliveAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyDeviceIsAlive)
    }

    static var activeAggregateSubdevicesAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyActiveSubDeviceList
        )
    }

    static var fullAggregateSubdevicesAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyFullSubDeviceList
        )
    }

    static var aggregateCompositionAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyComposition
        )
    }

    static var aggregateMainSubdeviceAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyMainSubDevice
        )
    }

    @available(macOS 14.2, *)
    static var aggregateTapListAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyTapList
        )
    }

    static var modelUIDAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyModelUID)
    }

    static var transportTypeAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyTransportType)
    }

    static var clockDomainAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyClockDomain)
    }

    static var ownerAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioObjectPropertyOwner)
    }

    static var classAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioObjectPropertyClass)
    }

    static var plugInBundleIDAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioPlugInPropertyBundleID)
    }

    static var streamVirtualFormatAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioStreamPropertyVirtualFormat)
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

    func routeDevice(_ deviceID: AudioDeviceID) throws -> AudioRouteDevice {
        let uid = try client.readRetainedString(
            from: deviceID,
            address: Self.deviceUIDAddress
        )
        let name = try client.readRetainedString(
            from: deviceID,
            address: Self.deviceNameAddress
        )
        let isAlive = try client.readScalar(
            UInt32.self,
            from: deviceID,
            address: Self.deviceAliveAddress
        ) != 0
        let outputStreamIDs = try client.readArray(
            AudioStreamID.self,
            from: deviceID,
            address: Self.outputStreamsAddress
        )
        let inputStreamIDs = client.hasProperty(
            objectID: deviceID,
            address: Self.inputStreamsAddress
        ) ? try client.readArray(
            AudioStreamID.self,
            from: deviceID,
            address: Self.inputStreamsAddress
        ) : []
        let isAggregate = [
            Self.fullAggregateSubdevicesAddress,
            Self.activeAggregateSubdevicesAddress,
            Self.aggregateCompositionAddress,
            Self.aggregateMainSubdeviceAddress,
        ].contains {
            client.hasProperty(objectID: deviceID, address: $0)
        }
        let aggregateSubdeviceUIDs = isAggregate
            ? activeAggregateSubdeviceUIDs(deviceID) ?? []
            : []

        return AudioRouteDevice(
            objectID: deviceID,
            uid: uid,
            name: name,
            isAlive: isAlive,
            isAggregate: isAggregate,
            aggregateSubdeviceUIDs: aggregateSubdeviceUIDs,
            inputStreams: try routeStreams(inputStreamIDs),
            outputStreams: try routeStreams(outputStreamIDs),
            clockDomain: optionalScalar(
                UInt32.self,
                objectID: deviceID,
                address: Self.clockDomainAddress
            ),
            transportType: optionalScalar(
                UInt32.self,
                objectID: deviceID,
                address: Self.transportTypeAddress
            ),
            modelUID: optionalString(
                objectID: deviceID,
                address: Self.modelUIDAddress
            ),
            driverIdentity: driverIdentity(deviceID),
            aggregateComposition: isAggregate
                ? aggregateComposition(
                    deviceID,
                    activeSubdeviceUIDs: aggregateSubdeviceUIDs
                )
                : nil
        )
    }

    func routeStreams(_ streamIDs: [AudioStreamID]) throws -> [AudioRouteStream] {
        try streamIDs.enumerated().map { index, streamID in
            let format = try client.readScalar(
                AudioStreamBasicDescription.self,
                from: streamID,
                address: Self.streamVirtualFormatAddress
            )
            return AudioRouteStream(
                streamObjectID: streamID,
                streamIndex: UInt(index),
                format: Self.routeFormat(format)
            )
        }
    }

    func activeAggregateSubdeviceUIDs(_ deviceID: AudioDeviceID) -> [String]? {
        guard let subdeviceIDs = optionalArray(
            AudioObjectID.self,
            objectID: deviceID,
            address: Self.activeAggregateSubdevicesAddress
        ) else {
            return nil
        }
        return try? subdeviceIDs.map {
            try client.readRetainedString(from: $0, address: Self.deviceUIDAddress)
        }
    }

    func aggregateComposition(
        _ deviceID: AudioDeviceID,
        activeSubdeviceUIDs: [String]
    ) -> AudioRouteAggregateComposition? {
        let tapUUIDs: [String]
        if #available(macOS 14.2, *) {
            guard let values = optionalStringArray(
                objectID: deviceID,
                address: Self.aggregateTapListAddress
            ) else {
                return nil
            }
            tapUUIDs = values
        } else {
            tapUUIDs = []
        }

        let compositionDictionary = optionalObject(
            CFDictionary.self,
            objectID: deviceID,
            address: Self.aggregateCompositionAddress
        )
        let isStacked = compositionDictionary.flatMap {
            ($0 as NSDictionary)[kAudioAggregateDeviceIsStackedKey] as? NSNumber
        }?.boolValue

        return AudioRouteAggregateComposition(
            fullSubdeviceUIDs: optionalStringArray(
                objectID: deviceID,
                address: Self.fullAggregateSubdevicesAddress
            ) ?? [],
            activeSubdeviceUIDs: activeSubdeviceUIDs,
            mainSubdeviceUID: optionalString(
                objectID: deviceID,
                address: Self.aggregateMainSubdeviceAddress
            ),
            isStacked: isStacked,
            tapUUIDs: tapUUIDs
        )
    }

    func driverIdentity(_ deviceID: AudioDeviceID) -> AudioRouteDriverIdentity? {
        guard let ownerID = optionalScalar(
            AudioObjectID.self,
            objectID: deviceID,
            address: Self.ownerAddress
        ), ownerID != kAudioObjectUnknown,
        optionalScalar(
            AudioClassID.self,
            objectID: ownerID,
            address: Self.classAddress
        ) == kAudioPlugInClassID,
        let bundleID = optionalString(
            objectID: ownerID,
            address: Self.plugInBundleIDAddress
        ) else {
            return nil
        }
        return AudioRouteDriverIdentity(
            plugInBundleID: bundleID,
            availableVersion: nil
        )
    }

    func optionalScalar<T>(
        _ type: T.Type,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> T? {
        guard client.hasProperty(objectID: objectID, address: address) else { return nil }
        return try? client.readScalar(type, from: objectID, address: address)
    }

    func optionalArray<T>(
        _ type: T.Type,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> [T]? {
        guard client.hasProperty(objectID: objectID, address: address) else { return nil }
        return try? client.readArray(type, from: objectID, address: address)
    }

    func optionalString(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> String? {
        guard client.hasProperty(objectID: objectID, address: address) else { return nil }
        return try? client.readRetainedString(from: objectID, address: address)
    }

    func optionalObject<T: AnyObject>(
        _ type: T.Type,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> T? {
        guard client.hasProperty(objectID: objectID, address: address) else { return nil }
        return try? client.readRetainedObject(type, from: objectID, address: address)
    }

    func optionalStringArray(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> [String]? {
        guard let array = optionalObject(
            CFArray.self,
            objectID: objectID,
            address: address
        ) else {
            return nil
        }
        var result: [String] = []
        for value in array as NSArray {
            guard let string = value as? String else { return nil }
            result.append(string)
        }
        return result
    }

    static func routeFormat(
        _ format: AudioStreamBasicDescription
    ) -> ProcessTapAudioFormat {
        ProcessTapAudioFormat(
            sampleRate: format.mSampleRate,
            channelCount: Int(format.mChannelsPerFrame),
            formatID: format.mFormatID,
            formatFlags: format.mFormatFlags,
            bitsPerChannel: format.mBitsPerChannel,
            interleaving: format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
                ? .nonInterleaved
                : .interleaved
        )
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
