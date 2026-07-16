import CoreAudio
import CoreFoundation
import XCTest
@testable import MacActivityCore

final class AudioHALClientTests: XCTestCase {
    func testHasPropertyReflectsBackendPresence() {
        let backend = FakeAudioHALBackend()
        let presentAddress = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        let absentAddress = AudioHALPropertyAddress(selector: kAudioObjectPropertyManufacturer)
        backend.setScalar(UInt32(0), objectID: 1, address: presentAddress)
        let client = AudioHALClient(backend: backend)

        XCTAssertTrue(client.hasProperty(objectID: 1, address: presentAddress))
        XCTAssertFalse(client.hasProperty(objectID: 1, address: absentAddress))
    }

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

    func testIOProcUsageWriteRejectsEmptyFlagsBeforeCallingBackend() {
        let backend = FakeAudioHALBackend()

        XCTAssertThrowsError(try AudioHALClient(backend: backend).writeIOProcStreamUsage(
            [],
            deviceID: 7,
            ioProcID: testIOProcID,
            scope: kAudioObjectPropertyScopeInput
        )) { error in
            XCTAssertEqual(error as? AudioIOProcStreamUsageError, .streamCountMismatch)
        }
        XCTAssertTrue(backend.writeSelectors.isEmpty)
    }

    func testIOProcUsageReadRejectsZeroStreamsBeforeCallingBackend() {
        let backend = FakeAudioHALBackend()

        XCTAssertThrowsError(try AudioHALClient(backend: backend).readIOProcStreamUsage(
            streamCount: 0,
            deviceID: 8,
            ioProcID: testIOProcID,
            scope: kAudioObjectPropertyScopeInput
        )) { error in
            XCTAssertEqual(error as? AudioIOProcStreamUsageError, .streamCountMismatch)
        }
        XCTAssertTrue(backend.dataReadSelectors.isEmpty)
    }

    func testIOProcUsageWriteMapsBackendPropertyFailure() {
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyIOProcStreamUsage,
            scope: kAudioObjectPropertyScopeInput
        )

