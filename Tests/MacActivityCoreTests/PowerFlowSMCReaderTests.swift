import XCTest
@testable import MacActivityCore

final class PowerFlowSMCReaderTests: XCTestCase {
    func testReadingDefaultsAllFieldsToNil() {
        let reading = PowerFlowSMCReader.Reading()

        XCTAssertNil(reading.inputVoltageMillivolts)
        XCTAssertNil(reading.inputCurrentMilliamps)
        XCTAssertNil(reading.batteryVoltageMillivolts)
        XCTAssertNil(reading.batteryCurrentMilliamps)
    }

    func testReadDecodesAllFourPowerKeys() {
        let reading = PowerFlowSMCReader.read { key in
            switch key {
            case "VD0R": return .init(bytes: [0x00, 0x00, 0xA4, 0x41, 0x99], dataType: "flt ")
            case "ID0R": return .init(bytes: [0x00, 0x00, 0xA0, 0xBF], dataType: "flt ")
            case "B0AV": return .init(bytes: [0xC2, 0x30], dataType: "ui16")
            case "B0AC": return .init(bytes: [0x30, 0xF8], dataType: "si16")
            default: return nil
            }
        }

        XCTAssertEqual(reading.inputVoltageMillivolts, 20_500)
        XCTAssertEqual(reading.inputCurrentMilliamps, -1_250)
        XCTAssertEqual(reading.batteryVoltageMillivolts, 12_482)
        XCTAssertEqual(reading.batteryCurrentMilliamps, -2_000)
    }

    func testReadDecodesPositiveBatteryCurrent() {
        let reading = PowerFlowSMCReader.read { key in
            guard key == "B0AC" else { return nil }
            return .init(bytes: [0xD2, 0x04], dataType: "si16")
        }

        XCTAssertEqual(reading.batteryCurrentMilliamps, 1_234)
        XCTAssertNil(reading.inputVoltageMillivolts)
        XCTAssertNil(reading.inputCurrentMilliamps)
        XCTAssertNil(reading.batteryVoltageMillivolts)
    }

    func testReadDecodesZeroValues() {
        let reading = PowerFlowSMCReader.read { key in
            switch key {
            case "VD0R", "ID0R": return .init(bytes: [0x00, 0x00, 0x00, 0x00], dataType: "flt ")
            case "B0AV": return .init(bytes: [0x00, 0x00], dataType: "ui16")
            case "B0AC": return .init(bytes: [0x00, 0x00], dataType: "si16")
            default: return nil
            }
        }

        XCTAssertEqual(reading.inputVoltageMillivolts, 0)
        XCTAssertEqual(reading.inputCurrentMilliamps, 0)
        XCTAssertEqual(reading.batteryVoltageMillivolts, 0)
        XCTAssertEqual(reading.batteryCurrentMilliamps, 0)
    }

    func testReadLeavesMissingAndInvalidLayoutsNilIndependently() {
        let reading = PowerFlowSMCReader.read { key in
            switch key {
            case "VD0R": return .init(bytes: [0x00, 0x00, 0xA4], dataType: "flt ")
            case "ID0R": return .init(bytes: [0x00, 0x00, 0x00, 0x40], dataType: "flt ")
            case "B0AV": return .init(bytes: [0xC2], dataType: "ui16")
            case "B0AC": return .init(bytes: [0x30, 0xF8, 0x00], dataType: "si16")
            default: return nil
            }
        }

        XCTAssertNil(reading.inputVoltageMillivolts)
        XCTAssertEqual(reading.inputCurrentMilliamps, 2_000)
        XCTAssertNil(reading.batteryVoltageMillivolts)
        XCTAssertNil(reading.batteryCurrentMilliamps)
    }

    func testReadRejectsUnexpectedDataTypesWithoutFallbackDecoding() {
        let reading = PowerFlowSMCReader.read { key in
            switch key {
            case "VD0R": return .init(bytes: [0x00, 0x00, 0xA4, 0x41], dataType: "sp78")
            case "ID0R": return .init(bytes: [0x00, 0x00, 0xA0, 0xBF], dataType: "unknown")
            case "B0AV": return .init(bytes: [0xC2, 0x30], dataType: "si16")
            case "B0AC": return .init(bytes: [0x30, 0xF8], dataType: "ui16")
            default: return nil
            }
        }

        XCTAssertNil(reading.inputVoltageMillivolts)
        XCTAssertNil(reading.inputCurrentMilliamps)
        XCTAssertNil(reading.batteryVoltageMillivolts)
        XCTAssertNil(reading.batteryCurrentMilliamps)
    }

    func testReadRejectsWhitespacePaddedFloatTypeTags() {
        for dataType in ["flt\n", " flt"] {
            let reading = PowerFlowSMCReader.read { key in
                switch key {
                case "VD0R", "ID0R": return .init(bytes: [0x00, 0x00, 0xA4, 0x41], dataType: dataType)
                default: return nil
                }
            }

            XCTAssertNil(reading.inputVoltageMillivolts)
            XCTAssertNil(reading.inputCurrentMilliamps)
        }
    }

    func testReadRejectsShortFloatTypeTag() {
        let reading = PowerFlowSMCReader.read { key in
            guard key == "VD0R" else { return nil }
            return .init(bytes: [0x00, 0x00, 0xA4, 0x41], dataType: "flt")
        }

        XCTAssertNil(reading.inputVoltageMillivolts)
    }

    func testReadRejectsWhitespacePaddedBatteryTypeTags() {
        let reading = PowerFlowSMCReader.read { key in
            switch key {
            case "B0AV": return .init(bytes: [0xC2, 0x30], dataType: "ui16\n")
            case "B0AC": return .init(bytes: [0x30, 0xF8], dataType: " si16")
            default: return nil
            }
        }

        XCTAssertNil(reading.batteryVoltageMillivolts)
        XCTAssertNil(reading.batteryCurrentMilliamps)
    }

    func testReadRejectsNonFiniteInputFloats() {
        for bytes: [UInt8] in [[0x00, 0x00, 0x80, 0x7F], [0x00, 0x00, 0xC0, 0x7F]] {
            let reading = PowerFlowSMCReader.read { key in
                guard key == "VD0R" else { return nil }
                return .init(bytes: bytes, dataType: "flt ")
            }

            XCTAssertNil(reading.inputVoltageMillivolts)
        }
    }
}
