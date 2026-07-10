import CoreAudio
import Foundation

protocol AudioHALBackend: AnyObject, Sendable {
    func hasProperty(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> Bool
    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: inout UInt32
    ) -> OSStatus
    func getPropertyData(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus
    func setPropertyData(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus
    func isPropertySettable(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        isSettable: inout DarwinBoolean
    ) -> OSStatus
    func addPropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
    func removePropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus
}

final class CoreAudioHALBackend: AudioHALBackend, @unchecked Sendable {
    func hasProperty(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> Bool {
        var rawAddress = address.rawValue
        return AudioObjectHasProperty(objectID, &rawAddress)
    }

    func getPropertyDataSize(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: inout UInt32
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectGetPropertyDataSize(objectID, &rawAddress, 0, nil, &byteCount)
    }

    func getPropertyData(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: inout UInt32,
        data: UnsafeMutableRawPointer
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectGetPropertyData(
            objectID,
            &rawAddress,
            0,
            nil,
            &byteCount,
            data
        )
    }

    func setPropertyData(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        byteCount: UInt32,
        data: UnsafeRawPointer
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectSetPropertyData(
            objectID,
            &rawAddress,
            0,
            nil,
            byteCount,
            data
        )
    }

    func isPropertySettable(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        isSettable: inout DarwinBoolean
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectIsPropertySettable(objectID, &rawAddress, &isSettable)
    }

    func addPropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectAddPropertyListenerBlock(objectID, &rawAddress, queue, block)
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectRemovePropertyListenerBlock(objectID, &rawAddress, queue, block)
    }
}

public final class AudioHALClient: @unchecked Sendable {
    public static let system = AudioHALClient()

    private let backend: any AudioHALBackend

    init(backend: any AudioHALBackend = CoreAudioHALBackend()) {
        self.backend = backend
    }

    public func hasProperty(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) -> Bool {
        backend.hasProperty(objectID: objectID, address: address)
    }

    public func isPropertySettable(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> Bool {
        var isSettable: DarwinBoolean = false
        let status = backend.isPropertySettable(
            objectID: objectID,
            address: address,
            isSettable: &isSettable
        )
        try check(
            status,
            operation: .isSettable,
            objectID: objectID,
            address: address
        )
        return isSettable.boolValue
    }

    public func readScalar<T>(
        _ type: T.Type,
        from objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> T {
        let expectedByteCount = UInt32(MemoryLayout<T>.size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: max(1, Int(expectedByteCount)),
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }

        var returnedByteCount = expectedByteCount
        let status = backend.getPropertyData(
            objectID: objectID,
            address: address,
            byteCount: &returnedByteCount,
            data: storage
        )
        try check(status, operation: .getData, objectID: objectID, address: address)
        guard returnedByteCount == expectedByteCount, expectedByteCount > 0 else {
            throw AudioHALError(
                operation: .getData,
                objectID: objectID,
                address: address,
                reason: .invalidDataSize(
                    byteCount: returnedByteCount,
                    elementStride: MemoryLayout<T>.stride
                )
            )
        }

        return storage.load(as: T.self)
    }

    public func readRetainedString(
        from objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> String {
        var value: Unmanaged<CFString>? = .none
        var returnedByteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            backend.getPropertyData(
                objectID: objectID,
                address: address,
                byteCount: &returnedByteCount,
                data: pointer
            )
        }
        try check(status, operation: .getData, objectID: objectID, address: address)

        guard returnedByteCount == MemoryLayout<Unmanaged<CFString>?>.size else {
            if let value {
                _ = value.takeRetainedValue()
            }
            throw AudioHALError(
                operation: .getData,
                objectID: objectID,
                address: address,
                reason: .invalidDataSize(
                    byteCount: returnedByteCount,
                    elementStride: MemoryLayout<Unmanaged<CFString>?>.stride
                )
            )
        }
        guard let value else {
            throw AudioHALError(
                operation: .getData,
                objectID: objectID,
                address: address,
                reason: .missingValue
            )
        }

        let string = autoreleasepool {
            let retainedValue = value.takeRetainedValue()
            let bytes = Array((retainedValue as String).utf8)
            guard let string = String(bytes: bytes, encoding: .utf8) else {
                preconditionFailure("CFString must produce valid UTF-8")
            }
            return string
        }
        return string
    }

    public func readArray<T>(
        _ type: T.Type,
        from objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        maxAttempts: Int = 3
    ) throws -> [T] {
        let elementStride = MemoryLayout<T>.stride
        guard elementStride > 0 else {
            throw AudioHALError(
                operation: .getDataSize,
                objectID: objectID,
                address: address,
                reason: .invalidDataSize(byteCount: 0, elementStride: elementStride)
            )
        }

        for attempt in 0..<maxAttempts {
            let announcedByteCount = try propertyDataSize(
                objectID: objectID,
                address: address
            )
            guard announcedByteCount % UInt32(elementStride) == 0 else {
                throw AudioHALError(
                    operation: .getDataSize,
                    objectID: objectID,
                    address: address,
                    reason: .invalidDataSize(
                        byteCount: announcedByteCount,
                        elementStride: elementStride
                    )
                )
            }
            guard announcedByteCount > 0 else { return [] }

            let storage = UnsafeMutableRawPointer.allocate(
                byteCount: Int(announcedByteCount),
                alignment: MemoryLayout<T>.alignment
            )
            defer { storage.deallocate() }

            var returnedByteCount = announcedByteCount
            let status = backend.getPropertyData(
                objectID: objectID,
                address: address,
                byteCount: &returnedByteCount,
                data: storage
            )

            if status == kAudioHardwareBadPropertySizeError
                || returnedByteCount > announcedByteCount {
                if attempt + 1 < maxAttempts { continue }
                throw AudioHALError(
                    operation: .getData,
                    objectID: objectID,
                    address: address,
                    reason: .retryLimitExceeded
                )
            }
            try check(status, operation: .getData, objectID: objectID, address: address)
            guard returnedByteCount % UInt32(elementStride) == 0 else {
                throw AudioHALError(
                    operation: .getData,
                    objectID: objectID,
                    address: address,
                    reason: .invalidDataSize(
                        byteCount: returnedByteCount,
                        elementStride: elementStride
                    )
                )
            }

            return copyTrivialValues(
                T.self,
                from: storage,
                count: Int(returnedByteCount) / elementStride
            )
        }
        throw AudioHALError(
            operation: .getData,
            objectID: objectID,
            address: address,
            reason: .retryLimitExceeded
        )
    }

    public func writeScalar<T>(
        _ value: T,
        to objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws {
        var value = value
        let status = withUnsafePointer(to: &value) { pointer in
            backend.setPropertyData(
                objectID: objectID,
                address: address,
                byteCount: UInt32(MemoryLayout<T>.size),
                data: pointer
            )
        }
        try check(status, operation: .setData, objectID: objectID, address: address)
    }

    public func addPropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) throws -> AudioHALListenerToken {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = backend.addPropertyListener(
            objectID: objectID,
            address: address,
            queue: queue,
            block: block
        )
        try check(status, operation: .addListener, objectID: objectID, address: address)
        return AudioHALListenerToken(
            backend: backend,
            objectID: objectID,
            address: address,
            queue: queue,
            block: block
        )
    }

    private func propertyDataSize(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> UInt32 {
        var byteCount: UInt32 = 0
        let status = backend.getPropertyDataSize(
            objectID: objectID,
            address: address,
            byteCount: &byteCount
        )
        try check(
            status,
            operation: .getDataSize,
            objectID: objectID,
            address: address
        )
        return byteCount
    }

    private func check(
        _ status: OSStatus,
        operation: AudioHALOperation,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress?
    ) throws {
        guard status == noErr else {
            throw AudioHALError(
                operation: operation,
                objectID: objectID,
                address: address,
                reason: .status(status)
            )
        }
    }

    private func copyTrivialValues<T>(
        _ type: T.Type,
        from storage: UnsafeMutableRawPointer,
        count: Int
    ) -> [T] {
        guard count > 0 else { return [] }
        let values = storage.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: values, count: count))
    }
}

public final class AudioHALListenerToken: @unchecked Sendable {
    private let backend: any AudioHALBackend
    private let objectID: AudioObjectID
    private let address: AudioHALPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private let lock = NSLock()
    private var isRegistered = true

    init(
        backend: any AudioHALBackend,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.backend = backend
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
    }

    deinit {
        try? cancel()
    }

    public func cancel() throws {
        lock.lock()
        defer { lock.unlock() }
        guard isRegistered else { return }

        let status = backend.removePropertyListener(
            objectID: objectID,
            address: address,
            queue: queue,
            block: block
        )
        guard status == noErr else {
            throw AudioHALError(
                operation: .removeListener,
                objectID: objectID,
                address: address,
                reason: .status(status)
            )
        }
        isRegistered = false
    }

    func invalidateAfterServiceRestart() {
        lock.lock()
        isRegistered = false
        lock.unlock()
    }
}
