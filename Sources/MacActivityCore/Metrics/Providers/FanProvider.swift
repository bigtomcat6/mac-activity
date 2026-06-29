import Darwin
import Foundation
import IOKit

public struct FanProvider: MetricProvider {
    public let kind: MetricKind = .fan
    public let cadence: MetricCadenceLane = .medium
    private let readFanRPM: @Sendable () async -> Int?

    public init() {
        self.init(smcSnapshotCache: .shared)
    }

    init(smcSnapshotCache: SMCSensorSnapshotCache) {
        self.readFanRPM = {
            await smcSnapshotCache.current().fanRPM
        }
    }

    public func sample() async -> MetricUpdate {
        guard let rpm = await readFanRPM() else {
            return .unavailable(kind: .fan, reason: "Fan speed is not exposed by AppleSMC")
        }

        return .fan(FanReading(rpm: rpm))
    }
}

struct SMCSensorSnapshot: Equatable, Sendable {
    var temperatureCelsius: Double?
    var fanRPM: Int?

    var hasReadings: Bool {
        temperatureCelsius != nil || fanRPM != nil
    }
}

actor SMCSensorSnapshotCache {
    static let shared = SMCSensorSnapshotCache()

    private let ttl: Duration
    private let retryInterval: Duration
    private let readSnapshot: @Sendable () async -> SMCSensorSnapshot
    private let clock = ContinuousClock()
    private var cachedSnapshot: (snapshot: SMCSensorSnapshot, timestamp: ContinuousClock.Instant)?

    init(
        ttl: Duration = .seconds(1),
        retryInterval: Duration = .seconds(2),
        readSnapshot: @escaping @Sendable () async -> SMCSensorSnapshot = {
            SMCSensorReader.readSnapshot()
        }
    ) {
        self.ttl = ttl
        self.retryInterval = retryInterval
        self.readSnapshot = readSnapshot
    }

    func current() async -> SMCSensorSnapshot {
        let now = clock.now
        if let cachedSnapshot {
            let age = cachedSnapshot.timestamp.duration(to: now)
            let maxAge = cachedSnapshot.snapshot.hasReadings ? ttl : retryInterval
            if age < maxAge {
                return cachedSnapshot.snapshot
            }
        }

        let snapshot = await readSnapshot()
        cachedSnapshot = (snapshot, now)
        return snapshot
    }
}

enum SMCSensorReader {
    static let serviceMatchingNames = ["AppleSMCKeysEndpoint", "AppleSMC"]
    static let legacyCPUTemperatureKeys = ["TC0P", "TC0D", "TC0H", "TC0E", "TC0F", "TCAD"]
    private static let maxTemperatureCelsius = 110.0
    private static let minAppleSiliconCPUTemperatureCelsius = 20.0

    static func readFanRPM() -> Int? {
        readSnapshot().fanRPM
    }

    static func readTemperatureCelsius() -> Double? {
        readSnapshot().temperatureCelsius
    }

    static func readSnapshot() -> SMCSensorSnapshot {
        withConnection { connection in
            SMCSensorSnapshot(
                temperatureCelsius: readTemperatureCelsius(connection: connection),
                fanRPM: readVisibleFanRPM(connection: connection)
            )
        } ?? SMCSensorSnapshot()
    }

    private static func withConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        for serviceName in serviceMatchingNames {
            guard let matching = IOServiceMatching(serviceName) else {
                continue
            }

            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != 0 else {
                continue
            }
            defer {
                IOObjectRelease(service)
            }

            var connection: io_connect_t = 0
            guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
                continue
            }
            defer {
                IOServiceClose(connection)
            }

