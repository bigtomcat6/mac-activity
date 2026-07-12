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
    let aggregateUID: String
    let ioProcID: AudioDeviceIOProcID
}

struct AudioOwnedObject: Equatable, Sendable {
    let id: AudioObjectID
    let classID: AudioClassID
    let uid: String
    let name: String?
}

struct AudioOwnedObjectDiscovery: Sendable {
    let objects: [AudioOwnedObject]
    let failures: [AudioTeardownFailure]
}

enum AudioTapHardwareError: Error, Equatable, Sendable {
    case aggregateNotReady(lastStatus: OSStatus?)
    case cancelled
}

final class CoreAudioTapHardware: AudioTapHardware, @unchecked Sendable {
    enum ValidationError: Error, Equatable, Sendable {
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
        tapUUID: UUID
    ) throws -> CFDictionary {
        let topology = try AudioAggregateTopologyResolver.plannedTopology(for: plan)
        let subdevices: [[String: Any]] = plan.subdevices.enumerated().map {
            index, subdevice in
            let usesDriftCompensation = subdevice.driftCompensation != .disabled
            var description: [String: Any] = [
                kAudioSubDeviceUIDKey: subdevice.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: topology.outputChannelCounts[index],
                kAudioSubDeviceDriftCompensationKey: usesDriftCompensation,
            ]
            if usesDriftCompensation {
                description[kAudioSubDeviceDriftCompensationQualityKey] =
                    kAudioAggregateDriftCompensationHighQuality
            }
            return description
        }
        let source = plan.tapSources[0]
        let usesSubTapDriftCompensation = source.driftCompensation != .disabled
        var tap: [String: Any] = [
            kAudioSubTapUIDKey: tapUUID.uuidString,
            kAudioSubTapDriftCompensationKey: usesSubTapDriftCompensation,
        ]
        if usesSubTapDriftCompensation {
            tap[kAudioSubTapDriftCompensationQualityKey] =
                kAudioAggregateDriftCompensationHighQuality
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey:
                "MacActivity Audio Aggregate \(plan.processObjectID).\(plan.generation)",
            kAudioAggregateDeviceUIDKey: plan.aggregateUID,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceMainSubDeviceKey: plan.mainDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: plan.isStacked,
            kAudioAggregateDeviceTapListKey: [tap],
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
        guard taps.count == 1,
              plan.tapSources.count == 1,
              taps[0].source == plan.tapSources[0]
        else {
            throw ValidationError.tapResourcesMismatch
        }
        guard #available(macOS 14.2, *) else {
            throw AudioHALError(
                operation: .createAggregate,
                objectID: kAudioObjectUnknown,
                address: nil,
                reason: .processTapsUnavailable
            )
        }

        let description = try Self.aggregateDescription(
            plan: plan,
            tapUUID: taps[0].uuid
        )
        let objectID = try hal.createAggregateDevice(description)
        return AudioAggregateResource(objectID: objectID, uid: plan.aggregateUID)
    }

