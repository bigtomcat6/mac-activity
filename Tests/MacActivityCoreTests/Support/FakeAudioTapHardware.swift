import CoreAudio
import Darwin
import Foundation

@testable import MacActivityCore

final class FakeAudioTapHardware: AudioTapHardware, @unchecked Sendable {
    enum Call: Equatable {
        case createTap(sourceIndex: Int, initiallyMuted: Bool)
        case readTapFormat(sourceIndex: Int)
        case createAggregate(tapAutoStart: Bool)
        case waitForAggregateReadiness
        case createIOProc
        case configureInputStreamUsage([UInt32])
        case startDevice
        case observeSustainedCallbacks
        case setTapMutedWhenTapped(sourceIndex: Int)
        case setTapUnmuted(sourceIndex: Int)
        case stopDevice
        case destroyIOProc
        case destroyAggregate
        case destroyTap(sourceIndex: Int)
        case ownedObjects
        case destroyOwnedObject(object: AudioOwnedObject)
    }

    enum FailurePoint: Hashable {
        case createTap(Int)
        case readTapFormat(Int)
        case createAggregate
        case waitForAggregateReadiness
        case createIOProc
        case configureInputStreamUsage
        case startDevice
        case setTapMuted(Int)
        case setTapUnmuted(Int)
        case stopDevice
        case destroyIOProc
        case destroyAggregate
        case destroyTap(Int)
        case ownedObjects
        case destroyOwnedObject(AudioObjectID)
    }

    private final class WeakContext: @unchecked Sendable {
        weak var value: ProcessTapDSPContext?

        init(_ value: ProcessTapDSPContext) {
            self.value = value
        }
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var queuedStatuses: [FailurePoint: [OSStatus]] = [:]
    private var persistentStatuses: [FailurePoint: OSStatus] = [:]
    private var ioProcPersistentStatuses: [FailurePoint: [UInt: OSStatus]] = [:]
    private var blockedPoints: Set<FailurePoint> = []
    private var enteredBlockedPoints: Set<FailurePoint> = []
    private var tapSourceIndices: [AudioObjectID: Int] = [:]
    private var tapFormats: [AudioObjectID: ProcessTapAudioFormat] = [:]
    private var liveTapIdentities: [AudioObjectID: UUID] = [:]
    private var tapMuteStates: [UUID: AudioTapMuteState] = [:]
    private var liveAggregateIdentities: [AudioObjectID: String] = [:]
    private var liveIOProcParents: [UInt: AudioAggregateResource] = [:]
    private var contexts: [AudioObjectID: WeakContext] = [:]
    private var contextOrder: [AudioObjectID] = []
    private var createdIOProcKeysStorage: [UInt] = []
    private var readinessCancellationProbe: (@Sendable () -> Bool)?
    private var readinessInvocationCount = 0
    private var startInvocationCount = 0
    private var readinessPolling = false
    private var mainThreadCallCountStorage = 0
    private var nextTapID: AudioObjectID = 1_000
    private var nextAggregateID: AudioObjectID = 2_000
    private var createdProcessObjectIDsStorage: [AudioObjectID] = []
    private var createdTapResourcesStorage: [AudioTapResource] = []
    private var latestPlan: AudioRoutePlan?
    private var latestTaps: [AudioTapResource] = []

    var readinessInitiallyBlocked = false
    var firstCallbackInitiallyBlocked = false
    var singleCallbackOnly = false
    var forcedTapObjectID: AudioObjectID?
    var forcedAggregateObjectID: AudioObjectID?
    var aggregateTopologyError: AudioAggregateTopologyError?
    var aggregateTopologySnapshotOverride: AudioAggregateTopologySnapshot?
    var tapFormatOverrides: [Int: ProcessTapAudioFormat] = [:]
    var ownedObjectValues: [AudioOwnedObject] = []
    var ownedDiscoveryFailures: [AudioTeardownFailure] = []

    var calls: [Call] {
        locked { recordedCalls }
    }

    var createdProcessObjectIDs: [AudioObjectID] {
        locked { createdProcessObjectIDsStorage }
    }

    var createdTapResources: [AudioTapResource] {
        locked { createdTapResourcesStorage }
    }

