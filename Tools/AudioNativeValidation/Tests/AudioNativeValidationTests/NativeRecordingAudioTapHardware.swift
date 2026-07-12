import CoreAudio
import Foundation
@testable import MacActivityCore

struct NativeRawFailure: Codable, Equatable, Sendable {
    let seam: String
    let status: OSStatus
}

struct NativeTapResourceObservation: Codable, Equatable, Sendable {
    let diagnosticOnlyObjectID: AudioObjectID
    let uuid: String
}

struct NativeTapFormatObservation: Codable, Equatable, Sendable {
    let diagnosticOnlyObjectID: AudioObjectID
    let format: ProcessTapAudioFormat
}

struct NativeAggregateResourceObservation: Codable, Equatable, Sendable {
    let diagnosticOnlyObjectID: AudioObjectID
    let uid: String
}

struct NativeIOProcResourceObservation: Codable, Equatable, Sendable {
    let diagnosticOnlyAggregateObjectID: AudioObjectID
    let diagnosticOnlyIOProcID: UInt64
}

struct NativeChannelAddressObservation: Codable, Equatable, Sendable {
    let bufferIndex: Int
    let channelIndex: Int
    let interleavedChannelCount: Int
}

struct NativeChannelMapObservation: Codable, Equatable, Sendable {
    let input: NativeChannelAddressObservation
    let output: NativeChannelAddressObservation
    let mixCoefficient: Float32
}

struct NativeDriftObservation: Codable, Equatable, Sendable {
    let kind: String
    let diagnosticOnlyObjectID: AudioObjectID
    let enabled: UInt32
    let quality: UInt32
}

struct NativeTopologyObservation: Codable, Equatable, Sendable {
    let isAlive: Bool
    let fullSubdeviceUIDs: [String]
    let diagnosticOnlyInputStreamIDs: [AudioStreamID]
    let inputFormats: [ProcessTapAudioFormat]
    let diagnosticOnlyOutputStreamIDs: [AudioStreamID]
    let outputFormats: [ProcessTapAudioFormat]
    let tapUUIDs: [String]
    let diagnosticOnlyActiveSubTapIDs: [AudioObjectID]
    let hasExactlyOneInput: Bool
    let outputABLFormats: [ProcessTapAudioFormat]
    let channelMaps: [NativeChannelMapObservation]
    let requestedInputStreamUsage: [UInt32]
    let drift: [NativeDriftObservation]
}

enum NativeRecordingError: Error {
    case missingPlanOrTap
    case missingDSPContext
}

final class NativeRecordingAudioTapHardware: AudioTapHardware, @unchecked Sendable {
    private let delegate = CoreAudioTapHardware(hal: .system)
    private let hal = AudioHALClient.system
    private weak var callbackContext: ProcessTapDSPContext?

    private(set) var taps: [NativeTapResourceObservation] = []
    private(set) var tapFormats: [NativeTapFormatObservation] = []
    private(set) var aggregate: NativeAggregateResourceObservation?
    private(set) var ioProc: NativeIOProcResourceObservation?
    private(set) var topology: NativeTopologyObservation?
    private(set) var verifiedInputStreamUsage: [UInt32] = []
    private(set) var callbackCountBeforeObservation: Int32?
    private(set) var callbackCountAfterObservation: Int32?
    private(set) var rawFailures: [NativeRawFailure] = []

    private var recordedPlan: AudioRoutePlan?
    private var recordedTap: AudioTapResource?

    func createTap(
        processObjectID: AudioObjectID,
        source: AudioTapSource,
        uuid: UUID
    ) throws -> AudioTapResource {
        do {
            let tap = try delegate.createTap(
                processObjectID: processObjectID,
                source: source,
                uuid: uuid
            )
            taps.append(NativeTapResourceObservation(
                diagnosticOnlyObjectID: tap.objectID,
                uuid: tap.uuid.uuidString
            ))
            return tap
        } catch {
            record(error, seam: "createTap")
            throw error
        }
    }

    func readTapFormat(_ tap: AudioTapResource) throws -> ProcessTapAudioFormat {
        do {
            let format = try delegate.readTapFormat(tap)
            tapFormats.append(NativeTapFormatObservation(
                diagnosticOnlyObjectID: tap.objectID,
                format: format
            ))
            return format
        } catch {
            record(error, seam: "readTapFormat")
            throw error
        }
    }

