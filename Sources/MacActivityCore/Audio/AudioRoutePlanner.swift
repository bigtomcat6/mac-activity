import CoreAudio
import Foundation

public struct AudioRoutePlanner: Sendable {
    public static let ownedUIDPrefix = "com.how.macactivity.audio."
    public static let aggregateUIDPrefix = "com.how.macactivity.audio.aggregate."

    private let policy: AudioRouteNativeValidationPolicy
    private let osBuildProvider: @Sendable () throws -> String

    public init(policy: AudioRouteNativeValidationPolicy = .conservative) {
        self.policy = policy
        self.osBuildProvider = AudioRouteOSBuild.current
    }

    init(
        policy: AudioRouteNativeValidationPolicy,
        osBuildProvider: @escaping @Sendable () throws -> String
    ) {
        self.policy = policy
        self.osBuildProvider = osBuildProvider
    }

    public func topologyFingerprint(
        for request: AudioRouteRequest
    ) throws -> AudioRouteTopologyFingerprint {
        try candidate(for: request).topologyFingerprint
    }

    public func permits(_ request: AudioRouteRequest) -> Bool {
        guard let fingerprint = try? topologyFingerprint(for: request) else { return false }
        return policy.permits(fingerprint)
    }

    public func plan(_ request: AudioRouteRequest) throws -> AudioRoutePlan {
        let candidate = try candidate(for: request)
        guard policy.permits(candidate.topologyFingerprint) else {
            throw AudioRoutePlanningError.nativeValidationRequired(
                candidate.topologyFingerprint
            )
        }

        return AudioRoutePlan(
            processObjectID: request.processObjectID,
            generation: request.generation,
            tapSources: candidate.tapSources,
            selectedTargetUIDs: candidate.selectedUIDs,
            subdevices: candidate.subdevices,
            mainDeviceUID: candidate.mainDeviceUID,
            isStacked: candidate.isStacked,
            aggregateUID: Self.aggregateUIDPrefix
                + "\(request.processObjectID).\(request.generation)",
            topologyFingerprint: candidate.topologyFingerprint
        )
    }
}

private extension AudioRoutePlanner {
    struct Candidate {
        let selectedUIDs: [String]
        let tapSources: [AudioTapSource]
        let subdevices: [AudioRouteSubdevice]
        let mainDeviceUID: String
        let isStacked: Bool
        let topologyFingerprint: AudioRouteTopologyFingerprint
    }

    func candidate(for request: AudioRouteRequest) throws -> Candidate {
        let devicesByUID = try indexedDevices(request.devices)
        let sourceUIDs = stableUnique(request.sourceDeviceUIDs)
        let sourceLeafUIDs = try stableUnique(sourceUIDs.flatMap {
            try flatten(uid: $0, devicesByUID: devicesByUID)
        })
        let selectedUIDs = try selectedUIDs(for: request)
        let flattenedUIDs = try stableUnique(selectedUIDs.flatMap {
            try flatten(uid: $0, devicesByUID: devicesByUID)
        })
        let participatingUIDs = stableUnique(
            sourceUIDs + sourceLeafUIDs + selectedUIDs + flattenedUIDs
        )
        try validateStreamIdentities(
            participatingUIDs,
            devicesByUID: devicesByUID
        )
        try validateTargets(flattenedUIDs, devicesByUID: devicesByUID)

        let mainDeviceUID = try mainDeviceUID(
            selectedUIDs: selectedUIDs,
            flattenedUIDs: flattenedUIDs,
            devicesByUID: devicesByUID
        )
        guard let mainDevice = devicesByUID[mainDeviceUID] else {
            throw AudioRoutePlanningError.unsupportedTopology
        }

        let tapSources = try buildTapSources(
            sourceDeviceUIDs: sourceUIDs,
            mainDevice: mainDevice,
            devicesByUID: devicesByUID
        )
        guard tapSources.count == 1 else {
            throw AudioRoutePlanningError.unsupportedTopology
        }

        let subdevices = try flattenedUIDs.map { uid in
            guard let device = devicesByUID[uid] else {
                throw AudioRoutePlanningError.missingDevice(uid)
            }
            return AudioRouteSubdevice(
                uid: uid,
                driftCompensation: subdeviceDrift(
                    device: device,
                    mainDevice: mainDevice
                ),
                inputStreams: device.inputStreams,
                outputStreams: device.outputStreams
            )
        }
        let isStacked = selectedUIDs.count > 1
            || flattenedUIDs.count > 1
            || flattenedUIDs.contains { uid in
                (devicesByUID[uid]?.outputStreams.count ?? 0) > 1
            }
        let fingerprint = try fingerprint(
            sourceUIDs: sourceUIDs,
            sourceLeafUIDs: sourceLeafUIDs,
            selectedUIDs: selectedUIDs,
            flattenedUIDs: flattenedUIDs,
            devicesByUID: devicesByUID
        )

        return Candidate(
            selectedUIDs: selectedUIDs,
            tapSources: tapSources,
            subdevices: subdevices,
            mainDeviceUID: mainDeviceUID,
            isStacked: isStacked,
            topologyFingerprint: fingerprint
        )
    }