            if let value = body(connection) {
                return value
            }
        }

        return nil
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

    private static func readVisibleFanRPM(connection: io_connect_t) -> Int? {
        guard let fanCount = readUInt8(key: "FNum", connection: connection), fanCount > 0 else {
            return nil
        }

        let speeds = (0..<fanCount).compactMap { index in
            readFanRPM(key: "F\(index)Ac", connection: connection)
        }

        return visibleFanRPM(from: speeds)
    }

    private static func readTemperatureCelsius(connection: io_connect_t) -> Double? {
        lemonCPUTemperature(
            legacyReading: { key in
                readTemperature(key: key, connection: connection)
            },
            appleSiliconKeys: appleSiliconCPUTemperatureKeys(forCPUBrand: currentCPUBrand()),
            appleSiliconReading: { key in
                readTemperature(key: key, connection: connection)
            }
        )
    }

    static func lemonCPUTemperature(
        legacyReading: (String) -> Double?,
        appleSiliconKeys: [String]?,
        appleSiliconReading: (String) -> Double?
    ) -> Double? {
        for key in legacyCPUTemperatureKeys {
            guard let celsius = legacyReading(key) else {
                continue
            }

            if celsius > 0, celsius <= maxTemperatureCelsius {
                return celsius
            }
        }

        guard let appleSiliconKeys else {
            return nil
        }

        let validTemperatures = appleSiliconKeys.compactMap { key -> Double? in
            guard let celsius = appleSiliconReading(key),
                  celsius > minAppleSiliconCPUTemperatureCelsius,
                  celsius < maxTemperatureCelsius else {
                return nil
            }

            return celsius
        }

        guard !validTemperatures.isEmpty else {
            return nil
        }

        return validTemperatures.reduce(0, +) / Double(validTemperatures.count)
    }

    static func appleSiliconCPUTemperatureKeys(forCPUBrand brand: String) -> [String]? {
        let normalized = brand
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        if normalized.contains("intel") {
            return nil
        }

        if normalized.contains("m1") {
            if normalized.contains("pro") || normalized.contains("max") || normalized.contains("ultra") {
                return ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
            }
            return ["Tc0a", "Tc0b", "Tc0x", "Tc0z", "Tc7a", "Tc7b", "Tc7x", "Tc7z", "Tc8a", "Tc8b", "Tc9a", "Tc9b", "Tc9x", "Tc9z"]
        }

        if normalized.contains("m2") {
            return ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tg0f", "Tg0j"]
        }

        if normalized.contains("m3") {
            return ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E", "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        }

        if normalized.contains("m4") {
            return ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        }

        if normalized.contains("m5") {
            return ["Te04", "Te08", "Te0C", "Te0R", "Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X", "Tp0a", "Tp0p", "Tp0u", "Tp0y"]
        }

        return nil
    }

    static func visibleFanRPM(from speeds: [Double]) -> Int? {
        guard let maxSpeed = speeds.max() else {
            return nil
        }

        return Int(maxSpeed)
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
        case "ui8", "ui16", "ui32":
            return decodeUInt(bytes)
        case "fp1f":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 15)
        case "fp4c":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 12)
        case "fp5b":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 11)
        case "fp6a":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 10)
        case "fp79":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 9)
        case "fp88":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 8)
        case "fpa6":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 6)
        case "fpc4":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 4)
        case "fpe2":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 2)
        case "sp1e":
            return decodeSignedFixedPoint(bytes, fractionalBits: 14)
        case "sp3c":
            return decodeSignedFixedPoint(bytes, fractionalBits: 12)
        case "sp4b":
            return decodeSignedFixedPoint(bytes, fractionalBits: 11)
        case "sp5a":
            return decodeSignedFixedPoint(bytes, fractionalBits: 10)
        case "sp69":
            return decodeSignedFixedPoint(bytes, fractionalBits: 9)
        case "sp78":
            return decodeSignedFixedPoint(bytes, fractionalBits: 8)
        case "sp87":
            return decodeSignedFixedPoint(bytes, fractionalBits: 7)
        case "sp96":
            return decodeSignedFixedPoint(bytes, fractionalBits: 6)
        case "spb4":
            return decodeSignedFixedPoint(bytes, fractionalBits: 4)
        case "spf0":
            return decodeSignedFixedPoint(bytes, fractionalBits: 0)
        case "si8":
            guard let first = bytes.first else { return nil }
            return Double(Int8(bitPattern: first))
        case "si16":
            return decodeSignedFixedPoint(bytes, fractionalBits: 0)
        case "pwm":
            return decodeUnsignedFixedPoint(bytes, fractionalBits: 16).map { $0 * 100 }
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
        decodeUnsignedFixedPoint(bytes, fractionalBits: 2)
    }

    private static func decodeUnsignedFixedPoint(_ bytes: [UInt8], fractionalBits: Int) -> Double? {
        guard bytes.count >= 2 else {
            return nil
        }

        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Double(raw) / Double(1 << fractionalBits)
    }

    static func decodeSP78(_ bytes: [UInt8]) -> Double? {
        decodeSignedFixedPoint(bytes, fractionalBits: 8)
    }

    private static func decodeSignedFixedPoint(_ bytes: [UInt8], fractionalBits: Int) -> Double? {
        guard bytes.count >= 2 else {
            return nil
        }

        let raw = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        return Double(Int16(bitPattern: raw)) / Double(1 << fractionalBits)
    }

    private static func decodeUInt(_ bytes: [UInt8]) -> Double? {
        guard !bytes.isEmpty else {
            return nil
        }

        return Double(bytes.reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        })
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

    private static func currentCPUBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return ""
        }

        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? ""
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
        // AppleSMC expects this to be laid out as exactly 32 bytes for IOConnectCallStructMethod.
        // swiftlint:disable:next large_tuple
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

enum BatteryTemperatureReader {
    static func readTemperatureCelsius() -> Double? {
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
