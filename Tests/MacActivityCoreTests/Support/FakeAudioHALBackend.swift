import CoreAudio
import CoreFoundation
import Dispatch
@testable import MacActivityCore

final class FakeAudioHALBackend: AudioHALBackend, @unchecked Sendable {
    struct ListenerCall {
        let objectID: AudioObjectID
        let address: AudioHALPropertyAddress
        let queue: DispatchQueue
        let block: AudioObjectPropertyListenerBlock

        var blockIdentifier: ObjectIdentifier {
            ObjectIdentifier(block as AnyObject)
        }
    }

    private struct PropertyKey: Hashable {
        let objectID: AudioObjectID
        let address: AudioHALPropertyAddress
    }

    private enum PropertyPayload {
        case bytes([UInt8])
        case retainedString(String)

        var byteCount: UInt32 {
            switch self {
            case .bytes(let bytes):
                UInt32(bytes.count)
            case .retainedString:
                UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
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
        case retainedString(Unmanaged<CFString>)
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

    private(set) var dataSizeCallCount = 0
    private(set) var readSelectors: [AudioObjectPropertySelector] = []
    private(set) var writeSelectors: [AudioObjectPropertySelector] = []
    private(set) var addedListeners: [ListenerCall] = []
    private(set) var removedListeners: [ListenerCall] = []

    var addListenerStatus: OSStatus = noErr
    var removeListenerStatus: OSStatus = noErr

    deinit {
        for result in queuedReads {
            if case .retainedString(let value) = result.payload {
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
        let retained = Unmanaged.passRetained(value)
        queuedReads.append(
            ReadResult(
                status: noErr,
                returnedByteCount: UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                payload: .retainedString(retained)
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
        case .retainedString(let string):
            let value = Unmanaged.passRetained(string as CFString)
            copy(
                .retainedString(value),
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
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        addedListeners.append(
            ListenerCall(objectID: objectID, address: address, queue: queue, block: block)
        )
        return addListenerStatus
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        removedListeners.append(
            ListenerCall(objectID: objectID, address: address, queue: queue, block: block)
        )
        return removeListenerStatus
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
        case .retainedString(let value):
            guard availableByteCount >= MemoryLayout<Unmanaged<CFString>?>.size else {
                value.release()
                return
            }
            data.assumingMemoryBound(to: Unmanaged<CFString>?.self).pointee = value
        case .none:
            break
        }
    }
}
