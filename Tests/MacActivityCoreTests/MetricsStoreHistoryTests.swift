import XCTest
@testable import MacActivityCore

@MainActor
final class MetricsStoreHistoryTests: XCTestCase {
    func testHistoryKeepsOnlyNewestSixtySamples() {
        let store = MetricsStore()

        for index in 0..<65 {
            store.apply(
                [
                    .cpu(CPUReading(usagePercent: Double(index))),
                    .temperature(TemperatureReading(celsius: 40 + Double(index) * 0.5)),
                    .fan(FanReading(rpm: 1_800 + index * 10)),
                    .network(
                        NetworkReading(
                            downloadBytesPerSecond: Double(index * 1_000),
                            uploadBytesPerSecond: Double(index * 500)
                        )
                    ),
                ],
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }

        XCTAssertEqual(store.history.samples.count, 60)
        XCTAssertEqual(store.history.samples.first?.timestamp, Date(timeIntervalSince1970: 5))
        XCTAssertEqual(store.history.samples.last?.cpuUsagePercent, 64)
        XCTAssertEqual(store.history.samples.last?.temperatureCelsius, 72)
        XCTAssertEqual(store.history.samples.last?.fanRPM, 2_440)
        XCTAssertEqual(store.history.samples.last?.downloadBytesPerSecond, 64_000)
    }
}