    func indexedDevices(
        _ devices: [AudioRouteDevice]
    ) throws -> [String: AudioRouteDevice] {
        var devicesByUID: [String: AudioRouteDevice] = [:]
        for device in devices {
            guard devicesByUID.updateValue(device, forKey: device.uid) == nil else {
                throw AudioRoutePlanningError.unsupportedTopology
            }
        }
        return devicesByUID
    }

    func selectedUIDs(for request: AudioRouteRequest) throws -> [String] {
        switch request.mode {
        case .followOriginal:
            let values = stableUnique(request.sourceDeviceUIDs)
            guard values.isEmpty == false else {
                throw AudioRoutePlanningError.noSourceRoute
            }
            return values
        case .explicit(let targetDeviceUIDs):
            let values = stableUnique(targetDeviceUIDs)
            guard values.isEmpty == false else {
                throw AudioRoutePlanningError.emptyExplicitTargets
            }
            return values
        }
    }

    func flatten(
        uid: String,
        devicesByUID: [String: AudioRouteDevice]
    ) throws -> [String] {
        guard uid.hasPrefix(Self.ownedUIDPrefix) == false else {
            throw AudioRoutePlanningError.macActivityAggregateSelected(uid)
        }
        guard let device = devicesByUID[uid] else {
            throw AudioRoutePlanningError.missingDevice(uid)
        }
        guard device.isAlive else {
            throw AudioRoutePlanningError.unavailableDevice(uid)
        }
        guard device.isAggregate else { return [uid] }
        guard let composition = device.aggregateComposition,
              composition.fullSubdeviceUIDs.isEmpty == false,
              Set(composition.fullSubdeviceUIDs).count == composition.fullSubdeviceUIDs.count,
              Set(composition.activeSubdeviceUIDs).count
                == composition.activeSubdeviceUIDs.count,
              Set(composition.activeSubdeviceUIDs)
                == Set(composition.fullSubdeviceUIDs),
              let mainUID = composition.mainSubdeviceUID,
              composition.fullSubdeviceUIDs.contains(mainUID),
              composition.isStacked != nil,
              composition.tapUUIDs.isEmpty
        else {
            throw AudioRoutePlanningError.unsupportedTopology
        }

        for childUID in composition.fullSubdeviceUIDs {
            guard childUID.hasPrefix(Self.ownedUIDPrefix) == false else {
                throw AudioRoutePlanningError.macActivityAggregateSelected(childUID)
            }
            guard let child = devicesByUID[childUID],
                  child.isAlive,
                  child.isAggregate == false
            else {
                throw AudioRoutePlanningError.unsupportedTopology
            }
        }
        return composition.fullSubdeviceUIDs
    }

