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

    func testDecodeFanRPMFallsBackBetweenFloatAndFixedPoint() throws {
        let floatRPM = try XCTUnwrap(SMCSensorReader.decodeFanRPM(from: bytes(from: Float(2222.25)), dataType: "unknown"))
        let fixedRPM = try XCTUnwrap(SMCSensorReader.decodeFanRPM(from: [0x12, 0x34], dataType: "unknown"))

        XCTAssertEqual(floatRPM, 2222.25, accuracy: 0.001)
        XCTAssertEqual(fixedRPM, 1165, accuracy: 0.001)
        XCTAssertNil(SMCSensorReader.decodeFanRPM(from: [0x12], dataType: "fpe2"))
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

    func testDecodeTemperatureSupportsIntegerAndFixedPointTypes() throws {
        XCTAssertEqual(
            try XCTUnwrap(SMCSensorReader.decodeTemperatureCelsius(from: [42], dataType: "ui8")),
            42,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(SMCSensorReader.decodeTemperatureCelsius(from: [0x01, 0x02], dataType: "ui16")),
            258,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(SMCSensorReader.decodeTemperatureCelsius(from: [0x00, 0x00, 0x01, 0x00], dataType: "ui32")),
            256,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(SMCSensorReader.decodeTemperatureCelsius(from: [0x80, 0x00], dataType: "pwm")),
            50,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(SMCSensorReader.decodeTemperatureCelsius(from: [0xFE], dataType: "si8")),
            -2,
            accuracy: 0.001
        )
        XCTAssertNil(SMCSensorReader.decodeTemperatureCelsius(from: [], dataType: "si8"))

        let unsignedTypes = ["fp1f", "fp4c", "fp5b", "fp6a", "fp79", "fp88", "fpa6", "fpc4", "fpe2"]
        for dataType in unsignedTypes {
            XCTAssertNotNil(
                SMCSensorReader.decodeTemperatureCelsius(from: [0x20, 0x00], dataType: dataType),
                "Expected \(dataType) to decode"
            )
        }

        let signedTypes = ["sp1e", "sp3c", "sp4b", "sp5a", "sp69", "sp87", "sp96", "spb4", "spf0", "si16"]
        for dataType in signedTypes {
            XCTAssertNotNil(
                SMCSensorReader.decodeTemperatureCelsius(from: [0x20, 0x00], dataType: dataType),
                "Expected \(dataType) to decode"
            )
        }
    }

    func testDecodeTemperatureFallsBackForUnknownTypes() throws {
        let floatValue = try XCTUnwrap(
            SMCSensorReader.decodeTemperatureCelsius(from: bytes(from: Float(44.5)), dataType: "unknown")
        )
        let sp78Value = try XCTUnwrap(
            SMCSensorReader.decodeTemperatureCelsius(from: [0x2C, 0x80], dataType: "unknown")
        )

        XCTAssertEqual(floatValue, 44.5, accuracy: 0.001)
        XCTAssertEqual(sp78Value, 44.5, accuracy: 0.001)
        XCTAssertNil(SMCSensorReader.decodeTemperatureCelsius(from: [0x2C], dataType: "unknown"))
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
            "Tg05": 50.0
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

    func testLemonCPUTemperatureRejectsInvalidAndMissingReadings() {
        XCTAssertNil(
            SMCSensorReader.lemonCPUTemperature(
                legacyReading: { _ in 0 },
                appleSiliconKeys: nil,
                appleSiliconReading: { _ in 64 }
            )
        )

        XCTAssertNil(
            SMCSensorReader.lemonCPUTemperature(
                legacyReading: { _ in nil },
                appleSiliconKeys: ["Tp09", "Tp0T"],
                appleSiliconReading: { _ in 110 }
            )
        )
    }

    func testAppleSiliconTemperatureKeysMatchLemonForMSeries() {
        XCTAssertEqual(
            SMCSensorReader.appleSiliconCPUTemperatureKeys(forCPUBrand: "Apple M4 Pro"),
            ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]
        )
    }

    func testAppleSiliconTemperatureKeysCoverKnownFamiliesAndFallbacks() {
        XCTAssertNil(SMCSensorReader.appleSiliconCPUTemperatureKeys(forCPUBrand: "Intel(R) Core(TM) i7"))
        XCTAssertNil(SMCSensorReader.appleSiliconCPUTemperatureKeys(forCPUBrand: "Unknown CPU"))
        XCTAssertEqual(
            SMCSensorReader.appleSiliconCPUTemperatureKeys(forCPUBrand: "Apple M1"),
            ["Tc0a", "Tc0b", "Tc0x", "Tc0z", "Tc7a", "Tc7b", "Tc7x", "Tc7z", "Tc8a", "Tc8b", "Tc9a", "Tc9b", "Tc9x", "Tc9z"]
        )
        XCTAssertEqual(
            SMCSensorReader.appleSiliconCPUTemperatureKeys(forCPUBrand: "Apple M1 Max"),
            ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b", "Tg05", "Tg0D", "Tg0L", "Tg0T"]
        )
        XCTAssertEqual(
            SMCSensorReader.appleSiliconCPUTemperatureKeys(forCPUBrand: "Apple M2"),
            ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tg0f", "Tg0j"]
        )
        XCTAssertEqual(
            SMCSensorReader.appleSiliconCPUTemperatureKeys(forCPUBrand: "Apple M3"),
            ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E", "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
        )
        XCTAssertEqual(
            SMCSensorReader.appleSiliconCPUTemperatureKeys(forCPUBrand: "Apple M5"),
            ["Te04", "Te08", "Te0C", "Te0R", "Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X", "Tp0a", "Tp0p", "Tp0u", "Tp0y"]
        )
    }

    func testCurrentCPUBrandReadsSysctlBrandString() {
        XCTAssertGreaterThanOrEqual(SMCSensorReader.currentCPUBrand().count, 0)
    }

    func testSMCSensorSnapshotTracksWhetherAnyReadingExists() {
        XCTAssertFalse(SMCSensorSnapshot().hasReadings)
        XCTAssertTrue(SMCSensorSnapshot(temperatureCelsius: 44.5).hasReadings)
        XCTAssertTrue(SMCSensorSnapshot(fanRPM: 2_400).hasReadings)
    }

    func testSMCSensorSnapshotCacheReusesFreshReadings() async {
        let recorder = SMCSensorSnapshotReadRecorder(
            snapshots: [
                SMCSensorSnapshot(temperatureCelsius: 44.5, fanRPM: 2_400),
                SMCSensorSnapshot(temperatureCelsius: 50, fanRPM: 3_100)
            ]
        )
        let cache = SMCSensorSnapshotCache(
            ttl: .seconds(60),
            retryInterval: .seconds(60),
            readSnapshot: {
                await recorder.nextSnapshot()
            }
        )

        let first = await cache.current()
        let second = await cache.current()
        let readCount = await recorder.currentReadCount()

        XCTAssertEqual(first, SMCSensorSnapshot(temperatureCelsius: 44.5, fanRPM: 2_400))
        XCTAssertEqual(second, first)
        XCTAssertEqual(readCount, 1)
    }

    func testSMCSensorSnapshotReadRecorderReturnsEmptySnapshotWhenExhausted() async {
        let recorder = SMCSensorSnapshotReadRecorder(snapshots: [])

        let snapshot = await recorder.nextSnapshot()

        XCTAssertEqual(snapshot, SMCSensorSnapshot())
    }

    func testFanProviderReportsFanRPMAndUnavailableState() async {
        let fanCache = SMCSensorSnapshotCache(
            readSnapshot: {
                SMCSensorSnapshot(fanRPM: 2_400)
            }
        )
        let unavailableCache = SMCSensorSnapshotCache(
            readSnapshot: {
                SMCSensorSnapshot(temperatureCelsius: 44.5)
            }
        )

        let fanUpdate = await FanProvider(smcSnapshotCache: fanCache).sample()
        let unavailableUpdate = await FanProvider(smcSnapshotCache: unavailableCache).sample()

        XCTAssertEqual(fanUpdate, .fan(FanReading(rpm: 2_400)))
        XCTAssertEqual(
            unavailableUpdate,
            .unavailable(kind: .fan, reason: "Fan speed is not exposed by AppleSMC")
        )
    }

    func testFanProviderReportsPerFanRPMsAndMaximumVisibleRPM() async {
        let fanCache = SMCSensorSnapshotCache(
            readSnapshot: {
                SMCSensorSnapshot(fanRPM: 3_111, fanRPMs: [1_200, 3_111])
            }
        )

        let fanUpdate = await FanProvider(smcSnapshotCache: fanCache).sample()

        XCTAssertEqual(fanUpdate, .fan(FanReading(rpm: 3_111, fanRPMs: [1_200, 3_111])))
    }

    func testVisibleFanRPMMatchesLemonByUsingMaximumTruncatedSpeed() {
        XCTAssertEqual(
            SMCSensorReader.visibleFanRPM(from: [1200.8, 3111.9, 3000.4]),
            3111
        )
        XCTAssertNil(SMCSensorReader.visibleFanRPM(from: []))
    }

    func testVisibleFanRPMsPreserveFanOrderAndTruncateSpeeds() {
        XCTAssertEqual(
            SMCSensorReader.visibleFanRPMs(from: [1200.8, 3111.9]),
            [1200, 3111]
        )
        XCTAssertEqual(SMCSensorReader.visibleFanRPMs(from: []), [])
    }

    private func bytes(from value: Float) -> [UInt8] {
        let raw = value.bitPattern
        return [
            UInt8(raw & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 24) & 0xFF)
        ]
    }
}

private actor SMCSensorSnapshotReadRecorder {
    private var snapshots: [SMCSensorSnapshot]
    private var readCount = 0

    init(snapshots: [SMCSensorSnapshot]) {
        self.snapshots = snapshots
    }

    func nextSnapshot() -> SMCSensorSnapshot {
        readCount += 1
        guard snapshots.isEmpty == false else {
            return SMCSensorSnapshot()
        }
        return snapshots.removeFirst()
    }

    func currentReadCount() -> Int {
        readCount
    }
}
