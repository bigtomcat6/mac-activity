import CoreAudio
import CoreFoundation
import Dispatch
import Foundation
@testable import MacActivityCore

final class FakeAudioHALBackend: AudioHALBackend, @unchecked Sendable {
    struct ObjectWrite {
        let objectID: AudioObjectID
        let address: AudioHALPropertyAddress
        let objectPointer: UnsafeMutableRawPointer?
    }

    struct ListenerCall {
        let objectID: AudioObjectID
        let address: AudioHALPropertyAddress
        let queue: DispatchQueue
        let registration: AudioHALListenerRegistration

        var block: AudioObjectPropertyListenerBlock {
            registration.block
        }

        var registrationIdentifier: ObjectIdentifier {
            ObjectIdentifier(registration)
        }

        init(
            objectID: AudioObjectID,
            address: AudioHALPropertyAddress,
            queue: DispatchQueue,
            registration: AudioHALListenerRegistration
        ) {
            self.objectID = objectID
            self.address = address
            self.queue = queue
            self.registration = registration
        }
    }

    struct IOProcCreation {
        let deviceID: AudioDeviceID
        let callback: AudioDeviceIOProc
        let clientData: UnsafeMutableRawPointer?
    }

    private struct PropertyKey: Hashable {
        let objectID: AudioObjectID
        let address: AudioHALPropertyAddress
    }

    private enum PropertyPayload {
        case bytes([UInt8])
        case retainedObject(AnyObject)
        case retainedString(String)

        var byteCount: UInt32 {
            switch self {
            case .bytes(let bytes):
                UInt32(bytes.count)
            case .retainedObject, .retainedString:
                UInt32(MemoryLayout<Unmanaged<AnyObject>?>.size)
            }
        }
    }

    private struct Property {
        var payload: PropertyPayload
        var readStatus: OSStatus = noErr
        var isSettable = false
    }

    private struct SizeResult {
        let status: OSStatus
        let byteCount: UInt32
    }

    private enum ReadPayload {
        case bytes([UInt8])
        case retainedObject(Unmanaged<AnyObject>)
        case none
    }

    private struct ReadResult {
        let status: OSStatus
        let returnedByteCount: UInt32
        let payload: ReadPayload
    }

    private var properties: [PropertyKey: Property] = [:]
    private var queuedSizes: [SizeResult] = []
    private var queuedReads: [ReadResult] = []
    private var queuedAddListenerStatuses: [OSStatus] = []
    private var activeListenerCalls: [ObjectIdentifier: ListenerCall] = [:]
    private let mutableStateLock = NSLock()
    private var mutableState = MutableState()

    private struct MutableState {
        var operations: [AudioHALOperation] = []
        var objectWrites: [ObjectWrite] = []
        var createdProcessTapDescriptions: [CATapDescription] = []
        var createdAggregateDeviceDescriptions: [CFDictionary] = []
        var ioProcCreations: [IOProcCreation] = []
        var destroyedProcessTapIDs: [AudioObjectID] = []
        var destroyedAggregateDeviceIDs: [AudioDeviceID] = []
        var objectWriteStatus: OSStatus = noErr
        var createProcessTapStatus: OSStatus = noErr
        var destroyProcessTapStatus: OSStatus = noErr
        var createAggregateDeviceStatus: OSStatus = noErr
        var destroyAggregateDeviceStatus: OSStatus = noErr
        var createIOProcStatus: OSStatus = noErr
        var destroyIOProcStatus: OSStatus = noErr
        var startDeviceStatus: OSStatus = noErr
        var stopDeviceStatus: OSStatus = noErr
        var nextProcessTapID: AudioObjectID = kAudioObjectUnknown
        var nextAggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
        var nextIOProcID: AudioDeviceIOProcID?
    }

    private(set) var dataSizeCallCount = 0
    private(set) var readSelectors: [AudioObjectPropertySelector] = []
    private(set) var writeSelectors: [AudioObjectPropertySelector] = []
    private(set) var addedListeners: [ListenerCall] = []
    private(set) var removedListeners: [ListenerCall] = []

