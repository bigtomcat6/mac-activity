import CoreAudio
import Foundation

enum AudioTapMuteState: Equatable, Sendable {
    case unmuted
    case mutedWhenTapped
}

struct AudioTapResource: Equatable, Sendable {
    let objectID: AudioObjectID
    let uuid: UUID
    let source: AudioTapSource
}

struct AudioAggregateResource: Equatable, Sendable {
    let objectID: AudioObjectID
    let uid: String
}

struct AudioIOProcResource: @unchecked Sendable {
    let aggregateDeviceID: AudioObjectID
    let ioProcID: AudioDeviceIOProcID
}

struct AudioOwnedObject: Equatable, Sendable {
    let id: AudioObjectID
    let classID: AudioClassID
    let uid: String
    let name: String
}

enum AudioTapHardwareError: Error, Equatable, Sendable {
    case aggregateNotReady
}

final class CoreAudioTapHardware: AudioTapHardware, @unchecked Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case actualTapFormatsMismatch
        case actualOutputFormatsMismatch
        case tapResourcesMismatch
    }

    private let hal: AudioHALClient

    init(hal: AudioHALClient = .system) {
        self.hal = hal
    }

    static func reservedTapUUID(entropy: UUID = UUID()) -> UUID {
        var bytes = entropy.uuid
        bytes.0 = 0x4D
        bytes.1 = 0x41
        bytes.2 = 0x43
        bytes.3 = 0x41
        return UUID(uuid: bytes)
    }

    @available(macOS 14.2, *)
    static func tapDescription(
        processObjectID: AudioObjectID,
        source: AudioTapSource,
        entropy: UUID = UUID()
    ) -> CATapDescription {
        let description = CATapDescription(
            processes: [processObjectID],
            deviceUID: source.deviceUID,
            stream: source.streamIndex
        )
        description.isPrivate = true
        description.isMixdown = false
        description.muteBehavior = .unmuted
        description.uuid = reservedTapUUID(entropy: entropy)
        description.name = "MacActivity Audio Tap \(description.uuid.uuidString)"
        return description
    }

    @available(macOS 14.2, *)
    static func aggregateDescription(
        plan: AudioRoutePlan,
        tapUUIDs: [UUID]
    ) -> CFDictionary {
        let subdevices: [[String: Any]] = plan.subdevices.map { subdevice in
            let usesDriftCompensation = subdevice.driftCompensation != .disabled
            var description: [String: Any] = [
                kAudioSubDeviceUIDKey: subdevice.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: subdevice.outputStreams.reduce(0) {
                    $0 + $1.format.channelCount
                },
                kAudioSubDeviceDriftCompensationKey: usesDriftCompensation,
            ]
            if usesDriftCompensation {
                description[kAudioSubDeviceDriftCompensationQualityKey] =
                    kAudioAggregateDriftCompensationHighQuality
            }
            return description
        }
        let taps: [[String: Any]] = zip(plan.tapSources, tapUUIDs).map { source, uuid in
            let usesDriftCompensation = source.driftCompensation != .disabled
            var description: [String: Any] = [
                kAudioSubTapUIDKey: uuid.uuidString,
                kAudioSubTapDriftCompensationKey: usesDriftCompensation,
            ]
            if usesDriftCompensation {
                description[kAudioSubTapDriftCompensationQualityKey] =
                    kAudioAggregateDriftCompensationHighQuality
            }
            return description
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey:
                "MacActivity Audio Aggregate \(plan.processObjectID).\(plan.generation)",
            kAudioAggregateDeviceUIDKey: plan.aggregateUID,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceMainSubDeviceKey: plan.mainDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: plan.isStacked,
            kAudioAggregateDeviceTapListKey: taps,
        ]
        return description as CFDictionary
    }

    @available(macOS 14.2, *)
    static func ownedOrphans(in objects: [AudioOwnedObject]) -> [AudioOwnedObject] {
        objects.filter { object in
            switch object.classID {
            case kAudioAggregateDeviceClassID:
                object.uid.hasPrefix(AudioRoutePlanner.aggregateUIDPrefix)
            case kAudioTapClassID:
                object.uid.hasPrefix("4D414341-")
            default:
                false
            }
        }
    }

    static func isAggregateReady(
        isAlive: Bool,
        inputStreamIDs: [AudioObjectID],
        outputStreamIDs: [AudioObjectID]
    ) -> Bool {
        isAlive && inputStreamIDs.isEmpty == false && outputStreamIDs.isEmpty == false
    }

    static func waitUntilReady(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        now: () -> TimeInterval,
        sleep: (TimeInterval) -> Void,
        isCancelled: () -> Bool = { false },
        probe: () throws -> Bool
    ) throws {
        let deadline = now() + max(0, timeout)

        while true {
            if isCancelled() { return }
            if try probe() { return }

            let remaining = deadline - now()
            guard remaining > 0,
                  pollInterval.isFinite,
                  pollInterval > 0
            else {
                throw AudioTapHardwareError.aggregateNotReady
            }

            if isCancelled() { return }
            sleep(min(pollInterval, remaining))
        }
    }

    static func validateActualTapFormats(
        plan: AudioRoutePlan,
        actualFormats: [ProcessTapAudioFormat]
    ) throws {
        guard actualFormats == plan.tapSources.map(\.expectedFormat) else {
            throw ValidationError.actualTapFormatsMismatch
        }
    }

    @available(macOS 14.2, *)
    static func destroyOwnedOrphans(
        in objects: [AudioOwnedObject],
        destroyAggregate: (AudioObjectID) -> OSStatus,
        destroyTap: (AudioObjectID) -> OSStatus
    ) -> [AudioTeardownFailure] {
        ownedOrphans(in: objects).compactMap { object in
            let operation: AudioHALOperation
            let status: OSStatus
            switch object.classID {
            case kAudioAggregateDeviceClassID:
                operation = .destroyAggregate
                status = destroyAggregate(object.id)
            case kAudioTapClassID:
                operation = .destroyTap
                status = destroyTap(object.id)
            default:
                return nil
            }

            guard status != noErr else { return nil }
            return AudioTeardownFailure(
                processObjectID: nil,
                operation: operation,
                objectID: object.id,
                status: status
            )
        }
    }

    func createTap(
        processObjectID: AudioObjectID,
        source: AudioTapSource,
        uuid: UUID
    ) throws -> AudioTapResource {
        guard #available(macOS 14.2, *) else {
            throw AudioHALError(
                operation: .createTap,
                objectID: kAudioObjectUnknown,
                address: nil,
                reason: .processTapsUnavailable
            )
        }

        let description = Self.tapDescription(
            processObjectID: processObjectID,
            source: source,
            entropy: uuid
        )
        let objectID = try hal.createProcessTap(description)
        return AudioTapResource(
            objectID: objectID,
            uuid: description.uuid,
            source: source
        )
    }

    func readTapFormat(_ tap: AudioTapResource) throws -> ProcessTapAudioFormat {
        try readFormat(
            from: tap.objectID,
            address: AudioHALPropertyAddress(selector: kAudioTapPropertyFormat)
        )
    }

    func createAggregate(
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateResource {
        guard #available(macOS 14.2, *) else {
            throw AudioHALError(
                operation: .createAggregate,
                objectID: kAudioObjectUnknown,
                address: nil,
                reason: .processTapsUnavailable
            )
        }

        let description = Self.aggregateDescription(
            plan: plan,
            tapUUIDs: taps.map(\.uuid)
        )
        let objectID = try hal.createAggregateDevice(description)
        return AudioAggregateResource(objectID: objectID, uid: plan.aggregateUID)
    }

    func waitUntilReady(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        let inputStreamsAddress = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        )
        let outputStreamsAddress = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        )

        while true {
            if isCancelled() { return }
            guard DispatchTime.now() < deadline else {
                throw AudioTapHardwareError.aggregateNotReady
            }

            if isCancelled() { return }
            let alive: UInt32 = try hal.readScalar(
                UInt32.self,
                from: aggregate.objectID,
                address: AudioHALPropertyAddress(
                    selector: kAudioDevicePropertyDeviceIsAlive
                )
            )
            if isCancelled() { return }
            let inputStreamIDs = try hal.readArray(
                AudioStreamID.self,
                from: aggregate.objectID,
                address: inputStreamsAddress
            )
            if isCancelled() { return }
            let outputStreamIDs = try hal.readArray(
                AudioStreamID.self,
                from: aggregate.objectID,
                address: outputStreamsAddress
            )

            if Self.isAggregateReady(
                isAlive: alive != 0,
                inputStreamIDs: inputStreamIDs,
                outputStreamIDs: outputStreamIDs
            ) {
                return
            }
            if isCancelled() { return }

            let now = DispatchTime.now()
            guard now < deadline else {
                throw AudioTapHardwareError.aggregateNotReady
            }
            let remainingNanoseconds = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            Thread.sleep(
                forTimeInterval: min(
                    0.010,
                    Double(remainingNanoseconds) / 1_000_000_000
                )
            )
        }
    }

    func readAggregateLayout(
        _ aggregate: AudioAggregateResource,
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateLayout {
        guard taps.count == 1,
              taps.map(\.source) == plan.tapSources,
              let tap = taps.first
        else {
            throw ValidationError.tapResourcesMismatch
        }

        let isAlive: UInt32 = try hal.readScalar(
            UInt32.self,
            from: aggregate.objectID,
            address: AudioHALPropertyAddress(
                selector: kAudioDevicePropertyDeviceIsAlive
            )
        )
        let inputStreamIDs = try hal.readArray(
            AudioStreamID.self,
            from: aggregate.objectID,
            address: AudioHALPropertyAddress(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeInput
            )
        )
        let outputStreamIDs = try hal.readArray(
            AudioStreamID.self,
            from: aggregate.objectID,
            address: AudioHALPropertyAddress(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput
            )
        )
        let formatAddress = AudioHALPropertyAddress(
            selector: kAudioStreamPropertyVirtualFormat
        )
        let actualInputFormats = try inputStreamIDs.map {
            try readFormat(from: $0, address: formatAddress)
        }
        let actualOutputFormats = try outputStreamIDs.map {
            try readFormat(from: $0, address: formatAddress)
        }
        let tapUUIDValues = try hal.readRetainedObject(
            CFArray.self,
            from: aggregate.objectID,
            address: AudioHALPropertyAddress(
                selector: kAudioAggregateDevicePropertyTapList
            )
        )
        let tapUUIDs = try (tapUUIDValues as NSArray).map { value in
            guard let string = value as? String,
                  let uuid = UUID(uuidString: string)
            else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            return uuid
        }
        let activeSubTapIDs = try hal.readArray(
            AudioObjectID.self,
            from: aggregate.objectID,
            address: AudioHALPropertyAddress(
                selector: kAudioAggregateDevicePropertySubTapList
            )
        )

        return try AudioAggregateTopologyResolver.resolve(
            plan: plan,
            tap: tap,
            snapshot: AudioAggregateTopologySnapshot(
                isAlive: isAlive != 0,
                inputStreamIDs: inputStreamIDs,
                inputFormats: actualInputFormats,
                outputStreamIDs: outputStreamIDs,
                outputFormats: actualOutputFormats,
                tapUUIDs: tapUUIDs,
                activeSubTapIDs: activeSubTapIDs
            )
        )
    }

    func createIOProc(
        aggregate: AudioAggregateResource,
        context: ProcessTapDSPContext
    ) throws -> AudioIOProcResource {
        let clientData = Unmanaged.passUnretained(context).toOpaque()
        let ioProcID = try withExtendedLifetime(context) {
            try hal.createIOProc(
                deviceID: aggregate.objectID,
                callback: coreAudioTapIOProc,
                clientData: clientData
            )
        }
        return AudioIOProcResource(
            aggregateDeviceID: aggregate.objectID,
            ioProcID: ioProcID
        )
    }

    func start(_ ioProc: AudioIOProcResource) throws {
        try hal.startDevice(
            deviceID: ioProc.aggregateDeviceID,
            ioProcID: ioProc.ioProcID
        )
    }

    func setMuteState(
        _ state: AudioTapMuteState,
        for tap: AudioTapResource
    ) throws {
        let address = AudioHALPropertyAddress(
            selector: kAudioTapPropertyDescription
        )
        let description = try hal.readRetainedObject(
            CATapDescription.self,
            from: tap.objectID,
            address: address
        )
        switch state {
        case .unmuted:
            description.muteBehavior = .unmuted
        case .mutedWhenTapped:
            description.muteBehavior = .mutedWhenTapped
        }
        try hal.writeObject(description, to: tap.objectID, address: address)
    }

    func stop(_ ioProc: AudioIOProcResource) -> OSStatus {
        teardownStatus {
            try hal.stopDevice(
                deviceID: ioProc.aggregateDeviceID,
                ioProcID: ioProc.ioProcID
            )
        }
    }

    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus {
        teardownStatus {
            try hal.destroyIOProc(
                deviceID: ioProc.aggregateDeviceID,
                ioProcID: ioProc.ioProcID
            )
        }
    }

    func destroyAggregate(_ aggregate: AudioAggregateResource) -> OSStatus {
        teardownStatus {
            guard try currentIdentityMatches(
                objectID: aggregate.objectID,
                classID: kAudioAggregateDeviceClassID,
                uid: aggregate.uid
            ) else {
                return
            }
            try hal.destroyAggregateDevice(aggregate.objectID)
        }
    }

    func destroyTap(_ tap: AudioTapResource) -> OSStatus {
        teardownStatus {
            guard try currentIdentityMatches(
                objectID: tap.objectID,
                classID: kAudioTapClassID,
                uid: tap.uuid.uuidString
            ) else {
                return
            }
            try hal.destroyProcessTap(tap.objectID)
        }
    }

    func destroyOwnedObject(_ object: AudioOwnedObject) -> OSStatus {
        if object.classID == kAudioAggregateDeviceClassID {
            return teardownStatus {
                guard try currentIdentityMatches(
                    objectID: object.id,
                    classID: object.classID,
                    uid: object.uid
                ) else {
                    return
                }
                try hal.destroyAggregateDevice(object.id)
            }
        }
        guard #available(macOS 14.2, *), object.classID == kAudioTapClassID else {
            return kAudioHardwareUnspecifiedError
        }
        return teardownStatus {
            guard try currentIdentityMatches(
                objectID: object.id,
                classID: object.classID,
                uid: object.uid
            ) else {
                return
            }
            try hal.destroyProcessTap(object.id)
        }
    }

    func ownedObjects() throws -> [AudioOwnedObject] {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let deviceIDs = try hal.readArray(
            AudioDeviceID.self,
            from: systemObject,
            address: AudioHALPropertyAddress(
                selector: kAudioHardwarePropertyDevices
            )
        )
        var objects = try deviceIDs.map { try readOwnedObject($0) }

        if #available(macOS 14.2, *) {
            let tapIDs = try hal.readArray(
                AudioObjectID.self,
                from: systemObject,
                address: AudioHALPropertyAddress(
                    selector: kAudioHardwarePropertyTapList
                )
            )
            objects.append(contentsOf: try tapIDs.map { try readOwnedObject($0) })
        }
        return objects
    }

    private func readFormat(
        from objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> ProcessTapAudioFormat {
        let asbd = try hal.readScalar(
            AudioStreamBasicDescription.self,
            from: objectID,
            address: address
        )
        let isNonInterleaved = asbd.mFormatFlags
            & kAudioFormatFlagIsNonInterleaved != 0
        return ProcessTapAudioFormat(
            sampleRate: asbd.mSampleRate,
            channelCount: Int(asbd.mChannelsPerFrame),
            formatID: asbd.mFormatID,
            formatFlags: asbd.mFormatFlags,
            bitsPerChannel: asbd.mBitsPerChannel,
            interleaving: isNonInterleaved ? .nonInterleaved : .interleaved
        )
    }

    private func readOwnedObject(
        _ objectID: AudioObjectID
    ) throws -> AudioOwnedObject {
        let classID = try hal.readScalar(
            AudioClassID.self,
            from: objectID,
            address: AudioHALPropertyAddress(
                selector: kAudioObjectPropertyClass
            )
        )
        let uidSelector: AudioObjectPropertySelector
        if #available(macOS 14.2, *), classID == kAudioTapClassID {
            uidSelector = kAudioTapPropertyUID
        } else {
            uidSelector = kAudioDevicePropertyDeviceUID
        }
        let uid = try hal.readRetainedString(
            from: objectID,
            address: AudioHALPropertyAddress(selector: uidSelector)
        )
        let name = try hal.readRetainedString(
            from: objectID,
            address: AudioHALPropertyAddress(
                selector: kAudioObjectPropertyName
            )
        )
        return AudioOwnedObject(
            id: objectID,
            classID: classID,
            uid: uid,
            name: name
        )
    }

    private func currentIdentityMatches(
        objectID: AudioObjectID,
        classID expectedClassID: AudioClassID,
        uid expectedUID: String
    ) throws -> Bool {
        let classAddress = AudioHALPropertyAddress(
            selector: kAudioObjectPropertyClass
        )
        guard hal.hasProperty(objectID: objectID, address: classAddress) else {
            return false
        }
        let currentClassID = try hal.readScalar(
            AudioClassID.self,
            from: objectID,
            address: classAddress
        )
        guard currentClassID == expectedClassID else {
            return false
        }

        let uidSelector: AudioObjectPropertySelector
        if #available(macOS 14.2, *), expectedClassID == kAudioTapClassID {
            uidSelector = kAudioTapPropertyUID
        } else {
            uidSelector = kAudioDevicePropertyDeviceUID
        }
        let currentUID = try hal.readRetainedString(
            from: objectID,
            address: AudioHALPropertyAddress(selector: uidSelector)
        )
        return currentUID == expectedUID
    }

    private func teardownStatus(_ body: () throws -> Void) -> OSStatus {
        do {
            try body()
            return noErr
        } catch let error as AudioHALError {
            return error.status ?? kAudioHardwareUnspecifiedError
        } catch {
            return kAudioHardwareUnspecifiedError
        }
    }

}

