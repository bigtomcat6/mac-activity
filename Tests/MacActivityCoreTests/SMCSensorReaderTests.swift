import XCTest
@testable import MacActivityCore

final class SMCSensorReaderTests: XCTestCase {
    func testSMCKeyDataMatchesAppleSMCOffsets() {
        XCTAssertEqual(MemoryLayout<SMCSensorReader.SMCKeyData>.stride, 80)
        XCTAssertEqual(MemoryLayout<SMCSensorReader.SMCKeyData>.offset(of: \.keyInfo), 28)
        XCTAssertEqual(MemoryLayout<SMCSensorReader.SMCKeyData>.offset(of: \.data8), 42)
    }

    func testDecodeFanRPMSupportsAppleSiliconLittleEndianFloat() throws {
        let bytes = bytes(from: Float(3456.5))
        let rpm = try XCTUnwrap(SMCSensorReader.decodeFanRPM(from: bytes, dataType: "flt "))

        XCTAssertEqual(
            rpm,
            3456.5,
            accuracy: 0.001
        )
    }

    func testDecodeFanRPMSupportsLegacyFixedPoint() throws {
        let rpm = try XCTUnwrap(SMCSensorReader.decodeFanRPM(from: [0x12, 0x34], dataType: "fpe2"))

        XCTAssertEqual(
            rpm,
            1165,
            accuracy: 0.001
        )
    }

    func testDecodeTemperatureSupportsSP78AndFloat() throws {
        let sp78 = try XCTUnwrap(SMCSensorReader.decodeTemperatureCelsius(from: [0x1E, 0x80], dataType: "sp78"))
        let floatValue = try XCTUnwrap(
            SMCSensorReader.decodeTemperatureCelsius(from: bytes(from: Float(41.25)), dataType: "flt ")
        )

        XCTAssertEqual(
            sp78,
            30.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            floatValue,
            41.25,
            accuracy: 0.001
        )
    }

    private func bytes(from value: Float) -> [UInt8] {
        let raw = value.bitPattern
        return [
            UInt8(raw & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 24) & 0xFF),
        ]
    }
}