    var addListenerStatus: OSStatus = noErr
    var removeListenerStatus: OSStatus = noErr

    var mutableOperations: [AudioHALOperation] {
        withMutableState { $0.operations }
    }

    var objectWrites: [ObjectWrite] {
        withMutableState { $0.objectWrites }
    }

    var createdProcessTapDescriptions: [CATapDescription] {
        withMutableState { $0.createdProcessTapDescriptions }
    }

    var createdAggregateDeviceDescriptions: [CFDictionary] {
        withMutableState { $0.createdAggregateDeviceDescriptions }
    }

    var ioProcCreations: [IOProcCreation] {
        withMutableState { $0.ioProcCreations }
    }

    var destroyedProcessTapIDs: [AudioObjectID] {
        withMutableState { $0.destroyedProcessTapIDs }
    }

    var destroyedAggregateDeviceIDs: [AudioDeviceID] {
        withMutableState { $0.destroyedAggregateDeviceIDs }
    }

    var objectWriteStatus: OSStatus {
        get { withMutableState { $0.objectWriteStatus } }
        set { withMutableState { $0.objectWriteStatus = newValue } }
    }

    var createProcessTapStatus: OSStatus {
        get { withMutableState { $0.createProcessTapStatus } }
        set { withMutableState { $0.createProcessTapStatus = newValue } }
    }

    var destroyProcessTapStatus: OSStatus {
        get { withMutableState { $0.destroyProcessTapStatus } }
        set { withMutableState { $0.destroyProcessTapStatus = newValue } }
    }

    var createAggregateDeviceStatus: OSStatus {
        get { withMutableState { $0.createAggregateDeviceStatus } }
        set { withMutableState { $0.createAggregateDeviceStatus = newValue } }
    }

    var destroyAggregateDeviceStatus: OSStatus {
        get { withMutableState { $0.destroyAggregateDeviceStatus } }
        set { withMutableState { $0.destroyAggregateDeviceStatus = newValue } }
    }

    var createIOProcStatus: OSStatus {
        get { withMutableState { $0.createIOProcStatus } }
        set { withMutableState { $0.createIOProcStatus = newValue } }
    }

    var destroyIOProcStatus: OSStatus {
        get { withMutableState { $0.destroyIOProcStatus } }
        set { withMutableState { $0.destroyIOProcStatus = newValue } }
    }

    var startDeviceStatus: OSStatus {
        get { withMutableState { $0.startDeviceStatus } }
        set { withMutableState { $0.startDeviceStatus = newValue } }
    }

    var stopDeviceStatus: OSStatus {
        get { withMutableState { $0.stopDeviceStatus } }
        set { withMutableState { $0.stopDeviceStatus = newValue } }
    }

    var nextProcessTapID: AudioObjectID {
        get { withMutableState { $0.nextProcessTapID } }
        set { withMutableState { $0.nextProcessTapID = newValue } }
    }

    var nextAggregateDeviceID: AudioDeviceID {
        get { withMutableState { $0.nextAggregateDeviceID } }
        set { withMutableState { $0.nextAggregateDeviceID = newValue } }
    }

    var nextIOProcID: AudioDeviceIOProcID? {
        get { withMutableState { $0.nextIOProcID } }
        set { withMutableState { $0.nextIOProcID = newValue } }
    }

    var activeListeners: [ListenerCall] {
        Array(activeListenerCalls.values)
    }

    func enqueueAddListenerStatuses(_ statuses: [OSStatus]) {
        queuedAddListenerStatuses.append(contentsOf: statuses)
    }

    func addedAddresses(for objectID: AudioObjectID) -> [AudioHALPropertyAddress] {
        addedListeners
            .filter { $0.objectID == objectID }
            .map(\.address)
    }

    func removedAddresses(for objectID: AudioObjectID) -> [AudioHALPropertyAddress] {
        removedListeners
            .filter { $0.objectID == objectID }
            .map(\.address)
    }

