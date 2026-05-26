import XCTest
@testable import MacActivityCore

final class SMCSensorReaderTests: XCTestCase {
    func testServiceMatchingNamesSupportAppleSiliconAndLegacySMC() {
        XCTAssertEqual(
            SMCSensorReader.serviceMatchingNames,
            ["AppleSMCKeysEndpoint", "AppleSMC"]
        )
    }

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

    func testLemonCPUTemperatureUsesLegacyKeyOrderBeforeAppleSiliconAverage() throws {
        var visitedKeys: [String] = []
        let temperature = try XCTUnwrap(
            SMCSensorReader.lemonCPUTemperature(
                legacyReading: { key in
                    visitedKeys.append(key)
                    return key == "TC0D" ? 54.5 : nil
                },
                appleSiliconKeys: ["Tp09"],
                appleSiliconReading: { _ in
                    XCTFail("Apple Silicon keys should not be read after a valid legacy CPU key")
                    return 64
                }
            )
        )

        XCTAssertEqual(temperature, 54.5, accuracy: 0.001)
        XCTAssertEqual(visitedKeys, ["TC0P", "TC0D"])
    }

    func testLemonCPUTemperatureAveragesValidAppleSiliconKeys() throws {
        let valuesByKey = [
            "Tp09": 30.0,
            "Tp0T": 34.0,
            "Tp01": 19.0,
            "Tp05": 110.0,
            "Tg05": 50.0,
        ]

        let temperature = try XCTUnwrap(
            SMCSensorReader.lemonCPUTemperature(
                legacyReading: { _ in nil },
                appleSiliconKeys: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tg05"],
                appleSiliconReading: { valuesByKey[$0] }
            )
        )

        XCTAssertEqual(temperature, 38, accuracy: 0.001)
    }

    func testAppleSiliconTemperatureKeysMatchLemonForMSeries() {
        XCTAssertEqual(
            SMCSensorReader.appleSiliconCPUTemperatureKeys(forCPUBrand: "Apple M4 Pro"),
            ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        )
    }

    func testVisibleFanRPMMatchesLemonByUsingMaximumTruncatedSpeed() {
        XCTAssertEqual(
            SMCSensorReader.visibleFanRPM(from: [1200.8, 3111.9, 3000.4]),
            3111
        )
        XCTAssertNil(SMCSensorReader.visibleFanRPM(from: []))
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
