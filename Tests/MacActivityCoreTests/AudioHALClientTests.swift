import CoreAudio
import CoreFoundation
import XCTest
@testable import MacActivityCore

final class AudioHALClientTests: XCTestCase {
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
            backend.removedListeners[0].blockIdentifier,
            backend.addedListeners[0].blockIdentifier
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
}