    var liveOwnedObjects: [AudioOwnedObject] {
        locked {
            liveAggregateIdentities.map { objectID, uid in
                AudioOwnedObject(
                    id: objectID,
                    classID: kAudioAggregateDeviceClassID,
                    uid: uid,
                    name: nil
                )
            } + liveTapIdentities.map { objectID, uuid in
                AudioOwnedObject(
                    id: objectID,
                    classID: kAudioTapClassID,
                    uid: uuid.uuidString,
                    name: nil
                )
            }
        }
    }

    var currentMuteState: AudioTapMuteState? {
        locked {
            createdTapResourcesStorage.last.flatMap {
                tapMuteStates[$0.uuid]
            }
        }
    }

    var mainThreadCallCount: Int {
        locked { mainThreadCallCountStorage }
    }

    var createdIOProcKeys: [UInt] {
        locked { createdIOProcKeysStorage }
    }

    var lastContext: ProcessTapDSPContext? {
        locked {
            contextOrder.reversed().compactMap { contexts[$0]?.value }.first
        }
    }

    func context(for aggregateDeviceID: AudioObjectID) -> ProcessTapDSPContext? {
        locked { contexts[aggregateDeviceID]?.value }
    }

    func clearCalls() {
        locked { recordedCalls.removeAll() }
    }

    func enqueueStatus(_ status: OSStatus, at point: FailurePoint) {
        locked { queuedStatuses[point, default: []].append(status) }
    }

    func setPersistentStatus(_ status: OSStatus?, at point: FailurePoint) {
        locked { persistentStatuses[point] = status }
    }

    func setPersistentStatus(
        _ status: OSStatus?,
        at point: FailurePoint,
        ioProcKey: UInt
    ) {
        locked {
            ioProcPersistentStatuses[point, default: [:]][ioProcKey] = status
        }
    }

    func blockCalls(at point: FailurePoint) {
        locked {
            enteredBlockedPoints.remove(point)
            blockedPoints.insert(point)
        }
    }

    func releaseCalls(at point: FailurePoint) {
        locked { blockedPoints.remove(point) }
    }

    func waitUntilBlocked(at point: FailurePoint) async {
        while locked({ enteredBlockedPoints.contains(point) }) == false {
            await Task.yield()
        }
    }

    func invokeLatestReadinessCancellationProbe() -> Bool? {
        let probe = locked { readinessCancellationProbe }
        return probe?()
    }

    func waitUntilReadinessPolling() async {
        while locked({ readinessPolling }) == false {
            await Task.yield()
        }
    }

    func waitUntilCall(_ expected: Call) async {
        while calls.contains(expected) == false {
            await Task.yield()
        }
    }

    func createTap(
        processObjectID: AudioObjectID,
        source: AudioTapSource,
        uuid: UUID
    ) throws -> AudioTapResource {
        let sourceIndex = Int(source.streamIndex)
        record(.createTap(sourceIndex: sourceIndex, initiallyMuted: false))
        waitIfBlocked(at: .createTap(sourceIndex))
        try throwIfNeeded(
            at: .createTap(sourceIndex),
            operation: .createTap,
            objectID: processObjectID
        )

        return locked {
            let objectID = forcedTapObjectID ?? nextTapID
            if forcedTapObjectID == nil {
                nextTapID += 1
            }
            tapSourceIndices[objectID] = sourceIndex
            tapFormats[objectID] = source.expectedFormat
            createdProcessObjectIDsStorage.append(processObjectID)
            let resource = AudioTapResource(
                objectID: objectID,
                uuid: CoreAudioTapHardware.reservedTapUUID(entropy: uuid),
                source: source
            )
            liveTapIdentities[objectID] = resource.uuid
            tapMuteStates[resource.uuid] = .unmuted
            createdTapResourcesStorage.append(resource)
            return resource
        }
    }

    func readTapFormat(_ tap: AudioTapResource) throws -> ProcessTapAudioFormat {
        let sourceIndex = sourceIndex(for: tap)
        record(.readTapFormat(sourceIndex: sourceIndex))
        try throwIfNeeded(
            at: .readTapFormat(sourceIndex),
            operation: .getData,
            objectID: tap.objectID
        )
        return locked {
            tapFormatOverrides[sourceIndex]
                ?? tapFormats[tap.objectID]
                ?? tap.source.expectedFormat
        }
    }

