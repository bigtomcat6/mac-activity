import Foundation
import IOKit

public struct FanProvider: MetricProvider {
    public let kind: MetricKind = .fan
    public let cadence: MetricCadenceLane = .slow

    public init() {}

    public func sample() async -> MetricUpdate {
        guard let rpm = SMCSensorReader.readFanRPM() else {
            return .unavailable(kind: .fan, reason: "Fan speed is not exposed by AppleSMC")
        }

        return .fan(FanReading(rpm: rpm))
    }
}

enum SMCSensorReader {
    static func readFanRPM() -> Int? {
        withConnection { connection in
            guard let fanCount = readUInt8(key: "FNum", connection: connection), fanCount > 0 else {
                return nil
            }

            let speeds = (0..<fanCount).compactMap { index in
                readFanRPM(key: "F\(index)Ac", connection: connection)
            }

            guard !speeds.isEmpty else {
                return nil
            }

            let average = speeds.reduce(0, +) / Double(speeds.count)
            return Int(average.rounded())
        }
    }

    static func readTemperatureCelsius() -> Double? {
        withConnection { connection in
            for key in ["TC0P", "TC0E", "TC0F", "TC0D", "TC0H", "TCXC", "TG0P"] {
                if let celsius = readTemperature(key: key, connection: connection) {
                    return celsius
                }
            }

            return nil
        }
    }

    private static func withConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        guard let matching = IOServiceMatching("AppleSMC") else {
            return nil
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return nil
        }
        defer {
            IOObjectRelease(service)
        }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            return nil
        }
        defer {
            IOServiceClose(connection)
        }

        return body(connection)
    }

    private static func readUInt8(key: String, connection: io_connect_t) -> Int? {
        guard let reading = readKey(key, connection: connection), let first = reading.bytes.first else {
            return nil
        }

        return Int(first)
    }

    static func readFanRPM(key: String, connection: io_connect_t) -> Double? {
        guard let reading = readKey(key, connection: connection) else {
            return nil
        }

        return decodeFanRPM(from: reading.bytes, dataType: reading.dataType)
    }

    static func readTemperature(key: String, connection: io_connect_t) -> Double? {
        guard let reading = readKey(key, connection: connection) else {
            return nil
        }

        return decodeTemperatureCelsius(from: reading.bytes, dataType: reading.dataType)
    }

    static func decodeFanRPM(from bytes: [UInt8], dataType: String) -> Double? {
        switch normalizedDataType(dataType) {
        case "flt":
            return decodeFloat(bytes)
        case "fpe2":
            return decodeFixedPoint(bytes)
        default:
            if let value = decodeFloat(bytes), bytes.count >= 4 {
                return value
            }
            return decodeFixedPoint(bytes)
        }
    }

    static func decodeTemperatureCelsius(from bytes: [UInt8], dataType: String) -> Double? {
        switch normalizedDataType(dataType) {
        case "sp78":
            return decodeSP78(bytes)
        case "flt":
            return decodeFloat(bytes)
        default:
            if let value = decodeFloat(bytes), bytes.count >= 4 {
                return value
            }
            return decodeSP78(bytes)
        }
    }

    static func normalizedDataType(_ dataType: String) -> String {
        dataType.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeFixedPoint(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else {
            return nil
        }

        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Double(raw) / 4.0
    }

    static func decodeSP78(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else {
            return nil
        }

        let signed = Int8(bitPattern: bytes[0])
        return Double(signed) + Double(bytes[1]) / 256.0
    }

    static func decodeFloat(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 4 else {
            return nil
        }

        let raw =
            UInt32(bytes[0]) |
            (UInt32(bytes[1]) << 8) |
            (UInt32(bytes[2]) << 16) |
            (UInt32(bytes[3]) << 24)
        let value = Float(bitPattern: raw)
        guard value.isFinite else {
            return nil
        }

        return Double(value)
    }

    private static func readKey(_ key: String, connection: io_connect_t) -> SMCReading? {
        guard let keyCode = keyCode(key) else {
            return nil
        }

        var input = SMCKeyData()
        var output = SMCKeyData()
        input.key = keyCode
        input.data8 = SMCCommand.readKeyInfo.rawValue

        guard callSMC(connection: connection, input: &input, output: &output) else {
            return nil
        }

        let dataSize = Int(output.keyInfo.dataSize)
        guard dataSize > 0, dataSize <= 32 else {
            return nil
        }
        let dataType = dataTypeString(output.keyInfo.dataType)

        input = SMCKeyData()
        output = SMCKeyData()
        input.key = keyCode
        input.keyInfo.dataSize = UInt32(dataSize)
        input.data8 = SMCCommand.readBytes.rawValue

        guard callSMC(connection: connection, input: &input, output: &output) else {
            return nil
        }

        return SMCReading(
            bytes: Array(output.bytes.array.prefix(dataSize)),
            dataType: dataType
        )
    }

    private static func callSMC(connection: io_connect_t, input: inout SMCKeyData, output: inout SMCKeyData) -> Bool {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let result = IOConnectCallStructMethod(
            connection,
            SMCSelector.open.rawValue,
            &input,
            inputSize,
            &output,
            &outputSize
        )

        return result == KERN_SUCCESS && output.result == 0
    }

    private static func dataTypeString(_ rawType: UInt32) -> String {
        withUnsafeBytes(of: rawType.bigEndian) { bytes in
            String(bytes: bytes, encoding: .ascii) ?? ""
        }
    }

    private static func keyCode(_ key: String) -> UInt32? {
        guard key.utf8.count == 4 else {
            return nil
        }

        return key.utf8.reduce(UInt32(0)) { partialResult, byte in
            (partialResult << 8) | UInt32(byte)
        }
    }

    private enum SMCCommand: UInt8 {
        case readBytes = 5
        case readKeyInfo = 9
    }

    private enum SMCSelector: UInt32 {
        case open = 2
    }

    struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct SMCPowerLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct SMCKeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    struct SMCBytes {
        var value: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )

        var array: [UInt8] {
            withUnsafeBytes(of: value) { bytes in
                Array(bytes)
            }
        }
    }

    struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPowerLimitData()
        var keyInfo = SMCKeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes = SMCBytes()
    }

    struct SMCReading {
        var bytes: [UInt8]
        var dataType: String
    }
}

enum IORegistrySensorFallbackReader {
    static func readBatteryTemperatureCelsius() -> Double? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            return nil
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            return nil
        }
        defer {
            IOObjectRelease(service)
        }

        guard let rawValue = IORegistryEntryCreateCFProperty(
            service,
            "Temperature" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }

        return celsius(fromBatteryTemperatureValue: rawValue.intValue)
    }

    static func celsius(fromBatteryTemperatureValue value: Int) -> Double {
        Double(value) / 100.0
    }
}
