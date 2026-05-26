import XCTest
@testable import MacActivityCore

final class TemperatureProviderTests: XCTestCase {
    func testReportsUnavailableWhenSMCTemperatureIsUnavailable() async {
        let provider = TemperatureProvider(
            readTemperatureSource: { .smc },
            readSMCTemperatureCelsius: { nil },
            readBatteryTemperatureCelsius: { nil }
        )

        let update = await provider.sample()

        XCTAssertEqual(
            update,
            MetricUpdate.unavailable(kind: .temperature, reason: "SMC temperature sensors are not available")
        )
    }

    func testFallsBackToBatteryTemperatureWhenSMCSourceIsUnavailable() async {
        let provider = TemperatureProvider(
            readTemperatureSource: { .smc },
            readSMCTemperatureCelsius: { nil },
            readBatteryTemperatureCelsius: { 30.17 }
        )

        let update = await provider.sample()

        XCTAssertEqual(
            update,
            MetricUpdate.temperature(TemperatureReading(celsius: 30.17, source: .battery))
        )
    }

    func testReadsBatteryTemperatureWhenBatterySourceIsSelected() async {
        let provider = TemperatureProvider(
            readTemperatureSource: { .battery },
            readSMCTemperatureCelsius: { 55.4 },
            readBatteryTemperatureCelsius: { 30.17 }
        )

        let update = await provider.sample()

        XCTAssertEqual(
            update,
            MetricUpdate.temperature(TemperatureReading(celsius: 30.17, source: .battery))
        )
    }

    func testBatteryTemperatureReaderDecodesCentiCelsius() {
        XCTAssertEqual(
            BatteryTemperatureReader.celsius(fromBatteryTemperatureValue: 3017),
            30.17,
            accuracy: 0.001
        )
    }

    func testSMCSensorCacheBacksOffRepeatedUnavailableReads() async {
        let recorder = SMCSnapshotReadRecorder(results: [
            .init(temperatureCelsius: nil, fanRPM: nil),
            .init(temperatureCelsius: 61, fanRPM: 2_100),
        ])
        let cache = SMCSensorSnapshotCache(
            ttl: .seconds(60),
            retryInterval: .seconds(60),
            readSnapshot: {
                await recorder.nextSnapshot()
            }
        )
        let provider = TemperatureProvider(
            readTemperatureSource: { .smc },
            smcSnapshotCache: cache,
            readBatteryTemperatureCelsius: { nil }
        )

        let first = await provider.sample()
        let second = await provider.sample()
        let readCount = await recorder.currentReadCount()

        XCTAssertEqual(
            first,
            MetricUpdate.unavailable(kind: .temperature, reason: "SMC temperature sensors are not available")
        )
        XCTAssertEqual(second, first)
        XCTAssertEqual(readCount, 1)
    }
}

private actor SMCSnapshotReadRecorder {
    private let results: [SMCSensorSnapshot]
    private var index = 0
    private var readCount = 0

    init(results: [SMCSensorSnapshot]) {
        self.results = results
    }

    func nextSnapshot() -> SMCSensorSnapshot {
        defer {
            readCount += 1
            index = min(index + 1, results.count - 1)
        }
        return results[index]
    }

    func currentReadCount() -> Int {
        readCount
    }
}