    func waitForStableTopology(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AudioAggregateTopologySnapshot {
        var previous: AudioAggregateTopologySnapshot?
        var lastStatus: OSStatus?
        while true {
            if isCancelled() { throw AudioTapHardwareError.cancelled }
            guard DispatchTime.now() < deadline else {
                throw AudioTapHardwareError.aggregateNotReady(lastStatus: lastStatus)
            }
            do {
                let snapshot = try readTopologySnapshot(aggregate)
                guard snapshot.isAlive,
                      snapshot.inputStreamIDs.isEmpty == false,
                      snapshot.outputStreamIDs.isEmpty == false,
                      snapshot.inputFormats.count == snapshot.inputStreamIDs.count,
                      snapshot.outputFormats.count == snapshot.outputStreamIDs.count,
                      snapshot.tapUUIDs.isEmpty == false,
                      snapshot.activeSubTapIDs.isEmpty == false
                else {
                    previous = nil
                    continueAfterReadinessPoll(deadline: deadline)
                    continue
                }
                if previous == snapshot { return snapshot }
                previous = snapshot
                lastStatus = nil
            } catch {
                previous = nil
                lastStatus = rawStatus(from: error)
            }
            if isCancelled() { throw AudioTapHardwareError.cancelled }
            continueAfterReadinessPoll(deadline: deadline)
        }
    }

    func configureInputStreamUsage(
        _ usage: [UInt32],
        for ioProc: AudioIOProcResource
    ) throws -> [UInt32] {
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyIOProcStreamUsage,
            scope: kAudioObjectPropertyScopeInput
        )
        guard hal.hasProperty(objectID: ioProc.aggregateDeviceID, address: address) else {
            throw AudioIOProcStreamUsageError.propertyMissing
        }
        do {
            guard try hal.isPropertySettable(
                objectID: ioProc.aggregateDeviceID,
                address: address
            ) else {
                throw AudioIOProcStreamUsageError.propertyNotSettable
            }
        } catch let error as AudioIOProcStreamUsageError {
            throw error
        } catch {
            throw AudioIOProcStreamUsageError.writeFailed(rawStatus(from: error) ?? -1)
        }
        do {
            try hal.writeIOProcStreamUsage(
                usage,
                deviceID: ioProc.aggregateDeviceID,
                ioProcID: ioProc.ioProcID,
                scope: kAudioObjectPropertyScopeInput
            )
        } catch {
            throw AudioIOProcStreamUsageError.writeFailed(rawStatus(from: error) ?? -1)
        }
        let verified: [UInt32]
        do {
            verified = try hal.readIOProcStreamUsage(
                streamCount: usage.count,
                deviceID: ioProc.aggregateDeviceID,
                ioProcID: ioProc.ioProcID,
                scope: kAudioObjectPropertyScopeInput
            )
        } catch let error as AudioIOProcStreamUsageError {
            throw error
        } catch {
            throw AudioIOProcStreamUsageError.readFailed(rawStatus(from: error) ?? -1)
        }
        guard verified == usage else {
            throw AudioIOProcStreamUsageError.flagsMismatch
        }
        return verified
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
            aggregateUID: aggregate.uid,
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
        guard try currentIdentityMatches(
            objectID: tap.objectID,
            classID: kAudioTapClassID,
            uid: tap.uuid.uuidString
        ) else {
            throw AudioHALError(
                operation: .setData,
                objectID: tap.objectID,
                address: nil,
                reason: .missingValue
            )
        }
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

    func restoreOriginalAudio(for tap: AudioTapResource) -> OSStatus {
        teardownStatus {
            guard try currentIdentityMatches(
                objectID: tap.objectID,
                classID: kAudioTapClassID,
                uid: tap.uuid.uuidString
            ) else { return }
            let address = AudioHALPropertyAddress(selector: kAudioTapPropertyDescription)
            let description = try hal.readRetainedObject(
                CATapDescription.self,
                from: tap.objectID,
                address: address
            )
            description.muteBehavior = .unmuted
            try hal.writeObject(description, to: tap.objectID, address: address)
        }
    }

    func stop(_ ioProc: AudioIOProcResource) -> OSStatus {
        teardownStatus {
            guard try currentIdentityMatches(
                objectID: ioProc.aggregateDeviceID,
                classID: kAudioAggregateDeviceClassID,
                uid: ioProc.aggregateUID
            ) else { return }
            try hal.stopDevice(
                deviceID: ioProc.aggregateDeviceID,
                ioProcID: ioProc.ioProcID
            )
        }
    }

    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus {
        teardownStatus {
            guard try currentIdentityMatches(
                objectID: ioProc.aggregateDeviceID,
                classID: kAudioAggregateDeviceClassID,
                uid: ioProc.aggregateUID
            ) else { return }
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

    func ownedObjects() throws -> AudioOwnedObjectDiscovery {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let deviceIDs = try hal.readArray(
            AudioDeviceID.self,
            from: systemObject,
            address: AudioHALPropertyAddress(
                selector: kAudioHardwarePropertyDevices
            )
        )
        var objectIDs = deviceIDs

        if #available(macOS 14.2, *) {
            let tapIDs = try hal.readArray(
                AudioObjectID.self,
                from: systemObject,
                address: AudioHALPropertyAddress(
                    selector: kAudioHardwarePropertyTapList
                )
            )
            objectIDs.append(contentsOf: tapIDs)
        }
        var objects: [AudioOwnedObject] = []
        var failures: [AudioTeardownFailure] = []
        for objectID in objectIDs {
            do {
                objects.append(try readOwnedObject(objectID))
            } catch {
                failures.append(AudioTeardownFailure(
                    processObjectID: nil,
                    operation: .getData,
                    objectID: objectID,
                    status: rawStatus(from: error) ?? kAudioHardwareUnspecifiedError
                ))
            }
        }
        return AudioOwnedObjectDiscovery(objects: objects, failures: failures)
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
        let name = try? hal.readRetainedString(
            from: objectID,
            address: AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
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
            if error.status == kAudioHardwareBadObjectError
                || error.status == kAudioHardwareUnknownPropertyError {
                return noErr
            }
            return error.status ?? kAudioHardwareUnspecifiedError
        } catch {
            return kAudioHardwareUnspecifiedError
        }
    }

    private func readTopologySnapshot(
        _ aggregate: AudioAggregateResource
    ) throws -> AudioAggregateTopologySnapshot {
        let inputStreamIDs = try hal.readArray(
            AudioStreamID.self,
            from: aggregate.objectID,
            address: .init(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeInput
            )
        )
        let outputStreamIDs = try hal.readArray(
            AudioStreamID.self,
            from: aggregate.objectID,
            address: .init(
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput
            )
        )
        let formatAddress = AudioHALPropertyAddress(selector: kAudioStreamPropertyVirtualFormat)
        let tapValues = try hal.readRetainedObject(
            CFArray.self,
            from: aggregate.objectID,
            address: .init(selector: kAudioAggregateDevicePropertyTapList)
        )
        let tapUUIDs = try (tapValues as NSArray).map { value -> UUID in
            guard let string = value as? String, let uuid = UUID(uuidString: string) else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            return uuid
        }
        return AudioAggregateTopologySnapshot(
            isAlive: try hal.readScalar(
                UInt32.self,
                from: aggregate.objectID,
                address: .init(selector: kAudioDevicePropertyDeviceIsAlive)
            ) != 0,
            inputStreamIDs: inputStreamIDs,
            inputFormats: try inputStreamIDs.map { try readFormat(from: $0, address: formatAddress) },
            outputStreamIDs: outputStreamIDs,
            outputFormats: try outputStreamIDs.map { try readFormat(from: $0, address: formatAddress) },
            tapUUIDs: tapUUIDs,
            activeSubTapIDs: try hal.readArray(
                AudioObjectID.self,
                from: aggregate.objectID,
                address: .init(selector: kAudioAggregateDevicePropertySubTapList)
            )
        )
    }

    private func continueAfterReadinessPoll(deadline: DispatchTime) {
        let now = DispatchTime.now()
        guard now < deadline else { return }
        Thread.sleep(forTimeInterval: min(
            0.010,
            Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
        ))
    }

    private func rawStatus(from error: Error) -> OSStatus? {
        (error as? AudioHALError)?.status
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
    func waitForStableTopology(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AudioAggregateTopologySnapshot
    func createIOProc(
        aggregate: AudioAggregateResource,
        context: ProcessTapDSPContext
    ) throws -> AudioIOProcResource
    func start(_ ioProc: AudioIOProcResource) throws
    func configureInputStreamUsage(
        _ usage: [UInt32],
        for ioProc: AudioIOProcResource
    ) throws -> [UInt32]
    func setMuteState(
        _ state: AudioTapMuteState,
        for tap: AudioTapResource
    ) throws
    func restoreOriginalAudio(for tap: AudioTapResource) -> OSStatus
    func stop(_ ioProc: AudioIOProcResource) -> OSStatus
    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus
    func destroyAggregate(_ aggregate: AudioAggregateResource) -> OSStatus
    func destroyTap(_ tap: AudioTapResource) -> OSStatus
    func ownedObjects() throws -> AudioOwnedObjectDiscovery
    func destroyOwnedObject(_ object: AudioOwnedObject) -> OSStatus
}
