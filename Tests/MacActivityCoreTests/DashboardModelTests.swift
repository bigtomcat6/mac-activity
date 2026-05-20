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

    func testModelBuildsProgressAndNetworkTrendFromSharedHistory() {
        let store = MetricsStore()
        let model = DashboardModel(store: store)

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 25)),
                .memory(MemoryReading(usedBytes: 4_000, totalBytes: 8_000)),
                .network(NetworkReading(downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500)),
                .battery(BatteryReading(percentage: 80, isCharging: false)),
            ],
            timestamp: Date(timeIntervalSince1970: 1)
        )
        store.apply(
            [
                .cpu(CPUReading(usagePercent: 40)),
                .memory(MemoryReading(usedBytes: 6_000, totalBytes: 8_000)),
                .network(NetworkReading(downloadBytesPerSecond: 2_000, uploadBytesPerSecond: 1_000)),
                .battery(BatteryReading(percentage: 78, isCharging: false)),
            ],
            timestamp: Date(timeIntervalSince1970: 2)
        )

        let cpu = try! XCTUnwrap(model.metrics.first { $0.kind == .cpu })
        let memory = try! XCTUnwrap(model.metrics.first { $0.kind == .memory })
        let network = try! XCTUnwrap(model.metrics.first { $0.kind == .network })
        let battery = try! XCTUnwrap(model.metrics.first { $0.kind == .battery })

        XCTAssertEqual(cpu.style, .progress)
        XCTAssertEqual(try! XCTUnwrap(cpu.progress), 0.4, accuracy: 0.001)
        XCTAssertEqual(memory.style, .progress)
        XCTAssertEqual(try! XCTUnwrap(memory.progress), 0.75, accuracy: 0.001)
        XCTAssertEqual(battery.style, .progress)
        XCTAssertEqual(try! XCTUnwrap(battery.progress), 0.78, accuracy: 0.001)
        XCTAssertEqual(network.style, .sparkline)
        XCTAssertEqual(network.trend.map(\.downloadBytesPerSecond), [1_000, 2_000])
        XCTAssertEqual(network.trend.map(\.uploadBytesPerSecond), [500, 1_000])
    }
}
