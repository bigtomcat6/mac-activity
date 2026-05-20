import XCTest
@testable import MacActivityCore

@MainActor
final class DashboardModelTests: XCTestCase {
    func testModelUsesSharedSnapshotAndHidesUnsupportedSensors() {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 39.2)),
                .memory(MemoryReading(usedBytes: 8_589_934_592, totalBytes: 17_179_869_184)),
                .temperature(TemperatureReading(celsius: 55.1)),
                .unavailable(kind: .fan, reason: "Unsupported"),
            ],
            timestamp: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(model.metrics.map(\.kind), [.cpu, .memory, .temperature])
        XCTAssertEqual(model.metrics.first?.value, "39%")
    }

    func testModelBuildsChartMetricsFromSharedHistory() {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 25)),
                .memory(MemoryReading(usedBytes: 4_000, totalBytes: 8_000)),
                .network(NetworkReading(downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500)),
                .battery(BatteryReading(percentage: 80, isCharging: false)),
                .temperature(TemperatureReading(celsius: 55.1)),
            ],
            timestamp: Date(timeIntervalSince1970: 1)
        )
        store.apply(
            [
                .cpu(CPUReading(usagePercent: 40)),
                .memory(MemoryReading(usedBytes: 6_000, totalBytes: 8_000)),
                .network(NetworkReading(downloadBytesPerSecond: 2_000, uploadBytesPerSecond: 1_000)),
                .battery(BatteryReading(percentage: 78, isCharging: false)),
                .temperature(TemperatureReading(celsius: 57.4)),
            ],
            timestamp: Date(timeIntervalSince1970: 2)
        )

        let cpu = try! XCTUnwrap(model.metrics.first { $0.kind == .cpu })
        let memory = try! XCTUnwrap(model.metrics.first { $0.kind == .memory })
        let network = try! XCTUnwrap(model.metrics.first { $0.kind == .network })
        let battery = try! XCTUnwrap(model.metrics.first { $0.kind == .battery })
        let temperature = try! XCTUnwrap(model.metrics.first { $0.kind == .temperature })

        XCTAssertEqual(cpu.style, .chart)
        XCTAssertEqual(try! XCTUnwrap(cpu.trend).scale, .fixed(lowerBound: 0, upperBound: 100))
        XCTAssertEqual(try! XCTUnwrap(cpu.trend).samples.map(\.primaryValue), [25, 40])

        XCTAssertEqual(memory.style, .chart)
        XCTAssertEqual(try! XCTUnwrap(memory.trend).scale, .fixed(lowerBound: 0, upperBound: 100))
        XCTAssertEqual(try! XCTUnwrap(memory.trend).samples.map(\.primaryValue), [50, 75])

        XCTAssertEqual(battery.style, .chart)
        XCTAssertEqual(try! XCTUnwrap(battery.trend).scale, .fixed(lowerBound: 0, upperBound: 100))
        XCTAssertEqual(try! XCTUnwrap(battery.trend).samples.map(\.primaryValue), [80, 78])

        XCTAssertEqual(temperature.style, .chart)
        XCTAssertEqual(try! XCTUnwrap(temperature.trend).scale, .automatic)
        XCTAssertEqual(try! XCTUnwrap(temperature.trend).samples.map(\.primaryValue), [55.1, 57.4])

        XCTAssertEqual(network.style, .chart)
        XCTAssertEqual(try! XCTUnwrap(network.trend).scale, .automatic)
        XCTAssertEqual(try! XCTUnwrap(network.trend).samples.map(\.primaryValue), [1_000, 2_000])
        XCTAssertEqual(try! XCTUnwrap(network.trend).samples.map { $0.secondaryValue ?? -1 }, [500, 1_000])
    }

    func testModelUsesTemperatureSourceSpecificTitle() {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .temperature(TemperatureReading(celsius: 30.2, source: .battery)),
            ],
            timestamp: Date(timeIntervalSince1970: 3)
        )

        let temperature = try! XCTUnwrap(model.metrics.first { $0.kind == .temperature })

        XCTAssertEqual(temperature.title, "Battery Temp")
        XCTAssertEqual(temperature.value, "30.2 C")
    }
}
