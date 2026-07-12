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

struct NativeObservedDrift: Equatable, Sendable {
    let uid: String
    let diagnosticOnlyObjectID: AudioObjectID
    let enabled: UInt32
    let quality: UInt32
}

struct NativeSubdeviceDriftObservation: Codable, Equatable, Sendable {
    let uid: String
    let diagnosticOnlyObjectID: AudioObjectID?
    let expectedEnabled: UInt32
    let expectedQuality: UInt32?
    let observedEnabled: UInt32?
    let observedQuality: UInt32?
    let driftMatchesExpected: Bool
}

struct NativeSubTapDriftObservation: Codable, Equatable, Sendable {
    let diagnosticOnlyObjectID: AudioObjectID
    let tapUUID: String
    let sourceDeviceUID: String
    let sourceStreamIndex: UInt
    let expectedEnabled: UInt32
    let expectedQuality: UInt32?
    let observedEnabled: UInt32
    let observedQuality: UInt32
    let driftMatchesExpected: Bool
}

struct NativeTopologyObservation: Codable, Equatable, Sendable {
    let isAlive: Bool
    let expectedFullSubdeviceUIDs: [String]
    let fullSubdeviceUIDs: [String]
    let fullSubdeviceOrderMatchesExpected: Bool
    let activeSubdeviceUIDs: [String]
    let activeSubdeviceMembershipMatchesExpected: Bool
    let expectedMainSubdeviceUID: String
    let actualMainSubdeviceUID: String
    let mainSubdeviceMatchesExpected: Bool
    let expectedIsStacked: Bool
    let actualIsStacked: Bool
    let isStackedMatchesExpected: Bool
    let subdevices: [NativeSubdeviceDriftObservation]
    let subTap: NativeSubTapDriftObservation
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
}

struct NativeTeardownObservation: Codable, Equatable, Sendable {
    let attempts: Int
    let callbackContextReleased: Bool
    let aggregateIdentityAbsent: Bool
    let tapIdentitiesAbsent: Bool

    var isReleased: Bool {
        callbackContextReleased && aggregateIdentityAbsent && tapIdentitiesAbsent
    }
}

struct NativeRecordingSnapshot: Sendable {
    let taps: [NativeTapResourceObservation]
    let tapFormats: [NativeTapFormatObservation]
    let aggregate: NativeAggregateResourceObservation?
    let ioProc: NativeIOProcResourceObservation?
    let topology: NativeTopologyObservation?
    let verifiedInputStreamUsage: [UInt32]
    let callbackCountBeforeObservation: Int32?
    let callbackCountAfterObservation: Int32?
    let teardown: NativeTeardownObservation?
    let rawFailures: [NativeRawFailure]
}

enum NativeRecordingError: Error {
    case missingPlanOrTap
    case missingDSPContext
    case invalidComposition
    case ownedObjectScanFailed
}

enum NativeTeardownWaitError: Error {
    case invalidAttemptCount
    case retainedFailures
    case timeout(NativeTeardownObservation)
}

@MainActor
func waitForNativeTeardownRelease(
    maxAttempts: Int,
    sleep: () async throws -> Void,
    advance: () async -> [AudioTeardownFailure],
    observe: (Int) throws -> NativeTeardownObservation
) async throws -> NativeTeardownObservation {
    guard maxAttempts > 0 else { throw NativeTeardownWaitError.invalidAttemptCount }
    var latest: NativeTeardownObservation?
    for attempt in 1...maxAttempts {
        let failures = await advance()
        guard failures.isEmpty else {
            _ = try observe(attempt)
            throw NativeTeardownWaitError.retainedFailures
        }
        let observation = try observe(attempt)
        latest = observation
        if observation.isReleased { return observation }
        if attempt < maxAttempts { try await sleep() }
    }
    throw NativeTeardownWaitError.timeout(latest!)
}