    func addCount(for objectID: AudioObjectID) -> Int {
        addedAddresses(for: objectID).count
    }

    @discardableResult
    func invokeLatestListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> Bool {
        guard let listener = activeListenerCalls.values.first(where: {
            $0.objectID == objectID && $0.address == address
        }) else {
            return false
        }

        if address.selector == kAudioHardwarePropertyServiceRestarted {
            activeListenerCalls.removeAll()
        }
        invokeRetainedListener(listener)
        return true
    }

    func invokeRetainedListener(_ listener: ListenerCall) {
        var rawAddress = listener.address.rawValue
        withUnsafePointer(to: &rawAddress) { pointer in
            listener.block(1, pointer)
        }
    }

    deinit {
        for result in queuedReads {
            if case .retainedObject(let value) = result.payload {
                value.release()
            }
        }
    }

    func enqueueArrayRead<T>(announced: [T], returned: [T]) {
        queuedSizes.append(
            SizeResult(status: noErr, byteCount: UInt32(announced.count * MemoryLayout<T>.stride))
        )
        let bytes = bytes(of: returned)
        queuedReads.append(
            ReadResult(
                status: noErr,
                returnedByteCount: UInt32(bytes.count),
                payload: .bytes(bytes)
            )
        )
    }

    func enqueueBadSizeThenArray<T>(_ values: [T]) {
        let bytes = bytes(of: values)
        let firstByteCount = UInt32(max(0, bytes.count - MemoryLayout<T>.stride))
        queuedSizes.append(SizeResult(status: noErr, byteCount: firstByteCount))
        queuedReads.append(
            ReadResult(
                status: kAudioHardwareBadPropertySizeError,
                returnedByteCount: UInt32(bytes.count),
                payload: .none
            )
        )
        queuedSizes.append(SizeResult(status: noErr, byteCount: UInt32(bytes.count)))
        queuedReads.append(
            ReadResult(
                status: noErr,
                returnedByteCount: UInt32(bytes.count),
                payload: .bytes(bytes)
            )
        )
    }

    func enqueueRawSize(_ byteCount: UInt32) {
        queuedSizes.append(SizeResult(status: noErr, byteCount: byteCount))
    }

    func enqueueRetainedString(_ value: CFString) {
        enqueueRetainedObject(value)
    }

    func enqueueRetainedObject<T: AnyObject>(
        _ value: T,
        returnedByteCount: UInt32 = UInt32(MemoryLayout<Unmanaged<T>?>.size)
    ) {
        let retained = Unmanaged.passRetained(value)
        queuedReads.append(
            ReadResult(
                status: noErr,
                returnedByteCount: returnedByteCount,
                payload: .retainedObject(
                    Unmanaged<AnyObject>.fromOpaque(retained.toOpaque())
                )
            )
        )
    }

    func setScalar<T>(
        _ value: T,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        isSettable: Bool = false
    ) {
        properties[PropertyKey(objectID: objectID, address: address)] = Property(
            payload: .bytes(bytes(of: value)),
            isSettable: isSettable
        )
    }

    func setArray<T>(
        _ values: [T],
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) {
        properties[PropertyKey(objectID: objectID, address: address)] = Property(
            payload: .bytes(bytes(of: values))
        )
    }

    func setString(
        _ value: String,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) {
        properties[PropertyKey(objectID: objectID, address: address)] = Property(
            payload: .retainedString(value)
        )
    }

    func setRetainedObject<T: AnyObject>(
        _ value: T,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) {
        properties[PropertyKey(objectID: objectID, address: address)] = Property(
            payload: .retainedObject(value)
        )
    }

    func setReadError(
        _ status: OSStatus,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        announcedByteCount: UInt32
    ) {
        properties[PropertyKey(objectID: objectID, address: address)] = Property(
            payload: .bytes(Array(repeating: 0, count: Int(announcedByteCount))),
            readStatus: status
        )
    }