    func createAggregate(
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateResource {
        record(.createAggregate(tapAutoStart: false))
        try throwIfNeeded(
            at: .createAggregate,
            operation: .createAggregate,
            objectID: plan.processObjectID
        )
        return locked {
            latestPlan = plan
            latestTaps = taps
            let objectID = forcedAggregateObjectID ?? nextAggregateID
            if forcedAggregateObjectID == nil {
                nextAggregateID += 1
            }
            let resource = AudioAggregateResource(
                objectID: objectID,
                uid: plan.aggregateUID
            )
            liveAggregateIdentities[objectID] = resource.uid
            return resource
        }
    }

    func waitForStableTopology(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> AudioAggregateTopologySnapshot {
        record(.waitForAggregateReadiness)
        locked { readinessCancellationProbe = isCancelled }
        try throwIfNeeded(
            at: .waitForAggregateReadiness,
            operation: .getData,
            objectID: aggregate.objectID
        )
        if let aggregateTopologyError { throw aggregateTopologyError }
        let shouldBlock = locked { () -> Bool in
            readinessInvocationCount += 1
            let shouldBlock = readinessInitiallyBlocked && readinessInvocationCount == 1
            readinessPolling = shouldBlock
            return shouldBlock
        }
        guard shouldBlock else { return topologySnapshot() }

        while DispatchTime.now() < deadline {
            if isCancelled() { throw AudioTapHardwareError.cancelled }
            usleep(1_000)
        }
        throw AudioTapHardwareError.aggregateNotReady(lastStatus: nil)
    }

    func createIOProc(
        aggregate: AudioAggregateResource,
        context: ProcessTapDSPContext
    ) throws -> AudioIOProcResource {
        record(.createIOProc)
        guard aggregateIdentityMatches(aggregate) else {
            throw badObjectError(
                operation: .createIOProc,
                objectID: aggregate.objectID
            )
        }
        try throwIfNeeded(
            at: .createIOProc,
            operation: .createIOProc,
            objectID: aggregate.objectID
        )
        locked {
            contexts[aggregate.objectID] = WeakContext(context)
            contextOrder.append(aggregate.objectID)
        }
        let ioProcID = locked { () -> AudioDeviceIOProcID in
            let ioProcID = fakeAudioTapIOProcs[
                createdIOProcKeysStorage.count % fakeAudioTapIOProcs.count
            ]
            createdIOProcKeysStorage.append(Self.ioProcKey(ioProcID))
            return ioProcID
        }
        let resource = AudioIOProcResource(
            aggregateDeviceID: aggregate.objectID,
            aggregateUID: aggregate.uid,
            ioProcID: ioProcID
        )
        locked {
            liveIOProcParents[Self.ioProcKey(ioProcID)] = aggregate
        }
        return resource
    }

    func configureInputStreamUsage(
        _ usage: [UInt32],
        for ioProc: AudioIOProcResource
    ) throws -> [UInt32] {
        record(.configureInputStreamUsage(usage))
        try throwIfNeeded(
            at: .configureInputStreamUsage,
            operation: .setData,
            objectID: ioProc.aggregateDeviceID
        )
        return usage
    }

    func start(_ ioProc: AudioIOProcResource) throws {
        record(.startDevice)
        guard ioProcIdentityMatches(ioProc) else {
            throw badObjectError(
                operation: .startDevice,
                objectID: ioProc.aggregateDeviceID
            )
        }
        try throwIfNeeded(
            at: .startDevice,
            operation: .startDevice,
            objectID: ioProc.aggregateDeviceID
        )
        let shouldBlock = locked { () -> Bool in
            startInvocationCount += 1
            return firstCallbackInitiallyBlocked && startInvocationCount == 1
        }
        guard shouldBlock == false else { return }
        let context = context(for: ioProc.aggregateDeviceID)
        context?.markCallbackObserved()
        if singleCallbackOnly == false, let context {
            let weakContext = WeakContext(context)
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) {
                weakContext.value?.markCallbackObserved()
            }
        }
        record(.observeSustainedCallbacks)
    }

    func setMuteState(
        _ state: AudioTapMuteState,
        for tap: AudioTapResource
    ) throws {
        let sourceIndex = sourceIndex(for: tap)
        guard tapIdentityMatches(tap) else {
            throw badObjectError(operation: .setData, objectID: tap.objectID)
        }
        switch state {
        case .unmuted:
            record(.setTapUnmuted(sourceIndex: sourceIndex))
            try throwIfNeeded(
                at: .setTapUnmuted(sourceIndex),
                operation: .setData,
                objectID: tap.objectID
            )
        case .mutedWhenTapped:
            record(.setTapMutedWhenTapped(sourceIndex: sourceIndex))
            try throwIfNeeded(
                at: .setTapMuted(sourceIndex),
                operation: .setData,
                objectID: tap.objectID
            )
        }
        locked { tapMuteStates[tap.uuid] = state }
    }

    func restoreOriginalAudio(for tap: AudioTapResource) -> OSStatus {
        let sourceIndex = sourceIndex(for: tap)
        record(.setTapUnmuted(sourceIndex: sourceIndex))
        guard tapIdentityMatches(tap) else { return noErr }
        let status = takeStatus(at: .setTapUnmuted(sourceIndex))
        if status == noErr {
            locked { tapMuteStates[tap.uuid] = .unmuted }
        }
        return status
    }

    func stop(_ ioProc: AudioIOProcResource) -> OSStatus {
        record(.stopDevice)
        guard ioProcIdentityMatches(ioProc) else {
            return kAudioHardwareBadObjectError
        }
        return takeStatus(
            at: .stopDevice,
            ioProcKey: Self.ioProcKey(ioProc.ioProcID)
        )
    }

    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus {
        record(.destroyIOProc)
        guard ioProcIdentityMatches(ioProc) else {
            return kAudioHardwareBadObjectError
        }
        let status = takeStatus(
            at: .destroyIOProc,
            ioProcKey: Self.ioProcKey(ioProc.ioProcID)
        )
        if status == noErr {
            locked {
                let key = Self.ioProcKey(ioProc.ioProcID)
                liveIOProcParents.removeValue(forKey: key)
            }
        }
        return status
    }

    func destroyAggregate(_ aggregate: AudioAggregateResource) -> OSStatus {
        record(.destroyAggregate)
        guard aggregateIdentityMatches(aggregate) else { return noErr }
        let status = takeStatus(at: .destroyAggregate)
        if status == noErr {
            locked { liveAggregateIdentities.removeValue(forKey: aggregate.objectID) }
        }
        return status
    }

    func destroyTap(_ tap: AudioTapResource) -> OSStatus {
        let sourceIndex = sourceIndex(for: tap)
        record(.destroyTap(sourceIndex: sourceIndex))
        waitIfBlocked(at: .destroyTap(sourceIndex))
        guard tapIdentityMatches(tap) else { return noErr }
        let status = takeStatus(at: .destroyTap(sourceIndex))
        if status == noErr {
            locked { liveTapIdentities.removeValue(forKey: tap.objectID) }
        }
        return status
    }

    func ownedObjects() throws -> AudioOwnedObjectDiscovery {
        record(.ownedObjects)
        try throwIfNeeded(
            at: .ownedObjects,
            operation: .getData,
            objectID: AudioObjectID(kAudioObjectSystemObject)
        )
        return locked {
            AudioOwnedObjectDiscovery(
                objects: ownedObjectValues + liveAggregateIdentities.map {
                    AudioOwnedObject(
                        id: $0.key,
                        classID: kAudioAggregateDeviceClassID,
                        uid: $0.value,
                        name: nil
                    )
                } + liveTapIdentities.map {
                    AudioOwnedObject(
                        id: $0.key,
                        classID: kAudioTapClassID,
                        uid: $0.value.uuidString,
                        name: nil
                    )
                },
                failures: ownedDiscoveryFailures
            )
        }
    }

    func destroyOwnedObject(_ object: AudioOwnedObject) -> OSStatus {
        record(.destroyOwnedObject(object: object))
        return takeStatus(at: .destroyOwnedObject(object.id))
    }
}

private extension FakeAudioTapHardware {
    func tapIdentityMatches(_ tap: AudioTapResource) -> Bool {
        locked { liveTapIdentities[tap.objectID] == tap.uuid }
    }

