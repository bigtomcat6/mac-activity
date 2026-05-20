import XCTest
@testable import MacActivityCore

final class TemperatureProviderTests: XCTestCase {
    func testReportsUnavailableWhenSMCTemperatureIsUnavailable() async {
        let provider = TemperatureProvider(
            readTemperatureSource: { .smc },
            readSMCTemperatureCelsius: { nil },
            readBatteryTemperatureCelsius: { 30.17 }
        )

        let update = await provider.sample()

        XCTAssertEqual(
            update,
            MetricUpdate.unavailable(kind: .temperature, reason: "SMC temperature sensors are not available")
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
}