    func hasProperty(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> Bool {
        properties[PropertyKey(objectID: objectID, address: address)] != nil
    }

    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: inout UInt32
    ) -> OSStatus {
        dataSizeCallCount += 1
        readSelectors.append(address.selector)

        if !queuedSizes.isEmpty {
            let result = queuedSizes.removeFirst()
            byteCount = result.byteCount
            return result.status
        }

        guard let property = properties[PropertyKey(objectID: objectID, address: address)] else {
            return kAudioHardwareUnknownPropertyError
        }
        byteCount = property.payload.byteCount
        return noErr
    }

    func getPropertyData(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        readSelectors.append(address.selector)

        if !queuedReads.isEmpty {
            let result = queuedReads.removeFirst()
            let availableByteCount = byteCount
            byteCount = result.returnedByteCount
            copy(
                result.payload,
                to: data,
                availableByteCount: availableByteCount,
                returnedByteCount: result.returnedByteCount
            )
            return result.status
        }

        guard let property = properties[PropertyKey(objectID: objectID, address: address)] else {
            return kAudioHardwareUnknownPropertyError
        }
        guard property.readStatus == noErr else {
            return property.readStatus
        }

        let availableByteCount = byteCount
        byteCount = property.payload.byteCount
        switch property.payload {
        case .bytes(let bytes):
            copy(
                .bytes(bytes),
                to: data,
                availableByteCount: availableByteCount,
                returnedByteCount: UInt32(bytes.count)
            )
        case .retainedObject(let object):
            let value = Unmanaged.passRetained(object)
            copy(
                .retainedObject(
                    Unmanaged<AnyObject>.fromOpaque(value.toOpaque())
                ),
                to: data,
                availableByteCount: availableByteCount,
                returnedByteCount: property.payload.byteCount
            )
        case .retainedString(let string):
            let value = Unmanaged.passRetained(string as CFString)
            copy(
                .retainedObject(
                    Unmanaged<AnyObject>.fromOpaque(value.toOpaque())
                ),
                to: data,
                availableByteCount: availableByteCount,
                returnedByteCount: property.payload.byteCount
            )
        }
        return noErr
    }