    func aggregateIdentityMatches(_ aggregate: AudioAggregateResource) -> Bool {
        locked { liveAggregateIdentities[aggregate.objectID] == aggregate.uid }
    }

    func ioProcIdentityMatches(_ ioProc: AudioIOProcResource) -> Bool {
        let key = Self.ioProcKey(ioProc.ioProcID)
        return locked {
            liveAggregateIdentities[ioProc.aggregateDeviceID] == ioProc.aggregateUID
                && liveIOProcParents[key]?.objectID == ioProc.aggregateDeviceID
                && liveIOProcParents[key]?.uid == ioProc.aggregateUID
        }
    }

    func badObjectError(
        operation: AudioHALOperation,
        objectID: AudioObjectID
    ) -> AudioHALError {
        AudioHALError(
            operation: operation,
            objectID: objectID,
            address: nil,
            reason: .status(kAudioHardwareBadObjectError)
        )
    }

    func topologySnapshot() -> AudioAggregateTopologySnapshot {
        locked {
            if let aggregateTopologySnapshotOverride {
                return aggregateTopologySnapshotOverride
            }
            let taps = latestTaps
            let plan = latestPlan
            let inputFormats = taps.map { tap in
                let index = tapSourceIndices[tap.objectID] ?? Int(tap.source.streamIndex)
                return tapFormatOverrides[index] ?? tapFormats[tap.objectID] ?? tap.source.expectedFormat
            }
            let outputFormats = plan?.subdevices.flatMap(\.outputStreams).map(\.format)
                ?? inputFormats
            return AudioAggregateTopologySnapshot(
                isAlive: true,
                inputStreamIDs: inputFormats.indices.map { AudioStreamID(10_000 + $0) },
                inputFormats: inputFormats,
                outputStreamIDs: outputFormats.indices.map { AudioStreamID(20_000 + $0) },
                outputFormats: outputFormats,
                tapUUIDs: taps.map(\.uuid),
                activeSubTapIDs: taps.indices.map { AudioObjectID(30_000 + $0) }
            )
        }
    }

