import AudioToolbox
import CoreAudio
import Foundation

@MainActor
public protocol AudioDeviceControlProviding: AnyObject {
    func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot]
    func outputDeviceSnapshot(forUID uid: String) throws -> AudioOutputDeviceSnapshot
    func writeVolume(_ volume: Double, forUID uid: String) throws -> Double
    func writeMute(_ isMuted: Bool, forUID uid: String) throws -> Bool
}

@MainActor
public final class AudioDeviceVolumeService:
    AudioDeviceControlProviding,
    AudioRouteDeviceProviding {
    private nonisolated static let internalDeviceUIDPrefix = "com.how.macactivity.audio."

    private let client: AudioHALClient

    public convenience init() {
        self.init(client: .system)
    }

    init(client: AudioHALClient) {
        self.client = client
    }

    public func routeDevices() throws -> [AudioRouteDevice] {
        try Self.outputDeviceIDs(client: client).compactMap {
            try? Self.routeDevice($0, client: client)
        }
    }

    nonisolated static func routeDevices(
        for deviceIDs: [AudioDeviceID],
        client: AudioHALClient
    ) throws -> [AudioRouteDevice] {
        var seenDeviceIDs: Set<AudioDeviceID> = []
        return try deviceIDs.compactMap { deviceID in
            seenDeviceIDs.insert(deviceID).inserted ? deviceID : nil
        }.map {
            try routeDevice($0, client: client)
        }
    }

    public func outputDeviceSnapshots() throws -> [AudioOutputDeviceSnapshot] {
        var snapshots: [AudioOutputDeviceSnapshot] = []
        for deviceID in try Self.outputDeviceIDs(client: client) {
            guard let uid = try? client.readRetainedString(
                from: deviceID,
                address: Self.deviceUIDAddress
            ) else {
                continue
            }
            guard !Self.isInternalDeviceUID(uid) else { continue }
            guard let snapshot = try? snapshot(deviceID: deviceID, uid: uid) else {
                continue
            }
            snapshots.append(snapshot)
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

    public nonisolated static func clampedVolume(_ value: Double) -> Double {
        min(1, max(0, value))
    }

}

private extension AudioDeviceVolumeService {
    nonisolated static var devicesAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioHardwarePropertyDevices)
    }

    nonisolated static var outputStreamsAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    nonisolated static var inputStreamsAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        )
    }

    nonisolated static var deviceUIDAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyDeviceUID)
    }

    nonisolated static var deviceNameAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
    }

    nonisolated static var deviceAliveAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyDeviceIsAlive)
    }

    nonisolated static var activeAggregateSubdevicesAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyActiveSubDeviceList
        )
    }

    nonisolated static var fullAggregateSubdevicesAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyFullSubDeviceList
        )
    }

    nonisolated static var aggregateCompositionAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyComposition
        )
    }

    nonisolated static var aggregateMainSubdeviceAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyMainSubDevice
        )
    }

    @available(macOS 14.2, *)
    nonisolated static var aggregateTapListAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioAggregateDevicePropertyTapList
        )
    }

    nonisolated static var modelUIDAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyModelUID)
    }

    nonisolated static var transportTypeAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyTransportType)
    }

    nonisolated static var clockDomainAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioDevicePropertyClockDomain)
    }

    nonisolated static var ownerAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioObjectPropertyOwner)
    }

    nonisolated static var classAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioObjectPropertyClass)
    }

    nonisolated static var plugInBundleIDAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioPlugInPropertyBundleID)
    }

    nonisolated static var streamVirtualFormatAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioStreamPropertyVirtualFormat)
    }

    nonisolated static var volumeAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    nonisolated static var muteAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    nonisolated static func isInternalDeviceUID(_ uid: String) -> Bool {
        uid.hasPrefix(internalDeviceUIDPrefix)
    }

    nonisolated static func doubleValue(_ value: Float32) -> Double {
        Double(String(value)) ?? Double(value)
    }

    nonisolated static func outputDeviceIDs(client: AudioHALClient) throws -> [AudioDeviceID] {
        let deviceIDs = try client.readArray(
            AudioDeviceID.self,
            from: AudioObjectID(kAudioObjectSystemObject),
            address: Self.devicesAddress
        )
        return deviceIDs.filter { hasOutputStreams($0, client: client) }
    }

    nonisolated static func hasOutputStreams(
        _ deviceID: AudioDeviceID,
        client: AudioHALClient
    ) -> Bool {
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

    nonisolated static func routeDevice(
        _ deviceID: AudioDeviceID,
        client: AudioHALClient
    ) throws -> AudioRouteDevice {
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
        let aggregateSubdeviceUIDs: [String]
        if isAggregate {
            aggregateSubdeviceUIDs = try activeAggregateSubdeviceUIDs(
                deviceID,
                client: client
            ) ?? []
        } else {
            aggregateSubdeviceUIDs = []
        }

        return AudioRouteDevice(
            objectID: deviceID,
            uid: uid,
            name: name,
            isAlive: isAlive,
            isAggregate: isAggregate,
            aggregateSubdeviceUIDs: aggregateSubdeviceUIDs,
            inputStreams: try routeStreams(inputStreamIDs, client: client),
            outputStreams: try routeStreams(outputStreamIDs, client: client),
            clockDomain: optionalScalar(
                UInt32.self,
                objectID: deviceID,
                address: Self.clockDomainAddress,
                client: client
            ),
            transportType: optionalScalar(
                UInt32.self,
                objectID: deviceID,
                address: Self.transportTypeAddress,
                client: client
            ),
            modelUID: optionalString(
                objectID: deviceID,
                address: Self.modelUIDAddress,
                client: client
            ),
            driverIdentity: try driverIdentity(deviceID, client: client),
            aggregateComposition: isAggregate
                ? try aggregateComposition(
                    deviceID,
                    activeSubdeviceUIDs: aggregateSubdeviceUIDs,
                    client: client
                )
                : nil
        )
    }

    nonisolated static func routeStreams(
        _ streamIDs: [AudioStreamID],
        client: AudioHALClient
    ) throws -> [AudioRouteStream] {
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

    nonisolated static func activeAggregateSubdeviceUIDs(
        _ deviceID: AudioDeviceID,
        client: AudioHALClient
    ) throws -> [String]? {
        guard let subdeviceIDs = optionalArray(
            AudioObjectID.self,
            objectID: deviceID,
            address: Self.activeAggregateSubdevicesAddress,
            client: client
        ) else {
            return nil
        }
        return try subdeviceIDs.map {
            try client.readRetainedString(from: $0, address: Self.deviceUIDAddress)
        }
    }

    nonisolated static func aggregateComposition(
        _ deviceID: AudioDeviceID,
        activeSubdeviceUIDs: [String],
        client: AudioHALClient
    ) throws -> AudioRouteAggregateComposition? {
        let tapUUIDs: [String]
        if #available(macOS 14.2, *) {
            guard let values = try optionalStringArray(
                objectID: deviceID,
                address: Self.aggregateTapListAddress,
                client: client
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
            address: Self.aggregateCompositionAddress,
            client: client
        )
        let isStacked = compositionDictionary.flatMap {
            ($0 as NSDictionary)[kAudioAggregateDeviceIsStackedKey] as? NSNumber
        }?.boolValue

        return AudioRouteAggregateComposition(
            fullSubdeviceUIDs: try optionalStringArray(
                objectID: deviceID,
                address: Self.fullAggregateSubdevicesAddress,
                client: client
            ) ?? [],
            activeSubdeviceUIDs: activeSubdeviceUIDs,
            mainSubdeviceUID: optionalString(
                objectID: deviceID,
                address: Self.aggregateMainSubdeviceAddress,
                client: client
            ),
            isStacked: isStacked,
            tapUUIDs: tapUUIDs
        )
    }

    nonisolated static func driverIdentity(
        _ deviceID: AudioDeviceID,
        client: AudioHALClient
    ) throws -> AudioRouteDriverIdentity? {
        guard let ownerID = optionalScalar(
            AudioObjectID.self,
            objectID: deviceID,
            address: Self.ownerAddress,
            client: client
        ), ownerID != kAudioObjectUnknown,
        optionalScalar(
            AudioClassID.self,
            objectID: ownerID,
            address: Self.classAddress,
            client: client
        ) == kAudioPlugInClassID,
        let bundleID = optionalString(
            objectID: ownerID,
            address: Self.plugInBundleIDAddress,
            client: client
        ) else {
            return nil
        }
        return AudioRouteDriverIdentity(
            plugInBundleID: bundleID,
            availableVersion: nil
        )
    }

    nonisolated static func optionalScalar<T>(
        _ type: T.Type,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        client: AudioHALClient
    ) -> T? {
        guard client.hasProperty(objectID: objectID, address: address) else { return nil }
        return try? client.readScalar(type, from: objectID, address: address)
    }

    nonisolated static func optionalArray<T>(
        _ type: T.Type,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        client: AudioHALClient
    ) -> [T]? {
        guard client.hasProperty(objectID: objectID, address: address) else { return nil }
        return try? client.readArray(type, from: objectID, address: address)
    }

    nonisolated static func optionalString(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        client: AudioHALClient
    ) -> String? {
        guard client.hasProperty(objectID: objectID, address: address) else { return nil }
        return try? client.readRetainedString(from: objectID, address: address)
    }

    nonisolated static func optionalObject<T: AnyObject>(
        _ type: T.Type,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        client: AudioHALClient
    ) -> T? {
        guard client.hasProperty(objectID: objectID, address: address) else { return nil }
        return try? client.readRetainedObject(type, from: objectID, address: address)
    }

    nonisolated static func optionalStringArray(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        client: AudioHALClient
    ) throws -> [String]? {
        guard let array = optionalObject(
            CFArray.self,
            objectID: objectID,
            address: address,
            client: client
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

    nonisolated static func routeFormat(
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

        for deviceID in try Self.outputDeviceIDs(client: client) {
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