        assertHALFailure(
            operation: .setData,
            objectID: 9,
            address: address,
            status: kAudioHardwareUnknownPropertyError
        ) {
            try AudioHALClient(backend: FakeAudioHALBackend()).writeIOProcStreamUsage(
                [1],
                deviceID: 9,
                ioProcID: testIOProcID,
                scope: kAudioObjectPropertyScopeInput
            )
        }
    }

    func testIOProcUsageReadMapsBackendPropertyFailure() {
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyIOProcStreamUsage,
            scope: kAudioObjectPropertyScopeInput
        )

        assertHALFailure(
            operation: .getData,
            objectID: 10,
            address: address,
            status: kAudioHardwareUnknownPropertyError
        ) {
            _ = try AudioHALClient(backend: FakeAudioHALBackend()).readIOProcStreamUsage(
                streamCount: 1,
                deviceID: 10,
                ioProcID: testIOProcID,
                scope: kAudioObjectPropertyScopeInput
            )
        }
    }

    func testIOProcUsageReadRejectsUnexpectedByteCount() {
        let deviceID: AudioDeviceID = 11
        let address = AudioHALPropertyAddress(
            selector: kAudioDevicePropertyIOProcStreamUsage,
            scope: kAudioObjectPropertyScopeInput
        )
        var encoded: [UInt8] = []
        AudioIOProcStreamUsage.withEncoded(ioProcID: testIOProcID, flags: [1]) { bytes in
            encoded = Array(bytes)
        }
        let backend = FakeAudioHALBackend()
        backend.setRawBytes(
            Array(encoded.dropLast()),
            objectID: deviceID,
            address: address,
            isSettable: false
        )

        XCTAssertThrowsError(try AudioHALClient(backend: backend).readIOProcStreamUsage(
            streamCount: 1,
            deviceID: deviceID,
            ioProcID: testIOProcID,
            scope: kAudioObjectPropertyScopeInput
        )) { error in
            XCTAssertEqual(error as? AudioIOProcStreamUsageError, .byteCountMismatch)
        }
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

    func testIOProcUsageEncodesEveryStreamFlagAndRejectsInvalidDecodeShape() throws {
        try AudioIOProcStreamUsage.withEncoded(
            ioProcID: testIOProcID,
            flags: [1, 0]
        ) { bytes in
            XCTAssertEqual(
                try AudioIOProcStreamUsage.decode(
                    UnsafeRawBufferPointer(bytes),
                    expectedIOProcID: testIOProcID,
                    expectedStreamCount: 2
                ),
                [1, 0]
            )
            XCTAssertThrowsError(
                try AudioIOProcStreamUsage.decode(
                    UnsafeRawBufferPointer(bytes),
                    expectedIOProcID: testIOProcID,
                    expectedStreamCount: 0
                )
            ) { error in
                XCTAssertEqual(error as? AudioIOProcStreamUsageError, .streamCountMismatch)
            }
            XCTAssertThrowsError(
                try AudioIOProcStreamUsage.decode(
                    UnsafeRawBufferPointer(rebasing: bytes.dropLast()),
                    expectedIOProcID: testIOProcID,
                    expectedStreamCount: 2
                )
            ) { error in
                XCTAssertEqual(error as? AudioIOProcStreamUsageError, .byteCountMismatch)
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

    func testReadArrayRetriesWhenReturnedByteCountExceedsAnnouncement() throws {
        let backend = FakeAudioHALBackend()
        backend.enqueueArrayRead(announced: [UInt32(11)], returned: [11, 22])
        backend.enqueueArrayRead(announced: [UInt32(11), 22], returned: [11, 22])

        XCTAssertEqual(
            try AudioHALClient(backend: backend).readArray(
                UInt32.self,
                from: 2,
                address: .init(selector: kAudioHardwarePropertyDevices),
                maxAttempts: 2
            ),
            [11, 22]
        )
        XCTAssertEqual(backend.dataSizeCallCount, 2)
    }

    func testReadArrayThrowsAfterExhaustingGrowingPropertyRetries() {
        let backend = FakeAudioHALBackend()
        for _ in 0..<3 {
            backend.enqueueArrayRead(announced: [UInt32(11)], returned: [11, 22])
        }
        let address = AudioHALPropertyAddress(selector: kAudioHardwarePropertyDevices)

        assertHALError(
            AudioHALError(
                operation: .getData,
                objectID: 3,
                address: address,
                reason: .retryLimitExceeded
            )
        ) {
            _ = try AudioHALClient(backend: backend).readArray(
                UInt32.self,
                from: 3,
                address: address,
                maxAttempts: 3
            )
        }
        XCTAssertEqual(backend.dataSizeCallCount, 3)
    }

    func testReadArrayRejectsReturnedByteCountWithPartialElement() {
        let backend = FakeAudioHALBackend()
        backend.enqueueArrayRead(
            announced: Array(repeating: UInt8(0), count: 4),
            returned: Array(repeating: UInt8(0), count: 3)
        )
        let address = AudioHALPropertyAddress(selector: kAudioHardwarePropertyDevices)

        assertHALError(
            AudioHALError(
                operation: .getData,
                objectID: 4,
                address: address,
                reason: .invalidDataSize(byteCount: 3, elementStride: 4)
            )
        ) {
            _ = try AudioHALClient(backend: backend).readArray(
                UInt32.self,
                from: 4,
                address: address
            )
        }
    }

    func testReadArrayReturnsEmptyWhenPropertyHasNoValues() throws {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioHardwarePropertyDevices)
        backend.setArray([UInt32](), objectID: 4, address: address)

        XCTAssertEqual(
            try AudioHALClient(backend: backend).readArray(
                UInt32.self,
                from: 4,
                address: address
            ),
            []
        )
    }

    func testReadArrayReturnsEmptyWhenReturnedValuesShrinkToZero() throws {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioHardwarePropertyDevices)
        backend.enqueueArrayRead(announced: [UInt32(11)], returned: [UInt32]())

        XCTAssertEqual(
            try AudioHALClient(backend: backend).readArray(
                UInt32.self,
                from: 4,
                address: address
            ),
            []
        )
    }

    func testReadArrayRejectsZeroAttemptsWithoutCallingBackend() {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioHardwarePropertyDevices)

        assertHALError(
            AudioHALError(
                operation: .getData,
                objectID: 4,
                address: address,
                reason: .retryLimitExceeded
            )
        ) {
            _ = try AudioHALClient(backend: backend).readArray(
                UInt32.self,
                from: 4,
                address: address,
                maxAttempts: 0
            )
        }
        XCTAssertEqual(backend.dataSizeCallCount, 0)
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

    func testReadScalarRejectsWrongReturnedByteCount() {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        backend.setRawBytes([0, 0, 0], objectID: 5, address: address, isSettable: false)

        assertHALError(
            AudioHALError(
                operation: .getData,
                objectID: 5,
                address: address,
                reason: .invalidDataSize(byteCount: 3, elementStride: 4)
            )
        ) {
            _ = try AudioHALClient(backend: backend).readScalar(
                UInt32.self,
                from: 5,
                address: address
            )
        }
    }

    func testReadScalarReturnsConfiguredValue() throws {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        backend.setScalar(UInt32(42), objectID: 5, address: address)

        XCTAssertEqual(
            try AudioHALClient(backend: backend).readScalar(
                UInt32.self,
                from: 5,
                address: address
            ),
            42
        )
    }

    func testWriteScalarUpdatesConfiguredProperty() throws {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        backend.setScalar(UInt32(0), objectID: 5, address: address, isSettable: true)
        let client = AudioHALClient(backend: backend)

        try client.writeScalar(UInt32(42), to: 5, address: address)
        XCTAssertEqual(
            try client.readScalar(UInt32.self, from: 5, address: address),
            42
        )
    }

    func testWriteScalarMapsBackendPropertyFailure() {
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)

        assertHALFailure(
            operation: .setData,
            objectID: 5,
            address: address,
            status: kAudioHardwareUnknownPropertyError
        ) {
            try AudioHALClient(backend: FakeAudioHALBackend()).writeScalar(
                UInt32(42),
                to: 5,
                address: address
            )
        }
    }

    func testRetainedStringTransferDiagnosticsBalanceSuccess() throws {
        let backend = FakeAudioHALBackend()
        let value = CFStringCreateMutable(kCFAllocatorDefault, 0)!
        CFStringAppend(value, "Music" as CFString)
        backend.enqueueRetainedString(value)
        let before = AudioHALRetainedTransferDiagnostics.snapshot()

        XCTAssertEqual(
            try AudioHALClient(backend: backend).readRetainedString(
                from: 10,
                address: .init(selector: kAudioObjectPropertyName)
            ),
            "Music"
        )
        let after = AudioHALRetainedTransferDiagnostics.snapshot()
        XCTAssertEqual(after.receipts - before.receipts, 1)
        XCTAssertEqual(after.consumptions - before.consumptions, 1)
        XCTAssertTrue(after.isBalanced(since: before))
    }

    func testRetainedStringRejectsMalformedByteCountAfterConsumingTransfer() {
        let backend = FakeAudioHALBackend()
        let value = CFStringCreateMutable(kCFAllocatorDefault, 0)!
        backend.enqueueRetainedObject(value, returnedByteCount: 1)
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        let before = AudioHALRetainedTransferDiagnostics.snapshot()

        assertHALError(
            AudioHALError(
                operation: .getData,
                objectID: 6,
                address: address,
                reason: .invalidDataSize(
                    byteCount: 1,
                    elementStride: MemoryLayout<Unmanaged<CFString>?>.stride
                )
            )
        ) {
            _ = try AudioHALClient(backend: backend).readRetainedString(
                from: 6,
                address: address
            )
        }

        let after = AudioHALRetainedTransferDiagnostics.snapshot()
        XCTAssertEqual(after.receipts - before.receipts, 1)
        XCTAssertEqual(after.consumptions - before.consumptions, 1)
        XCTAssertTrue(after.isBalanced(since: before))
    }

    func testRetainedStringRejectsMissingValueAfterFullPointerRead() {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        var nilPointer: UnsafeMutableRawPointer?
        backend.setRawBytes(
            withUnsafeBytes(of: &nilPointer) { Array($0) },
            objectID: 6,
            address: address,
            isSettable: false
        )

        assertHALError(
            AudioHALError(
                operation: .getData,
                objectID: 6,
                address: address,
                reason: .missingValue
            )
        ) {
            _ = try AudioHALClient(backend: backend).readRetainedString(
                from: 6,
                address: address
            )
        }
    }

    func testRetainedObjectRejectsMissingValueAfterFullPointerRead() {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        var nilPointer: UnsafeMutableRawPointer?
        backend.setRawBytes(
            withUnsafeBytes(of: &nilPointer) { Array($0) },
            objectID: 6,
            address: address,
            isSettable: false
        )

        assertHALError(
            AudioHALError(
                operation: .getData,
                objectID: 6,
                address: address,
                reason: .missingValue
            )
        ) {
            _ = try AudioHALClient(backend: backend).readRetainedObject(
                CFString.self,
                from: 6,
                address: address
            )
        }
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

    func testAggregateCreateRejectsMissingObjectID() {
        let backend = FakeAudioHALBackend()

        assertHALError(
            AudioHALError(
                operation: .createAggregate,
                objectID: kAudioObjectUnknown,
                address: nil,
                reason: .missingValue
            )
        ) {
            _ = try AudioHALClient(backend: backend).createAggregateDevice(
                ["uid": "com.how.macactivity.missing"] as CFDictionary
            )
        }
        XCTAssertEqual(backend.mutableOperations, [.createAggregate])
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

    func testProcessTapDestroyChecksAvailabilityBeforeTouchingBackend() {
        let backend = FakeAudioHALBackend()
        let client = AudioHALClient(
            backend: backend,
            processTapsAvailable: false
        )

        assertHALError(
            AudioHALError(
                operation: .destroyTap,
                objectID: 99,
                address: nil,
                reason: .processTapsUnavailable
            )
        ) {
            try client.destroyProcessTap(99)
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
    func testProcessTapCreateRejectsMissingObjectID() {
        let backend = FakeAudioHALBackend()
        let description = CATapDescription(stereoMixdownOfProcesses: [])

        assertHALError(
            AudioHALError(
                operation: .createTap,
                objectID: kAudioObjectUnknown,
                address: nil,
                reason: .missingValue
            )
        ) {
            _ = try AudioHALClient(
                backend: backend,
                processTapsAvailable: true
            ).createProcessTap(description)
        }
        XCTAssertEqual(backend.mutableOperations, [.createTap])
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

    func testRetainedObjectTransferDiagnosticsBalanceSuccessAndMalformedSize() throws {
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)

        let successBackend = FakeAudioHALBackend()
        let successValue = CFStringCreateMutable(kCFAllocatorDefault, 0)!
        CFStringAppend(successValue, "Success" as CFString)
        successBackend.enqueueRetainedObject(successValue)
        let beforeSuccess = AudioHALRetainedTransferDiagnostics.snapshot()
        try autoreleasepool {
            let returned = try AudioHALClient(backend: successBackend).readRetainedObject(
                CFString.self,
                from: 707,
                address: address
            )
            XCTAssertTrue(CFEqual(returned, successValue))
        }
        let afterSuccess = AudioHALRetainedTransferDiagnostics.snapshot()
        XCTAssertEqual(afterSuccess.receipts - beforeSuccess.receipts, 1)
        XCTAssertEqual(afterSuccess.consumptions - beforeSuccess.consumptions, 1)
        XCTAssertTrue(afterSuccess.isBalanced(since: beforeSuccess))

        let malformedBackend = FakeAudioHALBackend()
        let malformedValue = CFStringCreateMutable(kCFAllocatorDefault, 0)!
        malformedBackend.enqueueRetainedObject(malformedValue, returnedByteCount: 1)
        let beforeMalformed = AudioHALRetainedTransferDiagnostics.snapshot()
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
        let afterMalformed = AudioHALRetainedTransferDiagnostics.snapshot()
        XCTAssertEqual(afterMalformed.receipts - beforeMalformed.receipts, 1)
        XCTAssertEqual(afterMalformed.consumptions - beforeMalformed.consumptions, 1)
        XCTAssertTrue(afterMalformed.isBalanced(since: beforeMalformed))
    }

    func testRetainedTransferDiagnosticsBalanceStatusError() {
        let backend = FakeAudioHALBackend()
        let value = CFStringCreateMutable(kCFAllocatorDefault, 0)!
        backend.enqueueRetainedObject(value, status: -707)
        let before = AudioHALRetainedTransferDiagnostics.snapshot()

        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        assertHALError(AudioHALError(
            operation: .getData,
            objectID: 709,
            address: address,
            reason: .status(-707)
        )) {
            _ = try AudioHALClient(backend: backend).readRetainedString(
                from: 709,
                address: address
            )
        }

        let after = AudioHALRetainedTransferDiagnostics.snapshot()
        XCTAssertEqual(after.receipts - before.receipts, 1)
        XCTAssertEqual(after.consumptions - before.consumptions, 1)
        XCTAssertTrue(after.isBalanced(since: before))
    }

    func testUnconsumedRetainedTransferIsObservableAndUnbalanced() {
        let before = AudioHALRetainedTransferDiagnostics.snapshot()

        AudioHALRetainedTransferDiagnostics.recordReceiptForTesting()
        let unconsumed = AudioHALRetainedTransferDiagnostics.snapshot()
        XCTAssertEqual(
            unconsumed.outstandingUnconsumedTransfers,
            before.outstandingUnconsumedTransfers + 1
        )
        XCTAssertFalse(unconsumed.isBalanced(since: before))

        AudioHALRetainedTransferDiagnostics.recordConsumptionForTesting()
        XCTAssertTrue(AudioHALRetainedTransferDiagnostics.snapshot().isBalanced(since: before))
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
        try AudioHALClient(backend: successBackend).writeObject(
            value,
            to: 709,
            address: address
        )
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

    func testIsPropertySettableReadsBackendValue() throws {
        let backend = FakeAudioHALBackend()
        let settableAddress = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        let readOnlyAddress = AudioHALPropertyAddress(selector: kAudioObjectPropertyManufacturer)
        backend.setScalar(UInt32(0), objectID: 12, address: settableAddress, isSettable: true)
        backend.setScalar(UInt32(0), objectID: 13, address: readOnlyAddress, isSettable: false)
        let client = AudioHALClient(backend: backend)

        XCTAssertTrue(try client.isPropertySettable(objectID: 12, address: settableAddress))
        XCTAssertFalse(try client.isPropertySettable(objectID: 13, address: readOnlyAddress))
    }

    func testIsPropertySettableMapsBackendFailure() {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        backend.enqueueIsSettableStatuses([-12])

        assertHALFailure(
            operation: .isSettable,
            objectID: 12,
            address: address,
            status: -12
        ) {
            _ = try AudioHALClient(backend: backend).isPropertySettable(
                objectID: 12,
                address: address
            )
        }
    }

    func testAddPropertyListenerMapsBackendFailureWithoutCreatingActiveListener() {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        backend.enqueueAddListenerStatuses([-13])

        assertHALFailure(
            operation: .addListener,
            objectID: 13,
            address: address,
            status: -13
        ) {
            _ = try AudioHALClient(backend: backend).addPropertyListener(
                objectID: 13,
                address: address,
                queue: DispatchQueue(label: "AudioHALClientTests.addFailure"),
                handler: {}
            )
        }
        XCTAssertEqual(backend.addedListeners.count, 1)
        XCTAssertTrue(backend.activeListeners.isEmpty)
    }

    func testListenerCancellationRetainsRegistrationAfterBackendFailure() throws {
        let backend = FakeAudioHALBackend()
        let address = AudioHALPropertyAddress(selector: kAudioObjectPropertyName)
        let token = try AudioHALClient(backend: backend).addPropertyListener(
            objectID: 14,
            address: address,
            queue: DispatchQueue(label: "AudioHALClientTests.removeFailure"),
            handler: {}
        )
        backend.removeListenerStatus = -14

        assertHALFailure(
            operation: .removeListener,
            objectID: 14,
            address: address,
            status: -14
        ) {
            try token.cancel()
        }

        backend.removeListenerStatus = noErr
        try token.cancel()
        XCTAssertEqual(backend.removedListeners.count, 2)
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
