import CoreAudio
import XCTest
@testable import MacActivityCore

final class AudioControlModelsTests: XCTestCase {
    func testNonValueStatesNeverExposeAFallbackValue() {
        let error = AudioHALError(
            operation: .getData,
            objectID: 42,
            address: nil,
            reason: .status(kAudioHardwareUnspecifiedError)
        )

        XCTAssertNil(AudioPropertyValue<Double>.unsupported.value)
        XCTAssertNil(AudioPropertyValue<Double>.unavailable.value)
        XCTAssertNil(AudioPropertyValue<Double>.failed(error).value)
        XCTAssertFalse(AudioPropertyValue<Double>.unsupported.isWritable)
    }

    func testReadableAndWritableAreIndependent() {
        XCTAssertEqual(AudioPropertyValue.value(0.42, isWritable: false).value, 0.42)
        XCTAssertFalse(AudioPropertyValue.value(0.42, isWritable: false).isWritable)
        XCTAssertTrue(AudioPropertyValue.value(0.42, isWritable: true).isWritable)
    }
}
