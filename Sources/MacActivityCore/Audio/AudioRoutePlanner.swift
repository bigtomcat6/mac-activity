import Foundation

public struct AudioRoutePlanner: Sendable {
    public static let ownedUIDPrefix = "com.how.macactivity.audio."
    public static let aggregateUIDPrefix = "com.how.macactivity.audio.aggregate."

    public init() {}

    public func plan(_ request: AudioRouteRequest) throws -> AudioRoutePlan {
        let devicesByUID = Dictionary(
            uniqueKeysWithValues: request.devices.map { ($0.uid, $0) }
        )
        let selectedUIDs: [String]
        switch request.mode {
        case .followOriginal:
            selectedUIDs = stableUnique(request.sourceDeviceUIDs)
            guard selectedUIDs.isEmpty == false else {
                throw AudioRoutePlanningError.noSourceRoute
            }
        case .explicit(let targetDeviceUIDs):
            selectedUIDs = stableUnique(targetDeviceUIDs)
            guard selectedUIDs.isEmpty == false else {
                throw AudioRoutePlanningError.emptyExplicitTargets
            }
        }

        let flattenedUIDs = try stableUnique(selectedUIDs.flatMap {
            try flatten(uid: $0, devicesByUID: devicesByUID, path: [])
        })
        try validateTargets(flattenedUIDs, devicesByUID: devicesByUID)

        let subdevices = flattenedUIDs.enumerated().map {
            AudioRouteSubdevice(
                uid: $0.element,
                usesDriftCompensation: $0.offset != 0
            )
        }

        let tapSources = try stableUnique(request.sourceDeviceUIDs).flatMap { uid -> [AudioTapSource] in
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
                    expectedFormat: stream.format
                )
            }
        }
        guard tapSources.isEmpty == false else {
            throw AudioRoutePlanningError.noSourceRoute
        }

        return AudioRoutePlan(
            processObjectID: request.processObjectID,
            generation: request.generation,
            tapSources: tapSources,
            selectedTargetUIDs: selectedUIDs,
            subdevices: subdevices,
            clockDeviceUID: flattenedUIDs[0],
            isStacked: true,
            aggregateUID: Self.aggregateUIDPrefix
                + "\(request.processObjectID).\(request.generation)"
        )
    }
}

private extension AudioRoutePlanner {
    func stableUnique(_ values: [String]) -> [String] {
        values.reduce(into: []) { result, value in
            if result.contains(value) == false {
                result.append(value)
            }
        }
    }

    func flatten(
        uid: String,
        devicesByUID: [String: AudioRouteDevice],
        path: [String]
    ) throws -> [String] {
        guard uid.hasPrefix(Self.ownedUIDPrefix) == false else {
            throw AudioRoutePlanningError.macActivityAggregateSelected(uid)
        }
        guard path.contains(uid) == false else {
            throw AudioRoutePlanningError.recursiveAggregate(uid)
        }
        guard let device = devicesByUID[uid] else {
            throw AudioRoutePlanningError.missingDevice(uid)
        }
        guard device.isAlive else {
            throw AudioRoutePlanningError.unavailableDevice(uid)
        }
        guard device.isAggregate else { return [uid] }
        guard device.aggregateSubdeviceUIDs.isEmpty == false else {
            throw AudioRoutePlanningError.missingDevice(uid)
        }
        return try device.aggregateSubdeviceUIDs.flatMap {
            try flatten(
                uid: $0,
                devicesByUID: devicesByUID,
                path: path + [uid]
            )
        }
    }

    func validateTargets(
        _ targetUIDs: [String],
        devicesByUID: [String: AudioRouteDevice]
    ) throws {
        guard let clockUID = targetUIDs.first,
              let clockDevice = devicesByUID[clockUID]
        else {
            return
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
