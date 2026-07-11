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
        registration: AudioHALListenerRegistration
    ) -> OSStatus
    func removePropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        registration: AudioHALListenerRegistration
    ) -> OSStatus
    @available(macOS 14.2, *)
    func createProcessTap(
        _ description: CATapDescription,
        objectID: inout AudioObjectID
    ) -> OSStatus
    @available(macOS 14.2, *)
    func destroyProcessTap(_ objectID: AudioObjectID) -> OSStatus
    func createAggregateDevice(
        _ description: CFDictionary,
        objectID: inout AudioObjectID
    ) -> OSStatus
    func destroyAggregateDevice(_ objectID: AudioObjectID) -> OSStatus
    func createIOProc(
        deviceID: AudioDeviceID,
        callback: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?,
        ioProcID: inout AudioDeviceIOProcID?
    ) -> OSStatus
    func destroyIOProc(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus
    func startDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus
    func stopDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus
}

final class AudioHALListenerRegistration: @unchecked Sendable {
    let block: AudioObjectPropertyListenerBlock

    init(handler: @escaping @Sendable () -> Void) {
        block = { _, _ in
            handler()
        }
    }
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
        registration: AudioHALListenerRegistration
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectAddPropertyListenerBlock(
            objectID,
            &rawAddress,
            queue,
            registration.block
        )
    }

    func removePropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        registration: AudioHALListenerRegistration
    ) -> OSStatus {
        var rawAddress = address.rawValue
        return AudioObjectRemovePropertyListenerBlock(
            objectID,
            &rawAddress,
            queue,
            registration.block
        )
    }

    @available(macOS 14.2, *)
    func createProcessTap(
        _ description: CATapDescription,
        objectID: inout AudioObjectID
    ) -> OSStatus {
        AudioHardwareCreateProcessTap(description, &objectID)
    }

    @available(macOS 14.2, *)
    func destroyProcessTap(_ objectID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyProcessTap(objectID)
    }

    func createAggregateDevice(
        _ description: CFDictionary,
        objectID: inout AudioObjectID
    ) -> OSStatus {
        AudioHardwareCreateAggregateDevice(description, &objectID)
    }

    func destroyAggregateDevice(_ objectID: AudioObjectID) -> OSStatus {
        AudioHardwareDestroyAggregateDevice(objectID)
    }

    func createIOProc(
        deviceID: AudioDeviceID,
        callback: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?,
        ioProcID: inout AudioDeviceIOProcID?
    ) -> OSStatus {
        AudioDeviceCreateIOProcID(deviceID, callback, clientData, &ioProcID)
    }

    func destroyIOProc(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus {
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
    }

    func startDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus {
        AudioDeviceStart(deviceID, ioProcID)
    }

    func stopDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) -> OSStatus {
        AudioDeviceStop(deviceID, ioProcID)
    }
}

public final class AudioHALClient: @unchecked Sendable {
    public static let system = AudioHALClient()

    private let backend: any AudioHALBackend
    private let processTapsAvailable: Bool

    init(
        backend: any AudioHALBackend = CoreAudioHALBackend(),
        processTapsAvailable: Bool? = nil
    ) {
        self.backend = backend
        self.processTapsAvailable = processTapsAvailable ?? {
            if #available(macOS 14.2, *) {
                return true
            }
            return false
        }()
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

    public func readRetainedObject<T: AnyObject>(
        _ type: T.Type,
        from objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws -> T {
        var value: Unmanaged<T>? = .none
        var returnedByteCount = UInt32(MemoryLayout<Unmanaged<T>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            backend.getPropertyData(
                objectID: objectID,
                address: address,
                byteCount: &returnedByteCount,
                data: pointer
            )
        }
        let retainedValue = value?.takeRetainedValue()

        try check(status, operation: .getData, objectID: objectID, address: address)
        guard returnedByteCount == MemoryLayout<Unmanaged<T>?>.size else {
            throw AudioHALError(
                operation: .getData,
                objectID: objectID,
                address: address,
                reason: .invalidDataSize(
                    byteCount: returnedByteCount,
                    elementStride: MemoryLayout<Unmanaged<T>?>.stride
                )
            )
        }
        guard let retainedValue else {
            throw AudioHALError(
                operation: .getData,
                objectID: objectID,
                address: address,
                reason: .missingValue
            )
        }
        return retainedValue
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

    func writeIOProcStreamUsage(
        _ flags: [UInt32],
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID,
        scope: AudioObjectPropertyScope
    ) throws {
        guard flags.isEmpty == false else {
            throw AudioIOProcStreamUsageError.streamCountMismatch
        }
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyIOProcStreamUsage,
            scope: scope
        )
        try AudioIOProcStreamUsage.withEncoded(ioProcID: ioProcID, flags: flags) { bytes in
            let status = backend.setPropertyData(
                objectID: deviceID,
                address: address,
                byteCount: UInt32(bytes.count),
                data: bytes.baseAddress!
            )
            try check(status, operation: .setData, objectID: deviceID, address: address)
        }
    }

    func readIOProcStreamUsage(
        streamCount: Int,
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID,
        scope: AudioObjectPropertyScope
    ) throws -> [UInt32] {
        guard streamCount > 0 else {
            throw AudioIOProcStreamUsageError.streamCountMismatch
        }
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyIOProcStreamUsage,
            scope: scope
        )
        return try AudioIOProcStreamUsage.withEncoded(
            ioProcID: ioProcID,
            flags: Array(repeating: 0, count: streamCount)
        ) { bytes in
            var byteCount = UInt32(bytes.count)
            let status = backend.getPropertyData(
                objectID: deviceID,
                address: address,
                byteCount: &byteCount,
                data: bytes.baseAddress!
            )
            try check(status, operation: .getData, objectID: deviceID, address: address)
            guard byteCount == bytes.count else {
                throw AudioIOProcStreamUsageError.byteCountMismatch
            }
            return try AudioIOProcStreamUsage.decode(
                UnsafeRawBufferPointer(bytes),
                expectedIOProcID: ioProcID,
                expectedStreamCount: streamCount
            )
        }
    }