private let coreAudioTapIOProc: AudioDeviceIOProc = {
    _, _, inputData, _, outputData, _, clientData in
    guard let clientData else { return kAudioHardwareUnspecifiedError }
    let context = Unmanaged<ProcessTapDSPContext>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    context.process(input: inputData, output: outputData)
    context.markCallbackObserved()
    return noErr
}

protocol AudioTapHardware: AnyObject, Sendable {
    func createTap(
        processObjectID: AudioObjectID,
        source: AudioTapSource,
        uuid: UUID
    ) throws -> AudioTapResource
    func readTapFormat(_ tap: AudioTapResource) throws -> ProcessTapAudioFormat
    func createAggregate(
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateResource
    func waitUntilReady(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws
    func readAggregateLayout(
        _ aggregate: AudioAggregateResource,
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateLayout
    func createIOProc(
        aggregate: AudioAggregateResource,
        context: ProcessTapDSPContext
    ) throws -> AudioIOProcResource
    func start(_ ioProc: AudioIOProcResource) throws
    func setMuteState(
        _ state: AudioTapMuteState,
        for tap: AudioTapResource
    ) throws
    func stop(_ ioProc: AudioIOProcResource) -> OSStatus
    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus
    func destroyAggregate(_ aggregate: AudioAggregateResource) -> OSStatus
    func destroyTap(_ tap: AudioTapResource) -> OSStatus
    func ownedObjects() throws -> [AudioOwnedObject]
    func destroyOwnedObject(_ object: AudioOwnedObject) -> OSStatus
}