    func record(_ call: Call) {
        locked {
            recordedCalls.append(call)
            if Thread.isMainThread {
                mainThreadCallCountStorage += 1
            }
        }
    }

    func sourceIndex(for tap: AudioTapResource) -> Int {
        locked { tapSourceIndices[tap.objectID] ?? Int(tap.source.streamIndex) }
    }

    func throwIfNeeded(
        at point: FailurePoint,
        operation: AudioHALOperation,
        objectID: AudioObjectID
    ) throws {
        let status = takeStatus(at: point)
        guard status != noErr else { return }
        throw AudioHALError(
            operation: operation,
            objectID: objectID,
            address: nil,
            reason: .status(status)
        )
    }

    func takeStatus(at point: FailurePoint) -> OSStatus {
        locked {
            if var statuses = queuedStatuses[point], statuses.isEmpty == false {
                let status = statuses.removeFirst()
                queuedStatuses[point] = statuses
                return status
            }
            return persistentStatuses[point] ?? noErr
        }
    }

    func takeStatus(at point: FailurePoint, ioProcKey: UInt) -> OSStatus {
        if let status = locked({ ioProcPersistentStatuses[point]?[ioProcKey] }) {
            return status
        }
        return takeStatus(at: point)
    }

    func waitIfBlocked(at point: FailurePoint) {
        let shouldBlock = locked { () -> Bool in
            guard blockedPoints.contains(point) else { return false }
            enteredBlockedPoints.insert(point)
            return true
        }
        guard shouldBlock else { return }
        while locked({ blockedPoints.contains(point) }) {
            usleep(1_000)
        }
    }

    static func ioProcKey(_ ioProcID: AudioDeviceIOProcID) -> UInt {
        unsafeBitCast(ioProcID, to: UInt.self)
    }

    @discardableResult
    func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private let fakeAudioTapIOProcs: [AudioDeviceIOProcID] = [
    { _, _, _, _, _, _, _ in noErr },
    { _, _, _, _, _, _, _ in noErr },
    { _, _, _, _, _, _, _ in noErr },
    { _, _, _, _, _, _, _ in noErr },
]