    func mainDeviceUID(
        selectedUIDs: [String],
        flattenedUIDs: [String],
        devicesByUID: [String: AudioRouteDevice]
    ) throws -> String {
        guard let selectedUID = selectedUIDs.first,
              let selected = devicesByUID[selectedUID]
        else {
            throw AudioRoutePlanningError.unsupportedTopology
        }
        let mainUID: String
        if selected.isAggregate {
            guard let aggregateMain = selected.aggregateComposition?.mainSubdeviceUID else {
                throw AudioRoutePlanningError.unsupportedTopology
            }
            mainUID = aggregateMain
        } else {
            mainUID = selectedUID
        }
        guard flattenedUIDs.contains(mainUID) else {
            throw AudioRoutePlanningError.unsupportedTopology
        }
        return mainUID
    }

    func buildTapSources(
        sourceDeviceUIDs: [String],
        mainDevice: AudioRouteDevice,
        devicesByUID: [String: AudioRouteDevice]
    ) throws -> [AudioTapSource] {
        try sourceDeviceUIDs.flatMap { uid -> [AudioTapSource] in
            guard let device = devicesByUID[uid] else {
                throw AudioRoutePlanningError.missingDevice(uid)
            }
            guard device.isAlive else {
                throw AudioRoutePlanningError.unavailableDevice(uid)
            }
            return try device.outputStreams.map { stream in
                guard stream.format.isSupportedFloat32LinearPCM else {
                    throw AudioRoutePlanningError.unsupportedFormat(
                        deviceUID: uid,
                        streamIndex: stream.streamIndex
                    )
                }
                return AudioTapSource(
                    deviceUID: uid,
                    streamIndex: stream.streamIndex,
                    expectedFormat: stream.format,
                    driftCompensation: subTapDrift(
                        sourceDevice: device,
                        mainDevice: mainDevice
                    )
                )
            }
        }
    }

    func subdeviceDrift(
        device: AudioRouteDevice,
        mainDevice: AudioRouteDevice
    ) -> AudioRouteDriftCompensation {
        if device.uid == mainDevice.uid || sharesKnownClock(device, mainDevice) {
            return .disabled
        }
        return .highQuality
    }

    func subTapDrift(
        sourceDevice: AudioRouteDevice,
        mainDevice: AudioRouteDevice
    ) -> AudioRouteDriftCompensation {
        if sourceDevice.uid == mainDevice.uid
            || sharesKnownClock(sourceDevice, mainDevice)
            || sourceDevice.transportType == kAudioDeviceTransportTypeVirtual
            || mainDevice.transportType == kAudioDeviceTransportTypeBluetooth
            || mainDevice.transportType == kAudioDeviceTransportTypeBluetoothLE {
            return .disabled
        }
        return .highQuality
    }

    func sharesKnownClock(
        _ lhs: AudioRouteDevice,
        _ rhs: AudioRouteDevice
    ) -> Bool {
        guard let lhsClock = lhs.clockDomain,
              let rhsClock = rhs.clockDomain,
              lhsClock != 0,
              rhsClock != 0
        else {
            return false
        }
        return lhsClock == rhsClock
    }

