import AppKit
import CoreAudio
import Darwin
import Foundation
import MacActivityCore

@MainActor
public struct AudioNativePreflightCollector {
    private static let internalDeviceUIDPrefix = "com.how.macactivity.audio."

    public init() {}

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
        let deviceService = AudioDeviceVolumeService()
        let routeDevices = try deviceService.routeDevices().filter {
            !$0.uid.hasPrefix(Self.internalDeviceUIDPrefix)
        }
        let controlSnapshots = try deviceService.outputDeviceSnapshots()
        let controlsByUID = controlSnapshots.reduce(
            into: [String: AudioOutputDeviceSnapshot]()
        ) { result, snapshot in
            result[snapshot.id] = snapshot
        }
        let formatAddress = AudioHALPropertyAddress(
            selector: kAudioStreamPropertyVirtualFormat
        )
        let deviceObservations = try routeDevices.map { routeDevice in
            guard let controls = controlsByUID[routeDevice.uid] else {
                throw AudioNativePreflightCollectionError.missingControlSnapshot(
                    uid: routeDevice.uid
                )
            }
            return try AudioNativePreflightDeviceObservation(
                routeDevice: routeDevice,
                controlSnapshot: controls,
                exactFormat: { streamID in
                    try client.readScalar(
                        AudioStreamBasicDescription.self,
                        from: streamID,
                        address: formatAddress
                    )
                }
            )
        }

        let processPolicy = AudioRouteNativeValidationPolicy(
            validatedFingerprints: [Self.impossibleReadOnlyFingerprint]
        )
        let processAvailability = AudioFeatureAvailability(
            operatingSystemVersion: operatingSystemVersion,
            nativeValidationPolicy: processPolicy
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
    static let impossibleReadOnlyFingerprint = AudioRouteTopologyFingerprint(
        osBuild: "__AudioNativePreflight_Impossible_OS_Build__",
        sourceDeviceUIDs: ["__AudioNativePreflight_Impossible_Source_UID__"],
        selectedTargetUIDs: ["__AudioNativePreflight_Impossible_Target_UID__"],
        devices: []
    )

    static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
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

private enum AudioNativePreflightCollectionError: LocalizedError {
    case missingControlSnapshot(uid: String)
    case osBuildUnavailable
    case processDiscoveryGateUnavailable

    var errorDescription: String? {
        switch self {
        case .missingControlSnapshot(let uid):
            return "Output device changed during preflight; missing capability snapshot for \(uid)"
        case .osBuildUnavailable:
            return "Unable to read the exact current OS build"
        case .processDiscoveryGateUnavailable:
            return "The read-only process-discovery availability gate is unavailable"
        }
    }
}
