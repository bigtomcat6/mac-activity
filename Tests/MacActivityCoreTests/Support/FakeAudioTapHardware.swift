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
        case readAggregateLayout
        case createIOProc
        case startDevice
        case waitForFirstCallback
        case setTapMutedWhenTapped(sourceIndex: Int)
        case setTapUnmuted(sourceIndex: Int)
        case stopDevice
        case destroyIOProc
        case destroyAggregate
        case destroyTap(sourceIndex: Int)
        case ownedObjects
    }

    enum FailurePoint: Hashable {
        case createTap(Int)
        case readTapFormat(Int)
        case createAggregate
        case waitForAggregateReadiness
        case readAggregateLayout
        case createIOProc
        case startDevice
        case setTapMuted(Int)
        case setTapUnmuted(Int)
        case stopDevice
        case destroyIOProc
        case destroyAggregate
        case destroyTap(Int)
        case ownedObjects
    }

    private final class WeakContext {
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

    var readinessInitiallyBlocked = false
    var firstCallbackInitiallyBlocked = false
    var forcedAggregateObjectID: AudioObjectID?
    var aggregateLayoutOverride: AudioAggregateLayout?
    var tapFormatOverrides: [Int: ProcessTapAudioFormat] = [:]
    var ownedObjectValues: [AudioOwnedObject] = []

    var calls: [Call] {
        locked { recordedCalls }
    }

    var createdProcessObjectIDs: [AudioObjectID] {
        locked { createdProcessObjectIDsStorage }
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
            let objectID = nextTapID
            nextTapID += 1
            tapSourceIndices[objectID] = sourceIndex
            tapFormats[objectID] = source.expectedFormat
            createdProcessObjectIDsStorage.append(processObjectID)
            return AudioTapResource(objectID: objectID, uuid: uuid, source: source)
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
            let objectID = forcedAggregateObjectID ?? nextAggregateID
            if forcedAggregateObjectID == nil {
                nextAggregateID += 1
            }
            return AudioAggregateResource(
                objectID: objectID,
                uid: plan.aggregateUID
            )
        }
    }

    func waitUntilReady(
        _ aggregate: AudioAggregateResource,
        deadline: DispatchTime,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        record(.waitForAggregateReadiness)
        locked { readinessCancellationProbe = isCancelled }
        try throwIfNeeded(
            at: .waitForAggregateReadiness,
            operation: .getData,
            objectID: aggregate.objectID
        )
        let shouldBlock = locked { () -> Bool in
            readinessInvocationCount += 1
            let shouldBlock = readinessInitiallyBlocked && readinessInvocationCount == 1
            readinessPolling = shouldBlock
            return shouldBlock
        }
        guard shouldBlock else { return }

        while DispatchTime.now() < deadline {
            if isCancelled() { return }
            usleep(1_000)
        }
        throw AudioTapHardwareError.aggregateNotReady
    }

    func readAggregateLayout(
        _ aggregate: AudioAggregateResource,
        plan: AudioRoutePlan,
        taps: [AudioTapResource]
    ) throws -> AudioAggregateLayout {
        record(.readAggregateLayout)
        try throwIfNeeded(
            at: .readAggregateLayout,
            operation: .getData,
            objectID: aggregate.objectID
        )
        if let aggregateLayoutOverride {
            return aggregateLayoutOverride
        }

        let inputFormats = taps.map { tap in
            locked {
                let index = tapSourceIndices[tap.objectID] ?? Int(tap.source.streamIndex)
                return tapFormatOverrides[index]
                    ?? tapFormats[tap.objectID]
                    ?? tap.source.expectedFormat
            }
        }
        var channelMaps: [ProcessTapChannelMap] = []
        for (bufferIndex, format) in inputFormats.enumerated() {
            let interleavedChannelCount = format.interleaving == .interleaved
                ? format.channelCount
                : 1
            for channelIndex in 0..<interleavedChannelCount {
                let address = ProcessTapChannelAddress(
                    bufferIndex: bufferIndex,
                    channelIndex: channelIndex,
                    interleavedChannelCount: interleavedChannelCount
                )
                channelMaps.append(ProcessTapChannelMap(
                    input: address,
                    output: address,
                    mixCoefficient: 1
                ))
            }
        }
        return AudioAggregateLayout(
            inputFormats: inputFormats,
            outputFormats: inputFormats,
            channelMaps: channelMaps
        )
    }

    func createIOProc(
        aggregate: AudioAggregateResource,
        context: ProcessTapDSPContext
    ) throws -> AudioIOProcResource {
        record(.createIOProc)
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
        return AudioIOProcResource(
            aggregateDeviceID: aggregate.objectID,
            ioProcID: ioProcID
        )
    }

    func start(_ ioProc: AudioIOProcResource) throws {
        record(.startDevice)
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
        context(for: ioProc.aggregateDeviceID)?.markCallbackObserved()
        record(.waitForFirstCallback)
    }

    func setMuteState(
        _ state: AudioTapMuteState,
        for tap: AudioTapResource
    ) throws {
        let sourceIndex = sourceIndex(for: tap)
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
    }

    func stop(_ ioProc: AudioIOProcResource) -> OSStatus {
        record(.stopDevice)
        return takeStatus(
            at: .stopDevice,
            ioProcKey: Self.ioProcKey(ioProc.ioProcID)
        )
    }

    func destroyIOProc(_ ioProc: AudioIOProcResource) -> OSStatus {
        record(.destroyIOProc)
        return takeStatus(
            at: .destroyIOProc,
            ioProcKey: Self.ioProcKey(ioProc.ioProcID)
        )
    }

    func destroyAggregate(_ aggregate: AudioAggregateResource) -> OSStatus {
        record(.destroyAggregate)
        return takeStatus(at: .destroyAggregate)
    }

    func destroyTap(_ tap: AudioTapResource) -> OSStatus {
        let sourceIndex = sourceIndex(for: tap)
        record(.destroyTap(sourceIndex: sourceIndex))
        waitIfBlocked(at: .destroyTap(sourceIndex))
        return takeStatus(at: .destroyTap(sourceIndex))
    }

    func ownedObjects() throws -> [AudioOwnedObject] {
        record(.ownedObjects)
        try throwIfNeeded(
            at: .ownedObjects,
            operation: .getData,
            objectID: AudioObjectID(kAudioObjectSystemObject)
        )
        return locked { ownedObjectValues }
    }
}

private extension FakeAudioTapHardware {
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