enum NativeTopologyEvidence {
    static func make(
        plan: AudioRoutePlan,
        tap: AudioTapResource,
        snapshot: AudioAggregateTopologySnapshot,
        layout: AudioAggregateLayout,
        fullSubdeviceUIDs: [String],
        activeSubdevices: [NativeObservedDrift],
        actualMainSubdeviceUID: String,
        actualIsStacked: Bool,
        subTap: NativeObservedDrift
    ) throws -> NativeTopologyObservation {
        guard snapshot.activeSubTapIDs == [subTap.diagnosticOnlyObjectID],
              snapshot.tapUUIDs == [tap.uuid],
              subTap.uid == tap.uuid.uuidString
        else { throw NativeRecordingError.invalidComposition }
        let expectedUIDs = plan.subdevices.map(\.uid)
        var observedByUID: [String: NativeObservedDrift] = [:]
        for observed in activeSubdevices {
            guard observedByUID.updateValue(observed, forKey: observed.uid) == nil else {
                throw NativeRecordingError.invalidComposition
            }
        }
        let subdevices = plan.subdevices.map { expected in
            let expectedDrift = driftExpectation(expected.driftCompensation)
            let observed = observedByUID[expected.uid]
            return NativeSubdeviceDriftObservation(
                uid: expected.uid,
                diagnosticOnlyObjectID: observed?.diagnosticOnlyObjectID,
                expectedEnabled: expectedDrift.enabled,
                expectedQuality: expectedDrift.quality,
                observedEnabled: observed?.enabled,
                observedQuality: observed?.quality,
                driftMatchesExpected: matches(expectedDrift, observed: observed)
            )
        }
        let expectedSubTapDrift = driftExpectation(tap.source.driftCompensation)
        return NativeTopologyObservation(
            isAlive: snapshot.isAlive,
            expectedFullSubdeviceUIDs: expectedUIDs,
            fullSubdeviceUIDs: fullSubdeviceUIDs,
            fullSubdeviceOrderMatchesExpected: fullSubdeviceUIDs == expectedUIDs,
            activeSubdeviceUIDs: activeSubdevices.map(\.uid),
            activeSubdeviceMembershipMatchesExpected:
                activeSubdevices.count == expectedUIDs.count
                    && Set(activeSubdevices.map(\.uid)) == Set(expectedUIDs),
            expectedMainSubdeviceUID: plan.mainDeviceUID,
            actualMainSubdeviceUID: actualMainSubdeviceUID,
            mainSubdeviceMatchesExpected: actualMainSubdeviceUID == plan.mainDeviceUID,
            expectedIsStacked: plan.isStacked,
            actualIsStacked: actualIsStacked,
            isStackedMatchesExpected: actualIsStacked == plan.isStacked,
            subdevices: subdevices,
            subTap: NativeSubTapDriftObservation(
                diagnosticOnlyObjectID: subTap.diagnosticOnlyObjectID,
                tapUUID: tap.uuid.uuidString,
                sourceDeviceUID: tap.source.deviceUID,
                sourceStreamIndex: tap.source.streamIndex,
                expectedEnabled: expectedSubTapDrift.enabled,
                expectedQuality: expectedSubTapDrift.quality,
                observedEnabled: subTap.enabled,
                observedQuality: subTap.quality,
                driftMatchesExpected: matches(expectedSubTapDrift, observed: subTap)
            ),
            diagnosticOnlyInputStreamIDs: snapshot.inputStreamIDs,
            inputFormats: snapshot.inputFormats,
            diagnosticOnlyOutputStreamIDs: snapshot.outputStreamIDs,
            outputFormats: snapshot.outputFormats,
            tapUUIDs: snapshot.tapUUIDs.map(\.uuidString),
            diagnosticOnlyActiveSubTapIDs: snapshot.activeSubTapIDs,
            hasExactlyOneInput: snapshot.inputStreamIDs.count == 1,
            outputABLFormats: layout.outputFormats,
            channelMaps: layout.channelMaps.map(NativeChannelMapObservation.init),
            requestedInputStreamUsage: layout.inputStreamUsage
        )
    }

    private static func driftExpectation(
        _ drift: AudioRouteDriftCompensation
    ) -> (enabled: UInt32, quality: UInt32?) {
        switch drift {
        case .disabled:
            (0, nil)
        case .highQuality:
            (1, kAudioAggregateDriftCompensationHighQuality)
        }
    }

    private static func matches(
        _ expected: (enabled: UInt32, quality: UInt32?),
        observed: NativeObservedDrift?
    ) -> Bool {
        guard let observed, observed.enabled == expected.enabled else { return false }
        return expected.quality == nil || observed.quality == expected.quality
    }
}

final class NativeRecordingAudioTapHardware: AudioTapHardware, @unchecked Sendable {
    private let delegate = CoreAudioTapHardware(hal: .system)
    private let hal = AudioHALClient.system
    private let stateLock = NSLock()
    private weak var callbackContextStorage: ProcessTapDSPContext?

