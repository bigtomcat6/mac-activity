import AppKit
import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import MacActivityCore

@MainActor
public struct AudioNativePreflightCollector {
    private static let internalDeviceUIDPrefix = "com.how.macactivity.audio."
    private let controlInspectionPolicy: AudioNativePreflightControlInspectionPolicy

    public init(includeDeviceControls: Bool = false) {
        self.controlInspectionPolicy = AudioNativePreflightControlInspectionPolicy(
            includeDeviceControls: includeDeviceControls
        )
    }

    public func collect() throws -> AudioNativePreflightReport {
        let processInfo = ProcessInfo.processInfo
        let operatingSystemVersion = processInfo.operatingSystemVersion
        let processDiscoveryAvailable: Bool
        if #available(macOS 14.2, *) {
            processDiscoveryAvailable = true
        } else {
            processDiscoveryAvailable = false
        }

        let client = AudioHALClient.system
        let deviceObservations = try Self.deviceObservations(
            client: client,
            controlInspectionPolicy: controlInspectionPolicy
        )

        let processAvailability = AudioFeatureAvailability(
            operatingSystemVersion: operatingSystemVersion
        )
        let processObservations: [AudioNativePreflightProcessObservation]
        if #available(macOS 14.2, *) {
            guard processAvailability.supportsProcessControls else {
                throw AudioNativePreflightCollectionError.processDiscoveryGateUnavailable
            }
            processObservations = try Self.processObservations(client: client)
        } else {
            processObservations = []
        }

        return AudioNativePreflightReport.make(
            schemaVersion: 1,
            operatingSystemVersion: Self.versionString(operatingSystemVersion),
            osBuild: try Self.currentOSBuild(),
            processDiscoveryAvailable: processDiscoveryAvailable,
            devices: deviceObservations,
            processes: processObservations
        )
    }
}