    func fingerprint(
        sourceUIDs: [String],
        sourceLeafUIDs: [String],
        selectedUIDs: [String],
        flattenedUIDs: [String],
        devicesByUID: [String: AudioRouteDevice]
    ) throws -> AudioRouteTopologyFingerprint {
        let osBuild: String
        do {
            osBuild = try osBuildProvider()
        } catch {
            throw AudioRoutePlanningError.unsupportedTopology
        }
        guard osBuild.isEmpty == false else {
            throw AudioRoutePlanningError.unsupportedTopology
        }
        let orderedUIDs = stableUnique(
            sourceUIDs + sourceLeafUIDs + selectedUIDs + flattenedUIDs
        )
        let fingerprints = try orderedUIDs.map { uid in
            guard let device = devicesByUID[uid] else {
                throw AudioRoutePlanningError.missingDevice(uid)
            }
            let composition = device.aggregateComposition
            return AudioRouteDeviceFingerprint(
                uid: device.uid,
                modelUID: device.modelUID,
                driverIdentity: device.driverIdentity,
                inputStreams: device.inputStreams,
                outputStreams: device.outputStreams,
                fullSubdeviceUIDs: composition?.fullSubdeviceUIDs ?? [],
                activeSubdeviceUIDs: composition?.activeSubdeviceUIDs.sorted() ?? [],
                aggregateMainSubdeviceUID: composition?.mainSubdeviceUID,
                aggregateIsStacked: composition?.isStacked,
                aggregateTapUUIDs: composition?.tapUUIDs ?? [],
                clockDomain: device.clockDomain,
                transportType: device.transportType,
                isAlive: device.isAlive
            )
        }
        return AudioRouteTopologyFingerprint(
            osBuild: osBuild,
            sourceDeviceUIDs: sourceUIDs,
            selectedTargetUIDs: selectedUIDs,
            devices: fingerprints
        )
    }

    func validateStreamIdentities(
        _ deviceUIDs: [String],
        devicesByUID: [String: AudioRouteDevice]
    ) throws {
        var streamObjectIDs: Set<AudioStreamID> = []
        for uid in deviceUIDs {
            guard let device = devicesByUID[uid] else {
                throw AudioRoutePlanningError.missingDevice(uid)
            }
            try validateStreamIdentities(
                device.inputStreams,
                objectIDs: &streamObjectIDs
            )
            try validateStreamIdentities(
                device.outputStreams,
                objectIDs: &streamObjectIDs
            )
        }
    }

    func validateStreamIdentities(
        _ streams: [AudioRouteStream],
        objectIDs: inout Set<AudioStreamID>
    ) throws {
        guard Set(streams.map(\.streamIndex)).count == streams.count else {
            throw AudioRoutePlanningError.unsupportedTopology
        }
        for stream in streams {
            guard stream.streamObjectID != kAudioObjectUnknown,
                  objectIDs.insert(stream.streamObjectID).inserted
            else {
                throw AudioRoutePlanningError.unsupportedTopology
            }
        }
    }

    func stableUnique(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            if result.contains(value) == false {
                result.append(value)
            }
        }
    }

    func validateTargets(
        _ targetUIDs: [String],
        devicesByUID: [String: AudioRouteDevice]
    ) throws {
        guard let clockUID = targetUIDs.first,
              let clockDevice = devicesByUID[clockUID]
        else {
            throw AudioRoutePlanningError.unsupportedTopology
        }

        for uid in targetUIDs {
            guard let device = devicesByUID[uid] else {
                throw AudioRoutePlanningError.missingDevice(uid)
            }
            try validateTargetFormats(device)
        }

        guard let clockSampleRate = clockDevice.outputStreams.first?.format.sampleRate else {
            throw AudioRoutePlanningError.incompatibleTarget(deviceUID: clockUID)
        }
        for uid in targetUIDs {
            guard let device = devicesByUID[uid] else {
                throw AudioRoutePlanningError.missingDevice(uid)
            }
            guard device.outputStreams.allSatisfy({
                abs($0.format.sampleRate - clockSampleRate) <= 0.5
            }) else {
                throw AudioRoutePlanningError.incompatibleTarget(deviceUID: uid)
            }
        }
    }

    func validateTargetFormats(_ device: AudioRouteDevice) throws {
        guard device.outputStreams.isEmpty == false else {
            throw AudioRoutePlanningError.incompatibleTarget(deviceUID: device.uid)
        }
        for stream in device.outputStreams {
            guard stream.format.isSupportedFloat32LinearPCM else {
                throw AudioRoutePlanningError.unsupportedFormat(
                    deviceUID: device.uid,
                    streamIndex: stream.streamIndex
                )
            }
        }
    }
}
