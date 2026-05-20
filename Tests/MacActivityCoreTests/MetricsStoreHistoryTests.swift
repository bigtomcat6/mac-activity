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
        XCTAssertEqual(store.history.samples.last?.downloadBytesPerSecond, 64_000)
    }
}