private extension AudioNativePreflightCollector {
    static let devicesAddress = AudioHALPropertyAddress(
        selector: kAudioHardwarePropertyDevices
    )
    static let outputStreamsAddress = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyStreams,
        scope: kAudioObjectPropertyScopeOutput
    )
    static let inputStreamsAddress = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyStreams,
        scope: kAudioObjectPropertyScopeInput
    )
    static let deviceUIDAddress = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyDeviceUID
    )
    static let deviceNameAddress = AudioHALPropertyAddress(
        selector: kAudioObjectPropertyName
    )
    static let deviceAliveAddress = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyDeviceIsAlive
    )
    static let activeAggregateSubdevicesAddress = AudioHALPropertyAddress(
        selector: kAudioAggregateDevicePropertyActiveSubDeviceList
    )
    static let fullAggregateSubdevicesAddress = AudioHALPropertyAddress(
        selector: kAudioAggregateDevicePropertyFullSubDeviceList
    )
    static let aggregateCompositionAddress = AudioHALPropertyAddress(
        selector: kAudioAggregateDevicePropertyComposition
    )
    static let aggregateMainSubdeviceAddress = AudioHALPropertyAddress(
        selector: kAudioAggregateDevicePropertyMainSubDevice
    )
    static let modelUIDAddress = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyModelUID
    )
    static let transportTypeAddress = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyTransportType
    )
    static let clockDomainAddress = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyClockDomain
    )
    static let ownerAddress = AudioHALPropertyAddress(
        selector: kAudioObjectPropertyOwner
    )
    static let classAddress = AudioHALPropertyAddress(
        selector: kAudioObjectPropertyClass
    )
    static let plugInBundleIDAddress = AudioHALPropertyAddress(
        selector: kAudioPlugInPropertyBundleID
    )
    static let streamVirtualFormatAddress = AudioHALPropertyAddress(
        selector: kAudioStreamPropertyVirtualFormat
    )
    static let volumeAddress = AudioHALPropertyAddress(
        selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        scope: kAudioObjectPropertyScopeOutput
    )
    static let muteAddress = AudioHALPropertyAddress(
        selector: kAudioDevicePropertyMute,
        scope: kAudioObjectPropertyScopeOutput
    )

    @available(macOS 14.2, *)
    static var aggregateTapListAddress: AudioHALPropertyAddress {
        AudioHALPropertyAddress(selector: kAudioAggregateDevicePropertyTapList)
    }

    static let impossibleReadOnlyFingerprint = AudioRouteTopologyFingerprint(
        osBuild: "__AudioNativePreflight_Impossible_OS_Build__",
        sourceDeviceUIDs: ["__AudioNativePreflight_Impossible_Source_UID__"],
        selectedTargetUIDs: ["__AudioNativePreflight_Impossible_Target_UID__"],
        devices: []
    )

    static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func deviceObservations(
        client: AudioHALClient,
        controlInspectionPolicy: AudioNativePreflightControlInspectionPolicy
    ) throws -> [AudioNativePreflightDeviceObservation] {
        let deviceIDs = try client.readArray(
            AudioDeviceID.self,
            from: AudioObjectID(kAudioObjectSystemObject),
            address: devicesAddress
        )
        let outputDevices = try AudioNativePreflightHALDiscovery.outputDevices(
            deviceIDs: deviceIDs,
            outputStreams: { deviceID in
                guard client.hasProperty(
                    objectID: deviceID,
                    address: outputStreamsAddress
                ) else { return [] }
                return try client.readArray(
                    AudioStreamID.self,
                    from: deviceID,
                    address: outputStreamsAddress
                )
            }
        )

        return try outputDevices.compactMap { outputDevice in
            try deviceObservation(
                outputDevice,
                client: client,
                controlInspectionPolicy: controlInspectionPolicy
            )
        }
    }

    static func deviceObservation(
        _ outputDevice: AudioNativePreflightOutputDevice,
        client: AudioHALClient,
        controlInspectionPolicy: AudioNativePreflightControlInspectionPolicy
    ) throws -> AudioNativePreflightDeviceObservation? {
        let deviceID = outputDevice.deviceID
        let uid = try client.readRetainedString(
            from: deviceID,
            address: deviceUIDAddress
        )
        guard !uid.hasPrefix(internalDeviceUIDPrefix) else { return nil }

        let name = try client.readRetainedString(
            from: deviceID,
            address: deviceNameAddress
        )
        let alive = try client.readScalar(
            UInt32.self,
            from: deviceID,
            address: deviceAliveAddress
        ) != 0
        let inputStreamIDs: [AudioStreamID] = try optionalProperty(
            client: client,
            objectID: deviceID,
            address: inputStreamsAddress,
            read: {
                try client.readArray(AudioStreamID.self, from: deviceID, address: $0)
            }
        ) ?? []
        let aggregateAddresses = [
            fullAggregateSubdevicesAddress,
            activeAggregateSubdevicesAddress,
            aggregateCompositionAddress,
            aggregateMainSubdeviceAddress,
        ]
        let isAggregate = aggregateAddresses.contains {
            client.hasProperty(objectID: deviceID, address: $0)
        }
        let controlObservations = controlInspectionPolicy.observations(
            volume: { volumeObservation(deviceID: deviceID, client: client) },
            mute: { muteObservation(deviceID: deviceID, client: client) }
        )

        return AudioNativePreflightDeviceObservation(
            diagnosticObjectID: deviceID,
            uid: uid,
            name: name,
            alive: alive,
            isAggregate: isAggregate,
            aggregateComposition: isAggregate
                ? try aggregateComposition(deviceID: deviceID, client: client)
                : nil,
            modelUID: try optionalString(
                client: client,
                objectID: deviceID,
                address: modelUIDAddress
            ),
            driverIdentity: try driverIdentity(
                deviceID: deviceID,
                client: client
            ),
            transportType: try optionalScalar(
                UInt32.self,
                client: client,
                objectID: deviceID,
                address: transportTypeAddress
            ),
            clockDomain: try optionalScalar(
                UInt32.self,
                client: client,
                objectID: deviceID,
                address: clockDomainAddress
            ),
            inputStreams: try streamObservations(inputStreamIDs, client: client),
            outputStreams: try streamObservations(
                outputDevice.outputStreamIDs,
                client: client
            ),
            volume: controlObservations.volume,
            mute: controlObservations.mute
        )
    }

    static func streamObservations(
        _ streamIDs: [AudioStreamID],
        client: AudioHALClient
    ) throws -> [AudioNativePreflightStreamObservation] {
        try streamIDs.enumerated().map { index, streamID in
            let format = try client.readScalar(
                AudioStreamBasicDescription.self,
                from: streamID,
                address: streamVirtualFormatAddress
            )
            return AudioNativePreflightStreamObservation(
                diagnosticObjectID: streamID,
                index: UInt(index),
                format: AudioNativePreflightStreamFormat(format)
            )
        }
    }

    static func aggregateComposition(
        deviceID: AudioDeviceID,
        client: AudioHALClient
    ) throws -> AudioRouteAggregateComposition {
        let fullArray: CFArray = try requiredObject(
            CFArray.self,
            name: "FullSubDeviceList",
            client: client,
            objectID: deviceID,
            address: fullAggregateSubdevicesAddress
        )
        let activeIDs: [AudioObjectID] = try requiredArray(
            AudioObjectID.self,
            name: "ActiveSubDeviceList",
            client: client,
            objectID: deviceID,
            address: activeAggregateSubdevicesAddress
        )
        let mainUID: String = try requiredString(
            name: "MainSubDevice",
            client: client,
            objectID: deviceID,
            address: aggregateMainSubdeviceAddress
        )
        let composition: CFDictionary = try requiredObject(
            CFDictionary.self,
            name: "Composition",
            client: client,
            objectID: deviceID,
            address: aggregateCompositionAddress
        )
        guard let stacked = (composition as NSDictionary)[
            kAudioAggregateDeviceIsStackedKey
        ] as? NSNumber else {
            throw AudioNativePreflightHALDiscoveryError.malformedRequiredProperty(
                "Composition.Stacked"
            )
        }

        let tapUUIDs: [String]
        if #available(macOS 14.2, *) {
            tapUUIDs = try AudioNativePreflightHALDiscovery.aggregateTapUUIDs(
                isAvailableOnPlatform: true,
                read: {
                    let tapArray: CFArray = try requiredObject(
                        CFArray.self,
                        name: "TapList",
                        client: client,
                        objectID: deviceID,
                        address: aggregateTapListAddress
                    )
                    return try stringValues(tapArray, name: "TapList")
                }
            )
        } else {
            tapUUIDs = AudioNativePreflightHALDiscovery.aggregateTapUUIDs(
                isAvailableOnPlatform: false,
                read: { [] }
            )
        }

        return AudioRouteAggregateComposition(
            fullSubdeviceUIDs: try stringValues(fullArray, name: "FullSubDeviceList"),
            activeSubdeviceUIDs: try activeIDs.map {
                try client.readRetainedString(from: $0, address: deviceUIDAddress)
            },
            mainSubdeviceUID: mainUID,
            isStacked: stacked.boolValue,
            tapUUIDs: tapUUIDs
        )
    }

    static func driverIdentity(
        deviceID: AudioDeviceID,
        client: AudioHALClient
    ) throws -> AudioRouteDriverIdentity? {
        guard let ownerID = try optionalScalar(
            AudioObjectID.self,
            client: client,
            objectID: deviceID,
            address: ownerAddress
        ), ownerID != kAudioObjectUnknown else { return nil }
        guard let classID = try optionalScalar(
            AudioClassID.self,
            client: client,
            objectID: ownerID,
            address: classAddress
        ), classID == kAudioPlugInClassID else { return nil }
        guard let bundleID = try optionalString(
            client: client,
            objectID: ownerID,
            address: plugInBundleIDAddress
        ) else { return nil }
        return AudioRouteDriverIdentity(
            plugInBundleID: bundleID,
            availableVersion: nil
        )
    }

    static func optionalScalar<Value>(
        _ type: Value.Type,
        client: AudioHALClient,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> Value? {
        try optionalProperty(
            client: client,
            objectID: objectID,
            address: address,
            read: { try client.readScalar(type, from: objectID, address: $0) }
        )
    }

    static func optionalString(
        client: AudioHALClient,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> String? {
        try optionalProperty(
            client: client,
            objectID: objectID,
            address: address,
            read: { try client.readRetainedString(from: objectID, address: $0) }
        )
    }

    static func optionalProperty<Value>(
        client: AudioHALClient,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        read: (AudioHALPropertyAddress) throws -> Value
    ) throws -> Value? {
        try AudioNativePreflightHALDiscovery.optionalProperty(
            isPresent: client.hasProperty(objectID: objectID, address: address),
            read: { try read(address) }
        )
    }

    static func requiredArray<Value>(
        _ type: Value.Type,
        name: String,
        client: AudioHALClient,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> [Value] {
        try AudioNativePreflightHALDiscovery.requiredProperty(
            isPresent: client.hasProperty(objectID: objectID, address: address),
            name: name,
            read: { try client.readArray(type, from: objectID, address: address) }
        )
    }

    static func requiredString(
        name: String,
        client: AudioHALClient,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> String {
        try AudioNativePreflightHALDiscovery.requiredProperty(
            isPresent: client.hasProperty(objectID: objectID, address: address),
            name: name,
            read: {
                try client.readRetainedString(from: objectID, address: address)
            }
        )
    }

    static func requiredObject<Value: AnyObject>(
        _ type: Value.Type,
        name: String,
        client: AudioHALClient,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> Value {
        try AudioNativePreflightHALDiscovery.requiredProperty(
            isPresent: client.hasProperty(objectID: objectID, address: address),
            name: name,
            read: {
                try client.readRetainedObject(type, from: objectID, address: address)
            }
        )
    }

    static func stringValues(_ array: CFArray, name: String) throws -> [String] {
        try (array as NSArray).map { value in
            guard let string = value as? String else {
                throw AudioNativePreflightHALDiscoveryError
                    .malformedRequiredProperty(name)
            }
            return string
        }
    }

    static func volumeObservation(
        deviceID: AudioDeviceID,
        client: AudioHALClient
    ) -> AudioNativePreflightPropertyObservation<Double> {
        guard client.hasProperty(objectID: deviceID, address: volumeAddress) else {
            return .unsupported
        }
        do {
            let value = try client.readScalar(
                Float32.self,
                from: deviceID,
                address: volumeAddress
            )
            let isWritable = try client.isPropertySettable(
                objectID: deviceID,
                address: volumeAddress
            )
            return .value(Double(value), isWritable: isWritable)
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func muteObservation(
        deviceID: AudioDeviceID,
        client: AudioHALClient
    ) -> AudioNativePreflightPropertyObservation<Bool> {
        guard client.hasProperty(objectID: deviceID, address: muteAddress) else {
            return .unsupported
        }
        do {
            let value = try client.readScalar(
                UInt32.self,
                from: deviceID,
                address: muteAddress
            )
            let isWritable = try client.isPropertySettable(
                objectID: deviceID,
                address: muteAddress
            )
            return .value(value != 0, isWritable: isWritable)
        } catch {
            return .failed(String(describing: error))
        }
    }

    static func currentOSBuild() throws -> String {
        var byteCount = 0
        guard sysctlbyname("kern.osversion", nil, &byteCount, nil, 0) == 0,
              byteCount > 1 else {
            throw AudioNativePreflightCollectionError.osBuildUnavailable
        }

        var bytes = [CChar](repeating: 0, count: byteCount)
        guard sysctlbyname("kern.osversion", &bytes, &byteCount, nil, 0) == 0,
              byteCount > 1,
              byteCount <= bytes.count,
              bytes[byteCount - 1] == 0 else {
            throw AudioNativePreflightCollectionError.osBuildUnavailable
        }
        let buildBytes = bytes.prefix(byteCount - 1).map(UInt8.init(bitPattern:))
        guard let build = String(bytes: buildBytes, encoding: .utf8),
              !build.isEmpty else {
            throw AudioNativePreflightCollectionError.osBuildUnavailable
        }
        return build
    }

    @available(macOS 14.2, *)
    static func processObservations(
        client: AudioHALClient
    ) throws -> [AudioNativePreflightProcessObservation] {
        let processObjectIDs = try client.readArray(
            AudioObjectID.self,
            from: AudioObjectID(kAudioObjectSystemObject),
            address: .init(selector: kAudioHardwarePropertyProcessObjectList)
        )
        let apps = NSWorkspace.shared.runningApplications.map {
            AudioProcessAppSnapshot(
                processIdentifier: $0.processIdentifier,
                name: $0.localizedName ?? $0.bundleIdentifier
                    ?? "Process \($0.processIdentifier)",
                bundleIdentifier: $0.bundleIdentifier,
                bundleURL: $0.bundleURL
            )
        }
        return try AudioNativePreflightProcessDiscovery.observations(
            processObjectIDs: processObjectIDs,
            apps: apps,
            snapshot: { try processSnapshot(objectID: $0, client: client) }
        )
    }

    @available(macOS 14.2, *)
    static func processSnapshot(
        objectID: AudioObjectID,
        client: AudioHALClient
    ) throws -> AudioProcessSnapshot {
        let pid = try client.readScalar(
            pid_t.self,
            from: objectID,
            address: .init(selector: kAudioProcessPropertyPID)
        )
        let bundleAddress = AudioHALPropertyAddress(
            selector: kAudioProcessPropertyBundleID
        )
        let bundleIdentifier = client.hasProperty(
            objectID: objectID,
            address: bundleAddress
        ) ? try client.readRetainedString(
            from: objectID,
            address: bundleAddress
        ) : nil
        let isRunningOutput = try client.readScalar(
            UInt32.self,
            from: objectID,
            address: .init(selector: kAudioProcessPropertyIsRunningOutput)
        ) != 0
        let outputDeviceIDs = isRunningOutput ? try client.readArray(
            AudioDeviceID.self,
            from: objectID,
            address: .init(
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput
            )
        ) : []
        return AudioProcessSnapshot(
            processObjectID: objectID,
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            isRunningOutput: isRunningOutput,
            outputDeviceIDs: outputDeviceIDs
        )
    }
}

public struct AudioNativePreflightArguments: Equatable, Sendable {
    public let includeDeviceControls: Bool

    public static func parse(_ arguments: [String]) throws -> Self {
        switch arguments {
        case []:
            return Self(includeDeviceControls: false)
        case ["--include-device-controls"]:
            return Self(includeDeviceControls: true)
        default:
            throw AudioNativePreflightArgumentError.unsupportedArguments(arguments)
        }
    }
}

public enum AudioNativePreflightArgumentError: LocalizedError, Equatable, Sendable {
    case unsupportedArguments([String])

    public var errorDescription: String? {
        switch self {
        case .unsupportedArguments(let arguments):
            return "Unsupported arguments: \(arguments.joined(separator: " "))"
        }
    }
}

private enum AudioNativePreflightCollectionError: LocalizedError {
    case osBuildUnavailable
    case processDiscoveryGateUnavailable

    var errorDescription: String? {
        switch self {
        case .osBuildUnavailable:
            return "Unable to read the exact current OS build"
        case .processDiscoveryGateUnavailable:
            return "The read-only process-discovery availability gate is unavailable"
        }
    }
}