    private var tapsStorage: [NativeTapResourceObservation] = []
    private var tapFormatsStorage: [NativeTapFormatObservation] = []
    private var aggregateStorage: NativeAggregateResourceObservation?
    private var ioProcStorage: NativeIOProcResourceObservation?
    private var topologyStorage: NativeTopologyObservation?
    private var verifiedInputStreamUsageStorage: [UInt32] = []
    private var callbackCountBeforeObservationStorage: Int32?
    private var callbackCountAfterObservationStorage: Int32?
    private var teardownStorage: NativeTeardownObservation?
    private var rawFailuresStorage: [NativeRawFailure] = []

    private var recordedPlanStorage: AudioRoutePlan?
    private var recordedTapStorage: AudioTapResource?

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
            locked {
                tapsStorage.append(NativeTapResourceObservation(
                    diagnosticOnlyObjectID: tap.objectID,
                    uuid: tap.uuid.uuidString
                ))
            }
            return tap
        } catch {
            record(error, seam: "createTap")
            throw error
        }
    }

    func readTapFormat(_ tap: AudioTapResource) throws -> ProcessTapAudioFormat {
        do {
            let format = try delegate.readTapFormat(tap)
            locked {
                tapFormatsStorage.append(NativeTapFormatObservation(
                    diagnosticOnlyObjectID: tap.objectID,
                    format: format
                ))
            }
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
            locked {
                recordedPlanStorage = plan
                recordedTapStorage = taps.count == 1 ? taps[0] : nil
                aggregateStorage = NativeAggregateResourceObservation(
                    diagnosticOnlyObjectID: resource.objectID,
                    uid: resource.uid
                )
            }
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
            let recorded = locked { (recordedPlanStorage, recordedTapStorage) }
            guard let recordedPlan = recorded.0, let recordedTap = recorded.1 else {
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
            let activeSubdevices = try subdeviceIDs.map(readSubdeviceDrift)
            guard snapshot.activeSubTapIDs.count == 1 else {
                throw NativeRecordingError.invalidComposition
            }
            let topology = try NativeTopologyEvidence.make(
                plan: recordedPlan,
                tap: recordedTap,
                snapshot: snapshot,
                layout: layout,
                fullSubdeviceUIDs: fullSubdeviceUIDs,
                activeSubdevices: activeSubdevices,
                actualMainSubdeviceUID: try readMainSubdeviceUID(aggregate.objectID),
                actualIsStacked: try readIsStacked(aggregate.objectID),
                subTap: try readSubTapDrift(
                    objectID: snapshot.activeSubTapIDs[0],
                    tapUUID: recordedTap.uuid.uuidString
                )
            )
            locked { topologyStorage = topology }
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
            locked {
                callbackContextStorage = context
                ioProcStorage = NativeIOProcResourceObservation(
                    diagnosticOnlyAggregateObjectID: resource.aggregateDeviceID,
                    diagnosticOnlyIOProcID: UInt64(UInt(bitPattern:
                        AudioIOProcStreamUsage.ioProcPointer(resource.ioProcID)
                    ))
                )
            }
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
            locked { verifiedInputStreamUsageStorage = verified }
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
            locked {
                rawFailuresStorage.append(contentsOf: discovery.failures.map {
                    NativeRawFailure(
                    seam: "ownedObjects.\($0.operation.rawValue)",
                    status: $0.status
                    )
                })
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
        guard let context = locked({ callbackContextStorage }) else {
            throw NativeRecordingError.missingDSPContext
        }
        locked { callbackCountBeforeObservationStorage = context.callbackCount }
    }

    func sampleCallbackCountAfterObservation() throws {
        guard let context = locked({ callbackContextStorage }) else {
            throw NativeRecordingError.missingDSPContext
        }
        locked { callbackCountAfterObservationStorage = context.callbackCount }
    }

    func record(_ failures: [AudioTeardownFailure], seam: String) {
        locked {
            rawFailuresStorage.append(contentsOf: failures.map {
                NativeRawFailure(
                seam: "\(seam).\($0.operation.rawValue)",
                status: $0.status
                )
            })
        }
    }

    func recordSessionFailure(_ snapshot: ProcessTapSessionSnapshot) {
        switch snapshot.error {
        case .permissionDenied(let status):
            appendFailure(NativeRawFailure(seam: "session.permission", status: status))
        case .operationFailed(let operation, let status):
            appendFailure(NativeRawFailure(
                seam: "session.\(operation.rawValue)",
                status: status
            ))
        default:
            appendFailure(NativeRawFailure(
                seam: "session.\(snapshot.state)",
                status: kAudioHardwareUnspecifiedError
            ))
        }
    }

    func snapshot() -> NativeRecordingSnapshot {
        locked {
            NativeRecordingSnapshot(
                taps: tapsStorage,
                tapFormats: tapFormatsStorage,
                aggregate: aggregateStorage,
                ioProc: ioProcStorage,
                topology: topologyStorage,
                verifiedInputStreamUsage: verifiedInputStreamUsageStorage,
                callbackCountBeforeObservation: callbackCountBeforeObservationStorage,
                callbackCountAfterObservation: callbackCountAfterObservationStorage,
                teardown: teardownStorage,
                rawFailures: rawFailuresStorage
            )
        }
    }

    func observeTeardown(attempt: Int) throws -> NativeTeardownObservation {
        let recorded = locked {
            (
                callbackContextStorage == nil,
                aggregateStorage,
                tapsStorage
            )
        }
        guard recorded.0 else {
            let observation = NativeTeardownObservation(
                attempts: attempt,
                callbackContextReleased: false,
                aggregateIdentityAbsent: false,
                tapIdentitiesAbsent: false
            )
            locked { teardownStorage = observation }
            return observation
        }
        let discovery = try ownedObjects()
        guard discovery.failures.isEmpty else {
            throw NativeRecordingError.ownedObjectScanFailed
        }
        let aggregateAbsent = recorded.1.map { aggregate in
            discovery.objects.contains {
                $0.id == aggregate.diagnosticOnlyObjectID
                    && $0.classID == kAudioAggregateDeviceClassID
                    && $0.uid == aggregate.uid
            } == false
        } ?? true
        let tapsAbsent = recorded.2.allSatisfy { tap in
            discovery.objects.contains {
                $0.id == tap.diagnosticOnlyObjectID
                    && $0.classID == kAudioTapClassID
                    && $0.uid == tap.uuid
            } == false
        }
        let observation = NativeTeardownObservation(
            attempts: attempt,
            callbackContextReleased: recorded.0,
            aggregateIdentityAbsent: aggregateAbsent,
            tapIdentitiesAbsent: tapsAbsent
        )
        locked { teardownStorage = observation }
        return observation
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

    private func readSubdeviceDrift(
        objectID: AudioObjectID
    ) throws -> NativeObservedDrift {
        let uid = try hal.readRetainedString(
            from: objectID,
            address: .init(selector: kAudioDevicePropertyDeviceUID)
        )
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
        return NativeObservedDrift(
            uid: uid,
            diagnosticOnlyObjectID: objectID,
            enabled: enabled,
            quality: quality
        )
    }

    private func readSubTapDrift(
        objectID: AudioObjectID,
        tapUUID: String
    ) throws -> NativeObservedDrift {
        NativeObservedDrift(
            uid: tapUUID,
            diagnosticOnlyObjectID: objectID,
            enabled: try hal.readScalar(
                UInt32.self,
                from: objectID,
                address: .init(selector: kAudioSubTapPropertyDriftCompensation)
            ),
            quality: try hal.readScalar(
                UInt32.self,
                from: objectID,
                address: .init(selector: kAudioSubTapPropertyDriftCompensationQuality)
            )
        )
    }

    private func readMainSubdeviceUID(_ aggregateID: AudioObjectID) throws -> String {
        try hal.readRetainedString(
            from: aggregateID,
            address: .init(selector: kAudioAggregateDevicePropertyMainSubDevice)
        )
    }

    private func readIsStacked(_ aggregateID: AudioObjectID) throws -> Bool {
        let composition = try hal.readRetainedObject(
            CFDictionary.self,
            from: aggregateID,
            address: .init(selector: kAudioAggregateDevicePropertyComposition)
        ) as NSDictionary
        guard let value = composition[kAudioAggregateDeviceIsStackedKey] as? NSNumber else {
            throw NativeRecordingError.invalidComposition
        }
        return value.boolValue
    }

    @discardableResult
    private func record(_ status: OSStatus, seam: String) -> OSStatus {
        if status != noErr {
            appendFailure(NativeRawFailure(seam: seam, status: status))
        }
        return status
    }

    private func record(_ error: Error, seam: String) {
        appendFailure(NativeRawFailure(
            seam: seam,
            status: rawStatus(error)
        ))
    }

    private func appendFailure(_ failure: NativeRawFailure) {
        locked { rawFailuresStorage.append(failure) }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
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