    public func writeObject<T: AnyObject>(
        _ value: T,
        to objectID: AudioObjectID,
        address: AudioHALPropertyAddress
    ) throws {
        var reference = Unmanaged.passUnretained(value)
        let status = withUnsafePointer(to: &reference) { pointer in
            backend.setPropertyData(
                objectID: objectID,
                address: address,
                byteCount: UInt32(MemoryLayout<Unmanaged<T>>.size),
                data: pointer
            )
        }
        withExtendedLifetime(value) {}
        try check(status, operation: .setData, objectID: objectID, address: address)
    }

    public func createProcessTap(_ description: CATapDescription) throws -> AudioObjectID {
        guard processTapsAvailable else {
            throw AudioHALError(
                operation: .createTap,
                objectID: kAudioObjectUnknown,
                address: nil,
                reason: .processTapsUnavailable
            )
        }
        guard #available(macOS 14.2, *) else {
            throw AudioHALError(
                operation: .createTap,
                objectID: kAudioObjectUnknown,
                address: nil,
                reason: .processTapsUnavailable
            )
        }

        var objectID = kAudioObjectUnknown
        let status = withExtendedLifetime(description) {
            backend.createProcessTap(description, objectID: &objectID)
        }
        try check(
            status,
            operation: .createTap,
            objectID: kAudioObjectUnknown,
            address: nil
        )
        guard objectID != kAudioObjectUnknown else {
            throw AudioHALError(
                operation: .createTap,
                objectID: kAudioObjectUnknown,
                address: nil,
                reason: .missingValue
            )
        }
        return objectID
    }

    public func destroyProcessTap(_ objectID: AudioObjectID) throws {
        guard processTapsAvailable else {
            throw AudioHALError(
                operation: .destroyTap,
                objectID: objectID,
                address: nil,
                reason: .processTapsUnavailable
            )
        }
        guard #available(macOS 14.2, *) else {
            throw AudioHALError(
                operation: .destroyTap,
                objectID: objectID,
                address: nil,
                reason: .processTapsUnavailable
            )
        }

        try check(
            backend.destroyProcessTap(objectID),
            operation: .destroyTap,
            objectID: objectID,
            address: nil
        )
    }

    public func createAggregateDevice(_ description: CFDictionary) throws -> AudioDeviceID {
        var objectID = kAudioObjectUnknown
        let status = withExtendedLifetime(description) {
            backend.createAggregateDevice(description, objectID: &objectID)
        }
        try check(
            status,
            operation: .createAggregate,
            objectID: kAudioObjectUnknown,
            address: nil
        )
        guard objectID != kAudioObjectUnknown else {
            throw AudioHALError(
                operation: .createAggregate,
                objectID: kAudioObjectUnknown,
                address: nil,
                reason: .missingValue
            )
        }
        return objectID
    }

    public func destroyAggregateDevice(_ objectID: AudioDeviceID) throws {
        try check(
            backend.destroyAggregateDevice(objectID),
            operation: .destroyAggregate,
            objectID: objectID,
            address: nil
        )
    }

    public func createIOProc(
        deviceID: AudioDeviceID,
        callback: AudioDeviceIOProc,
        clientData: UnsafeMutableRawPointer?
    ) throws -> AudioDeviceIOProcID {
        var ioProcID: AudioDeviceIOProcID?
        let status = backend.createIOProc(
            deviceID: deviceID,
            callback: callback,
            clientData: clientData,
            ioProcID: &ioProcID
        )
        try check(
            status,
            operation: .createIOProc,
            objectID: deviceID,
            address: nil
        )
        guard let ioProcID else {
            throw AudioHALError(
                operation: .createIOProc,
                objectID: deviceID,
                address: nil,
                reason: .missingValue
            )
        }
        return ioProcID
    }

    public func destroyIOProc(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) throws {
        try check(
            backend.destroyIOProc(deviceID: deviceID, ioProcID: ioProcID),
            operation: .destroyIOProc,
            objectID: deviceID,
            address: nil
        )
    }

    public func startDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) throws {
        try check(
            backend.startDevice(deviceID: deviceID, ioProcID: ioProcID),
            operation: .startDevice,
            objectID: deviceID,
            address: nil
        )
    }

    public func stopDevice(
        deviceID: AudioDeviceID,
        ioProcID: AudioDeviceIOProcID
    ) throws {
        try check(
            backend.stopDevice(deviceID: deviceID, ioProcID: ioProcID),
            operation: .stopDevice,
            objectID: deviceID,
            address: nil
        )
    }

    public func addPropertyListener(
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) throws -> AudioHALListenerToken {
        let registration = AudioHALListenerRegistration(handler: handler)
        let status = backend.addPropertyListener(
            objectID: objectID,
            address: address,
            queue: queue,
            registration: registration
        )
        try check(status, operation: .addListener, objectID: objectID, address: address)
        return AudioHALListenerToken(
            backend: backend,
            objectID: objectID,
            address: address,
            queue: queue,
            registration: registration
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
    private let registration: AudioHALListenerRegistration
    private let lock = NSLock()
    private var isRegistered = true

    init(
        backend: any AudioHALBackend,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress,
        queue: DispatchQueue,
        registration: AudioHALListenerRegistration
    ) {
        self.backend = backend
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.registration = registration
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
            registration: registration
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