    func createAggregate(
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateResource {
        do {
            let resource = try delegate.createAggregate(plan: plan, taps: taps)
            recordedPlan = plan
            recordedTap = taps.count == 1 ? taps[0] : nil
            aggregate = NativeAggregateResourceObservation(
                diagnosticOnlyObjectID: resource.objectID,
                uid: resource.uid
            )
            return resource
        } catch {
            record(error, seam: "createAggregate")
            throw error
        }
    }

    func waitForStableTopology(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AudioAggregateTopologySnapshot {
        do {
            let snapshot = try delegate.waitForStableTopology(
                aggregate,
                deadline: deadline,
                isCancelled: isCancelled
            )
            guard let recordedPlan, let recordedTap else {
                throw NativeRecordingError.missingPlanOrTap
            }
            let layout = try AudioAggregateTopologyResolver.resolve(
                plan: recordedPlan,
                tap: recordedTap,
                snapshot: snapshot
            )
            let fullSubdeviceUIDs = try readFullSubdeviceUIDs(aggregate.objectID)
            let subdeviceIDs = try hal.readArray(
                AudioObjectID.self,
                from: aggregate.objectID,
                address: .init(selector: kAudioAggregateDevicePropertyActiveSubDeviceList)
            )
            let drift = try subdeviceIDs.map {
                try readDrift(kind: "subdevice", objectID: $0)
            } + snapshot.activeSubTapIDs.map {
                try readDrift(kind: "subtap", objectID: $0)
            }
            topology = NativeTopologyObservation(
                isAlive: snapshot.isAlive,
                fullSubdeviceUIDs: fullSubdeviceUIDs,
                diagnosticOnlyInputStreamIDs: snapshot.inputStreamIDs,
                inputFormats: snapshot.inputFormats,
                diagnosticOnlyOutputStreamIDs: snapshot.outputStreamIDs,
                outputFormats: snapshot.outputFormats,
                tapUUIDs: snapshot.tapUUIDs.map(\.uuidString),
                diagnosticOnlyActiveSubTapIDs: snapshot.activeSubTapIDs,
                hasExactlyOneInput: snapshot.inputStreamIDs.count == 1,
                outputABLFormats: layout.outputFormats,
                channelMaps: layout.channelMaps.map(NativeChannelMapObservation.init),
                requestedInputStreamUsage: layout.inputStreamUsage,
                drift: drift
            )
            return snapshot
        } catch {
            record(error, seam: "waitForStableTopology")
            throw error
        }
    }

    func createIOProc(
        aggregate: AudioAggregateResource,
        context: ProcessTapDSPContext
    ) throws -> AudioIOProcResource {
        do {
            let resource = try delegate.createIOProc(
                aggregate: aggregate,
                context: context
            )
            callbackContext = context
            ioProc = NativeIOProcResourceObservation(
                diagnosticOnlyAggregateObjectID: resource.aggregateDeviceID,
                diagnosticOnlyIOProcID: UInt64(UInt(bitPattern:
                    AudioIOProcStreamUsage.ioProcPointer(resource.ioProcID)
                ))
            )
            return resource
        } catch {
            record(error, seam: "createIOProc")
            throw error
        }
    }

    func start(_ ioProc: AudioIOProcResource) throws {
        do {
            try delegate.start(ioProc)
        } catch {
            record(error, seam: "startDevice")
            throw error
        }
    }

    func configureInputStreamUsage(
        _ usage: [UInt32],
        for ioProc: AudioIOProcResource
    ) throws -> [UInt32] {
        do {
            let verified = try delegate.configureInputStreamUsage(usage, for: ioProc)
            verifiedInputStreamUsage = verified
            return verified
        } catch {
            record(error, seam: "configureInputStreamUsage")
            throw error
        }
    }

    func setMuteState(_ state: AudioTapMuteState, for tap: AudioTapResource) throws {
        do {
            try delegate.setMuteState(state, for: tap)
        } catch {
            record(error, seam: "setMuteState")
            throw error
        }
    }

    func restoreOriginalAudio(for tap: AudioTapResource) -> OSStatus {
        record(delegate.restoreOriginalAudio(for: tap), seam: "restoreOriginalAudio")
    }

    func stop(_ ioProc: AudioIOProcResource) -> OSStatus {
        record(delegate.stop(ioProc), seam: "stopDevice")
    }

    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus {
        record(delegate.destroyIOProc(ioProc), seam: "destroyIOProc")
    }

    func destroyAggregate(_ aggregate: AudioAggregateResource) -> OSStatus {
        record(delegate.destroyAggregate(aggregate), seam: "destroyAggregate")
    }

    func destroyTap(_ tap: AudioTapResource) -> OSStatus {
        record(delegate.destroyTap(tap), seam: "destroyTap")
    }

    func ownedObjects() throws -> AudioOwnedObjectDiscovery {
        do {
            let discovery = try delegate.ownedObjects()
            discovery.failures.forEach {
                rawFailures.append(NativeRawFailure(
                    seam: "ownedObjects.\($0.operation.rawValue)",
                    status: $0.status
                ))
            }
            return discovery
        } catch {
            record(error, seam: "ownedObjects")
            throw error
        }
    }

    func destroyOwnedObject(_ object: AudioOwnedObject) -> OSStatus {
        record(delegate.destroyOwnedObject(object), seam: "destroyOwnedObject")
    }

    func sampleCallbackCountBeforeObservation() throws {
        guard let callbackContext else { throw NativeRecordingError.missingDSPContext }
        callbackCountBeforeObservation = callbackContext.callbackCount
    }

    func sampleCallbackCountAfterObservation() throws {
        guard let callbackContext else { throw NativeRecordingError.missingDSPContext }
        callbackCountAfterObservation = callbackContext.callbackCount
    }

    func record(_ failures: [AudioTeardownFailure], seam: String) {
        rawFailures.append(contentsOf: failures.map {
            NativeRawFailure(
                seam: "\(seam).\($0.operation.rawValue)",
                status: $0.status
            )
        })
    }

    func recordSessionFailure(_ snapshot: ProcessTapSessionSnapshot) {
        switch snapshot.error {
        case .permissionDenied(let status):
            rawFailures.append(NativeRawFailure(seam: "session.permission", status: status))
        case .operationFailed(let operation, let status):
            rawFailures.append(NativeRawFailure(
                seam: "session.\(operation.rawValue)",
                status: status
            ))
        default:
            rawFailures.append(NativeRawFailure(
                seam: "session.\(snapshot.state)",
                status: kAudioHardwareUnspecifiedError
            ))
        }
    }

    private func readFullSubdeviceUIDs(_ aggregateID: AudioObjectID) throws -> [String] {
        let values = try hal.readRetainedObject(
            CFArray.self,
            from: aggregateID,
            address: .init(selector: kAudioAggregateDevicePropertyFullSubDeviceList)
        )
        return try (values as NSArray).map { value in
            guard let uid = value as? String else {
                throw AudioAggregateTopologyError.unsupportedTopology
            }
            return uid
        }
    }

    private func readDrift(
        kind: String,
        objectID: AudioObjectID
    ) throws -> NativeDriftObservation {
        let enabled = try hal.readScalar(
            UInt32.self,
            from: objectID,
            address: .init(selector: kAudioSubDevicePropertyDriftCompensation)
        )
        let quality = try hal.readScalar(
            UInt32.self,
            from: objectID,
            address: .init(selector: kAudioSubDevicePropertyDriftCompensationQuality)
        )
        return NativeDriftObservation(
            kind: kind,
            diagnosticOnlyObjectID: objectID,
            enabled: enabled,
            quality: quality
        )
    }

    @discardableResult
    private func record(_ status: OSStatus, seam: String) -> OSStatus {
        if status != noErr {
            rawFailures.append(NativeRawFailure(seam: seam, status: status))
        }
        return status
    }

    private func record(_ error: Error, seam: String) {
        rawFailures.append(NativeRawFailure(
            seam: seam,
            status: rawStatus(error)
        ))
    }

    private func rawStatus(_ error: Error) -> OSStatus {
        if let status = (error as? AudioHALError)?.status { return status }
        if let error = error as? AudioIOProcStreamUsageError {
            switch error {
            case .writeFailed(let status), .readFailed(let status): return status
            default: return kAudioHardwareUnspecifiedError
            }
        }
        if case .aggregateNotReady(let status) = error as? AudioTapHardwareError {
            return status ?? kAudioHardwareUnspecifiedError
        }
        return kAudioHardwareUnspecifiedError
    }
}

private extension NativeChannelAddressObservation {
    init(_ value: ProcessTapChannelAddress) {
        self.init(
            bufferIndex: value.bufferIndex,
            channelIndex: value.channelIndex,
            interleavedChannelCount: value.interleavedChannelCount
        )
    }
}

private extension NativeChannelMapObservation {
    init(_ value: ProcessTapChannelMap) {
        self.init(
            input: NativeChannelAddressObservation(value.input),
            output: NativeChannelAddressObservation(value.output),
            mixCoefficient: value.mixCoefficient
        )
    }
}