    func setPropertyData(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus {
        writeSelectors.append(address.selector)
        let key = PropertyKey(objectID: objectID, address: address)
        if byteCount == MemoryLayout<Unmanaged<AnyObject>?>.size {
            let objectPointer = data.load(as: UnsafeMutableRawPointer?.self)
            let status = withMutableState { state in
                state.objectWrites.append(
                    ObjectWrite(
                        objectID: objectID,
                        address: address,
                        objectPointer: objectPointer
                    )
                )
                return state.objectWriteStatus
            }
            if status != noErr || properties[key] == nil {
                return status
            }
        }
        guard var property = properties[key] else {
            return kAudioHardwareUnknownPropertyError
        }
        property.payload = .bytes(
            Array(UnsafeRawBufferPointer(start: data, count: Int(byteCount)))
        )
        properties[key] = property
        return noErr
    }

    func isPropertySettable(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        isSettable: inout DarwinBoolean
    ) -> OSStatus {
        guard let property = properties[PropertyKey(objectID: objectID, address: address)] else {
            return kAudioHardwareUnknownPropertyError
        }
        isSettable = DarwinBoolean(property.isSettable)
        return noErr
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        registration: AudioHALListenerRegistration
    ) -> OSStatus {
        let call = ListenerCall(
            objectID: objectID,
            address: address,
            queue: queue,
            registration: registration
        )
        addedListeners.append(call)
        let status = queuedAddListenerStatuses.isEmpty
            ? addListenerStatus
            : queuedAddListenerStatuses.removeFirst()
        if status == noErr {
            activeListenerCalls[call.registrationIdentifier] = call
        }
        return status
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        registration: AudioHALListenerRegistration
    ) -> OSStatus {
        let call = ListenerCall(
            objectID: objectID,
            address: address,
            queue: queue,
            registration: registration
        )
        removedListeners.append(call)
        if removeListenerStatus == noErr {
            activeListenerCalls[call.registrationIdentifier] = nil
        }
        return removeListenerStatus
    }

    @available(macOS 14.2, *)
    func createProcessTap(
        _ description: CATapDescription,
        objectID: inout AudioObjectID
    ) -> OSStatus {
        let result = withMutableState { state -> (OSStatus, AudioObjectID) in
            state.operations.append(.createTap)
            state.createdProcessTapDescriptions.append(description)
            return (state.createProcessTapStatus, state.nextProcessTapID)
        }
        if result.0 == noErr {
            objectID = result.1
        }
        return result.0
    }

    @available(macOS 14.2, *)
    func destroyProcessTap(_ objectID: AudioObjectID) -> OSStatus {
        withMutableState { state in
            state.operations.append(.destroyTap)
            state.destroyedProcessTapIDs.append(objectID)
            return state.destroyProcessTapStatus
        }
    }

    func createAggregateDevice(
        _ description: CFDictionary,
        objectID: inout AudioObjectID
    ) -> OSStatus {
        let result = withMutableState { state -> (OSStatus, AudioDeviceID) in
            state.operations.append(.createAggregate)
            state.createdAggregateDeviceDescriptions.append(description)
            return (state.createAggregateDeviceStatus, state.nextAggregateDeviceID)
        }
        if result.0 == noErr {
            objectID = result.1
        }
        return result.0
    }

    func destroyAggregateDevice(_ objectID: AudioObjectID) -> OSStatus {
        withMutableState { state in
            state.operations.append(.destroyAggregate)
            state.destroyedAggregateDeviceIDs.append(objectID)
            return state.destroyAggregateDeviceStatus
        }
    }

    func createIOProc(
        deviceID: AudioDeviceID,
        callback: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?,
        ioProcID: inout AudioDeviceIOProcID?
    ) -> OSStatus {
        let result = withMutableState { state -> (OSStatus, AudioDeviceIOProcID?) in
            state.operations.append(.createIOProc)
            state.ioProcCreations.append(
                IOProcCreation(
                    deviceID: deviceID,
                    callback: callback,
                    clientData: clientData
                )
            )
            return (state.createIOProcStatus, state.nextIOProcID)
        }
        if result.0 == noErr {
            ioProcID = result.1
        }
        return result.0
    }

    func destroyIOProc(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus {
        withMutableState { state in
            state.operations.append(.destroyIOProc)
            return state.destroyIOProcStatus
        }
    }

    func startDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus {
        withMutableState { state in
            state.operations.append(.startDevice)
            return state.startDeviceStatus
        }
    }

    func stopDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus {
        withMutableState { state in
            state.operations.append(.stopDevice)
            return state.stopDeviceStatus
        }
    }

    private func withMutableState<Result>(
        _ body: (inout MutableState) -> Result
    ) -> Result {
        mutableStateLock.lock()
        defer { mutableStateLock.unlock() }
        return body(&mutableState)
    }

    private func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    private func bytes<T>(of values: [T]) -> [UInt8] {
        values.withUnsafeBytes { Array($0) }
    }

    private func copy(
        _ payload: ReadPayload,
        to data: UnsafeMutableRawPointer,
        availableByteCount: UInt32,
        returnedByteCount: UInt32
    ) {
        switch payload {
        case .bytes(let bytes):
            let count = min(Int(availableByteCount), Int(returnedByteCount), bytes.count)
            guard count > 0 else { return }
            bytes.withUnsafeBytes { source in
                data.copyMemory(from: source.baseAddress!, byteCount: count)
            }
        case .retainedObject(let value):
            guard availableByteCount >= MemoryLayout<Unmanaged<CFString>?>.size else {
                value.release()
                return
            }
            var pointer: UnsafeMutableRawPointer? = value.toOpaque()
            withUnsafeBytes(of: &pointer) { source in
                data.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        case .none:
            break
        }
    }
}
