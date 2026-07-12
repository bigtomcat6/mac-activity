import CoreAudio
import CoreFoundation
import XCTest
@testable import MacActivityCore

final class AudioHALClientTests: XCTestCase {
    func testIOProcUsageWritesAndReadsExactOneStream() throws {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyIOProcStreamUsage,
            scope: kAudioObjectPropertyScopeInput
        )
        AudioIOProcStreamUsage.withEncoded(ioProcID: testIOProcID, flags: [0]) { bytes in
            backend.setArray(
                Array(bytes),
                objectID: 700,
                address: address
            )
        }
        let client = AudioHALClient(backend: backend)

        try client.writeIOProcStreamUsage(
            [1], deviceID: 700, ioProcID: testIOProcID,
            scope: kAudioObjectPropertyScopeInput
        )
        XCTAssertEqual(
            try client.readIOProcStreamUsage(
                streamCount: 1,
                deviceID: 700,
                ioProcID: testIOProcID,
                scope: kAudioObjectPropertyScopeInput
            ),
            [1]
        )
    }

    func testIOProcUsageDecodeRejectsWrongFunctionPointer() throws {
        try AudioIOProcStreamUsage.withEncoded(ioProcID: testIOProcID, flags: [1]) { bytes in
            XCTAssertThrowsError(
                try AudioIOProcStreamUsage.decode(
                    UnsafeRawBufferPointer(bytes),
                    expectedIOProcID: alternateTestIOProcID,
                    expectedStreamCount: 1
                )
            ) { error in
                XCTAssertEqual(error as? AudioIOProcStreamUsageError, .ioProcMismatch)
            }
        }
    }

    func testIOProcUsageDecodesIndependentTwoFlagSDKBufferAndRejectsCorruption() throws {
        let streamCount = 2
        let expectedByteCount = MemoryLayout<AudioHardwareIOProcStreamUsage>.size
            + MemoryLayout<UInt32>.stride
        let flagOffset = try XCTUnwrap(
            MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(
                of: \AudioHardwareIOProcStreamUsage.mStreamIsOn
            )
        )
        XCTAssertEqual(
            flagOffset,
            MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        )
        XCTAssertEqual(
            AudioIOProcStreamUsage.byteCount(streamCount: streamCount),
            expectedByteCount
        )

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: expectedByteCount,
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        let header = storage.bindMemory(
            to: AudioHardwareIOProcStreamUsage.self,
            capacity: 1
        )
        header.initialize(to: AudioHardwareIOProcStreamUsage(
            mIOProc: unsafeBitCast(testIOProcID, to: UnsafeMutableRawPointer.self),
            mNumberStreams: UInt32(streamCount),
            mStreamIsOn: (1)
        ))
        storage.advanced(by: flagOffset + MemoryLayout<UInt32>.stride)
            .storeBytes(of: UInt32(0), as: UInt32.self)
        defer {
            header.deinitialize(count: 1)
            storage.deallocate()
        }

        let bytes = UnsafeRawBufferPointer(start: storage, count: expectedByteCount)
        XCTAssertEqual(
            try AudioIOProcStreamUsage.decode(
                bytes,
                expectedIOProcID: testIOProcID,
                expectedStreamCount: streamCount
            ),
            [1, 0]
        )

        header.pointee.mNumberStreams = 3
        XCTAssertThrowsError(try AudioIOProcStreamUsage.decode(
            bytes,
            expectedIOProcID: testIOProcID,
            expectedStreamCount: streamCount
        )) { error in
            XCTAssertEqual(error as? AudioIOProcStreamUsageError, .streamCountMismatch)
        }
    }
    func testReadArrayUsesReturnedByteCountAfterShrink() throws {
        let backend = FakeAudioHALBackend()
        backend.enqueueArrayRead(announced: [UInt32(11), 22, 33], returned: [11, 22])
        let client = AudioHALClient(backend: backend)

        let values = try client.readArray(
            UInt32.self,
            from: 1,
            address: .init(selector: kAudioHardwarePropertyDevices)
        )

        XCTAssertEqual(values, [11, 22])
    }

    func testReadArrayRetriesGrowingPropertyOnce() throws {
        let backend = FakeAudioHALBackend()
        backend.enqueueBadSizeThenArray([UInt32(11), 22, 33])
        let client = AudioHALClient(backend: backend)

        XCTAssertEqual(
            try client.readArray(
                UInt32.self,
                from: 1,
                address: .init(selector: kAudioHardwarePropertyDevices),
                maxAttempts: 3
            ),
            [11, 22, 33]
        )
        XCTAssertEqual(backend.dataSizeCallCount, 2)
    }

    func testMalformedArraySizeIsTyped() {
        let backend = FakeAudioHALBackend()
        backend.enqueueRawSize(3)
        let client = AudioHALClient(backend: backend)

        XCTAssertThrowsError(
            try client.readArray(
                UInt32.self,
                from: 1,
                address: .init(selector: kAudioHardwarePropertyDevices)
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioHALError,
                AudioHALError(
                    operation: .getDataSize,
                    objectID: 1,
                    address: .init(selector: kAudioHardwarePropertyDevices),
                    reason: .invalidDataSize(byteCount: 3, elementStride: 4)
                )
            )
        }
    }

    func testRetainedStringIsConsumedExactlyOnce() throws {
        let backend = FakeAudioHALBackend()
        let value = CFStringCreateMutable(kCFAllocatorDefault, 0)!
        CFStringAppend(value, "Music" as CFString)
        let before = CFGetRetainCount(value)
        backend.enqueueRetainedString(value)

        XCTAssertEqual(
            try AudioHALClient(backend: backend).readRetainedString(
                from: 10,
                address: .init(selector: kAudioObjectPropertyName)
            ),
            "Music"
        )
        let after = CFGetRetainCount(value)
        XCTAssertEqual(after, before)
    }

    func testAggregateCreateCoversSuccessAndStatusFailureMetadata() throws {
        let description = ["uid": "com.how.macactivity.test"] as CFDictionary

        let successBackend = FakeAudioHALBackend()
        successBackend.nextAggregateDeviceID = 701
        XCTAssertEqual(
            try AudioHALClient(backend: successBackend).createAggregateDevice(description),
            701
        )
        XCTAssertEqual(
            successBackend.mutableOperations,
            [AudioHALOperation.createAggregate]
        )

        let failureBackend = FakeAudioHALBackend()
        failureBackend.createAggregateDeviceStatus = -701
        assertHALFailure(
            operation: .createAggregate,
            objectID: kAudioObjectUnknown,
            status: -701
        ) {
            _ = try AudioHALClient(backend: failureBackend).createAggregateDevice(description)
        }
        XCTAssertEqual(
            failureBackend.mutableOperations,
            [AudioHALOperation.createAggregate]
        )
    }

    @available(macOS 14.2, *)
    func testProcessTapCreateChecksAvailabilityBeforeTouchingBackend() {
        let backend = FakeAudioHALBackend()
        let description = CATapDescription(stereoMixdownOfProcesses: [])
        let client = AudioHALClient(backend: backend, processTapsAvailable: false)

        XCTAssertThrowsError(try client.createProcessTap(description)) { error in
            XCTAssertEqual(
                error as? AudioHALError,
                AudioHALError(
                    operation: .createTap,
                    objectID: kAudioObjectUnknown,
                    address: nil,
                    reason: .processTapsUnavailable
                )
            )
        }
        XCTAssertTrue(backend.mutableOperations.isEmpty)
    }

    @available(macOS 14.2, *)
    func testProcessTapCreateCoversSuccessAndStatusFailure() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [])

        let successBackend = FakeAudioHALBackend()
        successBackend.nextProcessTapID = 702
        XCTAssertEqual(
            try AudioHALClient(backend: successBackend).createProcessTap(description),
            702
        )
        XCTAssertEqual(successBackend.mutableOperations, [AudioHALOperation.createTap])

        let failureBackend = FakeAudioHALBackend()
        failureBackend.createProcessTapStatus = -702
        assertHALFailure(
            operation: .createTap,
            objectID: kAudioObjectUnknown,
            status: -702
        ) {
            _ = try AudioHALClient(backend: failureBackend).createProcessTap(description)
        }
        XCTAssertEqual(failureBackend.mutableOperations, [AudioHALOperation.createTap])
    }

    @available(macOS 14.2, *)
    func testDestroyTapAndAggregatePreserveExactOperationObjectAndStatus() {
        let cases: [(
            operation: AudioHALOperation,
            objectID: AudioObjectID,
            status: OSStatus,
            configure: (FakeAudioHALBackend) -> Void,
            invoke: (AudioHALClient, AudioObjectID) throws -> Void
        )] = [
            (
                .destroyTap,
                703,
                -703,
                { $0.destroyProcessTapStatus = -703 },
                { try $0.destroyProcessTap($1) }
            ),
            (
                .destroyAggregate,
                704,
                -704,
                { $0.destroyAggregateDeviceStatus = -704 },
                { try $0.destroyAggregateDevice($1) }
            ),
        ]

        for testCase in cases {
            let backend = FakeAudioHALBackend()
            testCase.configure(backend)
            assertHALFailure(
                operation: testCase.operation,
                objectID: testCase.objectID,
                status: testCase.status
            ) {
                try testCase.invoke(AudioHALClient(backend: backend), testCase.objectID)
            }
            XCTAssertEqual(backend.mutableOperations, [testCase.operation])
        }
    }

    func testIOProcCreateCoversSuccessMissingValueAndStatusFailure() throws {
        let deviceID: AudioDeviceID = 705
        let expectedIOProcID: AudioDeviceIOProcID = testAudioDeviceIOProc
        let clientData: UnsafeMutableRawPointer? = nil

        let successBackend = FakeAudioHALBackend()
        successBackend.nextIOProcID = expectedIOProcID
        let createdIOProcID = try AudioHALClient(backend: successBackend).createIOProc(
            deviceID: deviceID,
            callback: testAudioDeviceIOProc,
            clientData: clientData
        )
        XCTAssertEqual(
            ioProcIdentity(createdIOProcID),
            ioProcIdentity(expectedIOProcID)
        )

        let missingBackend = FakeAudioHALBackend()
        let missingIOProcID: AudioDeviceIOProcID? = nil
        missingBackend.nextIOProcID = missingIOProcID
        assertHALError(
            AudioHALError(
                operation: .createIOProc,
                objectID: deviceID,
                address: nil,
                reason: .missingValue
            )
        ) {
            _ = try AudioHALClient(backend: missingBackend).createIOProc(
                deviceID: deviceID,
                callback: testAudioDeviceIOProc,
                clientData: clientData
            )
        }

        let failureBackend = FakeAudioHALBackend()
        failureBackend.createIOProcStatus = -705
        assertHALFailure(operation: .createIOProc, objectID: deviceID, status: -705) {
            _ = try AudioHALClient(backend: failureBackend).createIOProc(
                deviceID: deviceID,
                callback: testAudioDeviceIOProc,
                clientData: clientData
            )
        }
    }

    func testIOProcLifecycleRecordsDestroyStartStopOrdering() throws {
        let backend = FakeAudioHALBackend()
        let deviceID: AudioDeviceID = 706
        let ioProcID: AudioDeviceIOProcID = testAudioDeviceIOProc
        let clientData: UnsafeMutableRawPointer? = nil
        backend.nextIOProcID = ioProcID
        let client = AudioHALClient(backend: backend)

        let createdID = try client.createIOProc(
            deviceID: deviceID,
            callback: testAudioDeviceIOProc,
            clientData: clientData
        )
        try client.startDevice(deviceID: deviceID, ioProcID: createdID)
        try client.stopDevice(deviceID: deviceID, ioProcID: createdID)
        try client.destroyIOProc(deviceID: deviceID, ioProcID: createdID)

        XCTAssertEqual(
            backend.mutableOperations,
            [
                AudioHALOperation.createIOProc,
                .startDevice,
                .stopDevice,
                .destroyIOProc,
            ]
        )
    }

    func testRetainedCFObjectIsConsumedOnceAndMalformedSizeIsCleanedUp() throws {
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)

        let successBackend = FakeAudioHALBackend()
        let successValue = CFStringCreateMutable(kCFAllocatorDefault, 0)!
        CFStringAppend(successValue, "Success" as CFString)
        let successRetainCount = CFGetRetainCount(successValue)
        successBackend.enqueueRetainedObject(successValue)
        try autoreleasepool {
            let returned = try AudioHALClient(backend: successBackend).readRetainedObject(
                CFString.self,
                from: 707,
                address: address
            )
            XCTAssertTrue(CFEqual(returned, successValue))
        }
        let observedSuccessRetainCount = CFGetRetainCount(successValue)
        XCTAssertEqual(observedSuccessRetainCount, successRetainCount)

        let malformedBackend = FakeAudioHALBackend()
        let malformedValue = CFStringCreateMutable(kCFAllocatorDefault, 0)!
        let malformedRetainCount = CFGetRetainCount(malformedValue)
        malformedBackend.enqueueRetainedObject(malformedValue, returnedByteCount: 1)
        assertHALError(
            AudioHALError(
                operation: .getData,
                objectID: 708,
                address: address,
                reason: .invalidDataSize(
                    byteCount: 1,
                    elementStride: MemoryLayout<Unmanaged<CFString>?>.stride
                )
            )
        ) {
            _ = try AudioHALClient(backend: malformedBackend).readRetainedObject(
                CFString.self,
                from: 708,
                address: address
            )
        }
        let observedMalformedRetainCount = CFGetRetainCount(malformedValue)
        XCTAssertEqual(observedMalformedRetainCount, malformedRetainCount)
    }

    func testCFObjectWritePassesUnretainedReferenceAndPreservesAddressAndStatus() throws {
        let address = AudioHALPropertyAddress(
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeInput,
            element: 3
        )
        let value = CFStringCreateMutable(kCFAllocatorDefault, 0)!
        let pointer = Unmanaged.passUnretained(value).toOpaque()

        let successBackend = FakeAudioHALBackend()
        let retainCount = CFGetRetainCount(value)
        try AudioHALClient(backend: successBackend).writeObject(
            value,
            to: 709,
            address: address
        )
        let observedRetainCount = CFGetRetainCount(value)
        XCTAssertEqual(observedRetainCount, retainCount)
        XCTAssertEqual(successBackend.objectWrites.count, 1)
        XCTAssertEqual(successBackend.objectWrites[0].objectID, 709)
        XCTAssertEqual(successBackend.objectWrites[0].address, address)
        XCTAssertEqual(successBackend.objectWrites[0].objectPointer, pointer)

        let failureBackend = FakeAudioHALBackend()
        failureBackend.objectWriteStatus = -709
        assertHALFailure(
            operation: .setData,
            objectID: 710,
            address: address,
            status: -709
        ) {
            try AudioHALClient(backend: failureBackend).writeObject(
                value,
                to: 710,
                address: address
            )
        }
        XCTAssertEqual(failureBackend.objectWrites.first?.address, address)
    }

    func testListenerCancellationUsesExactRegistrationAndIsIdempotent() throws {
        let backend = FakeAudioHALBackend()
        let client = AudioHALClient(backend: backend)
        let queue = DispatchQueue(label: "AudioHALClientTests.listener")
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        let token = try client.addPropertyListener(
            objectID: 42,
            address: address,
            queue: queue,
            handler: {}
        )

        try token.cancel()
        try token.cancel()

        XCTAssertEqual(backend.addedListeners.count, 1)
        XCTAssertEqual(backend.removedListeners.count, 1)
        XCTAssertEqual(backend.removedListeners[0].objectID, 42)
        XCTAssertEqual(backend.removedListeners[0].address, address)
        XCTAssertTrue(backend.removedListeners[0].queue === backend.addedListeners[0].queue)
        XCTAssertEqual(
            backend.removedListeners[0].registrationIdentifier,
            backend.addedListeners[0].registrationIdentifier
        )
    }

    func testListenerRegistrationsHaveDistinctStableIdentities() throws {
        let backend = FakeAudioHALBackend()
        let client = AudioHALClient(backend: backend)
        let queue = DispatchQueue(label: "AudioHALClientTests.identities")
        let firstToken = try client.addPropertyListener(
            objectID: 41,
            address: .init(selector: kAudioObjectPropertyName),
            queue: queue,
            handler: {}
        )
        let secondToken = try client.addPropertyListener(
            objectID: 42,
            address: .init(selector: kAudioObjectPropertyName),
            queue: queue,
            handler: {}
        )

        XCTAssertNotEqual(
            backend.addedListeners[0].registrationIdentifier,
            backend.addedListeners[1].registrationIdentifier
        )

        try firstToken.cancel()
        try secondToken.cancel()

        XCTAssertEqual(
            backend.removedListeners.map(\.registrationIdentifier),
            backend.addedListeners.map(\.registrationIdentifier)
        )
    }

    func testInvalidatedListenerDoesNotRemoveARegistrationOwnedByRestartedHAL() throws {
        let backend = FakeAudioHALBackend()
        let token = try AudioHALClient(backend: backend).addPropertyListener(
            objectID: 42,
            address: .init(selector: kAudioObjectPropertyName),
            queue: DispatchQueue(label: "AudioHALClientTests.restart"),
            handler: {}
        )

        token.invalidateAfterServiceRestart()
        try token.cancel()

        XCTAssertTrue(backend.removedListeners.isEmpty)
    }

    private func assertHALFailure(
        operation: AudioHALOperation,
        objectID: AudioObjectID,
        address: AudioHALPropertyAddress? = nil,
        status: OSStatus,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        assertHALError(
            AudioHALError(
                operation: operation,
                objectID: objectID,
                address: address,
                reason: .status(status)
            ),
            file: file,
            line: line,
            body
        )
    }

    private func assertHALError(
        _ expected: AudioHALError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? AudioHALError, expected, file: file, line: line)
        }
    }
}

private let testIOProcID: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }
private let alternateTestIOProcID: AudioDeviceIOProcID = { _, _, _, _, _, _, _ in noErr }

private let testAudioDeviceIOProc: AudioDeviceIOProc = { _, _, _, _, _, _, _ in
    noErr
}

private func ioProcIdentity(_ ioProcID: AudioDeviceIOProcID) -> UInt {
    unsafeBitCast(ioProcID, to: UInt.self)
}
