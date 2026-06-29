import XCTest
@testable import MacActivityCore

final class TemperatureProviderTests: XCTestCase {
    func testTemperatureSourceSelectionStoreReadsAndUpdatesSource() async {
        let store = TemperatureSourceSelectionStore(initialSource: .smc)

        let initialSource = await store.read()
        await store.set(.battery)
        let updatedSource = await store.read()

        XCTAssertEqual(initialSource, .smc)
        XCTAssertEqual(updatedSource, .battery)
    }

    func testSamplesSMCAndBatteryTemperatureTogether() async {
        let provider = TemperatureProvider(
            readSMCTemperatureCelsius: { 55.4 },
            readBatteryTemperatureCelsius: { 30.17 }
        )

        let update = await provider.sample()

        XCTAssertEqual(
            update,
            MetricUpdate.temperatures([
                TemperatureReading(celsius: 55.4, source: .smc),
                TemperatureReading(celsius: 30.17, source: .battery)
            ])
        )
    }

    func testReportsUnavailableWhenNoTemperatureSourceIsAvailable() async {
        let provider = TemperatureProvider(
            readSMCTemperatureCelsius: { nil },
            readBatteryTemperatureCelsius: { nil }
        )

        let update = await provider.sample()

        XCTAssertEqual(
            update,
            MetricUpdate.unavailable(kind: .temperature, reason: "Temperature sensors are not available")
        )
    }

    func testSamplesBatteryTemperatureWhenSMCIsUnavailable() async {
        let provider = TemperatureProvider(
            readSMCTemperatureCelsius: { nil },
            readBatteryTemperatureCelsius: { 30.17 }
        )

        let update = await provider.sample()

        XCTAssertEqual(
            update,
            MetricUpdate.temperatures([
                TemperatureReading(celsius: 30.17, source: .battery)
            ])
        )
    }

    func testSamplesSMCTemperatureWhenBatteryIsUnavailable() async {
        let provider = TemperatureProvider(
            readSMCTemperatureCelsius: { 55.4 },
            readBatteryTemperatureCelsius: { nil }
        )

        let update = await provider.sample()

        XCTAssertEqual(
            update,
            MetricUpdate.temperatures([
                TemperatureReading(celsius: 55.4, source: .smc)
            ])
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
            .init(temperatureCelsius: 61, fanRPM: 2_100)
        ])
        let cache = SMCSensorSnapshotCache(
            ttl: .seconds(60),
            retryInterval: .seconds(60),
            readSnapshot: {
                await recorder.nextSnapshot()
            }
        )
        let provider = TemperatureProvider(
            smcSnapshotCache: cache,
            readBatteryTemperatureCelsius: { nil }
        )

        let first = await provider.sample()
        let second = await provider.sample()
        let readCount = await recorder.currentReadCount()

        XCTAssertEqual(
            first,
            MetricUpdate.unavailable(kind: .temperature, reason: "Temperature sensors are not available")
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
