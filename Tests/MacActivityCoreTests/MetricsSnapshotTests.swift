import XCTest
@testable import MacActivityCore

final class MetricsSnapshotTests: XCTestCase {
    func testApplyingUpdatesNormalizesValuesAndIssues() {
        let originalTimestamp = Date(timeIntervalSince1970: 1_000)
        let updatedTimestamp = Date(timeIntervalSince1970: 2_000)
        let original = MetricsSnapshot(
            timestamp: originalTimestamp,
            network: NetworkReading(downloadBytesPerSecond: 512, uploadBytesPerSecond: 128)
        )

        let updated = original.applying(
            [
                .cpu(CPUReading(usagePercent: 63.4)),
                .gpu(GPUReading(usagePercent: 14.5)),
                .memory(MemoryReading(usedBytes: 8_000, totalBytes: 16_000)),
                .vram(VRAMReading(usedBytes: 2_000, totalBytes: 8_000)),
                .disk(DiskReading(usedBytes: 700, totalBytes: 1_000)),
                .swap(SwapReading(usedBytes: 300, totalBytes: 1_000)),
                .unavailable(kind: .temperature, reason: "Unsupported sensor"),
            ],
            timestamp: updatedTimestamp
        )

        XCTAssertEqual(updated.timestamp, updatedTimestamp)
        XCTAssertEqual(updated.cpu, CPUReading(usagePercent: 63.4))
        XCTAssertEqual(updated.gpu, GPUReading(usagePercent: 14.5))
        XCTAssertEqual(updated.memory, MemoryReading(usedBytes: 8_000, totalBytes: 16_000))
        XCTAssertEqual(updated.vram, VRAMReading(usedBytes: 2_000, totalBytes: 8_000))
        XCTAssertEqual(updated.disk, DiskReading(usedBytes: 700, totalBytes: 1_000))
        XCTAssertEqual(updated.swap, SwapReading(usedBytes: 300, totalBytes: 1_000))
        XCTAssertEqual(updated.network, original.network)
        XCTAssertEqual(updated.issues[.temperature], .unsupported("Unsupported sensor"))
    }

    func testApplyingTemperatureSnapshotReplacesMissingSources() {
        let original = MetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_000),
            temperatures: [
                .smc: TemperatureReading(celsius: 55, source: .smc),
                .battery: TemperatureReading(celsius: 30, source: .battery),
            ]
        )

        let updated = original.applying(
            [
                .temperatures([
                    TemperatureReading(celsius: 31, source: .battery),
                ]),
            ],
            timestamp: Date(timeIntervalSince1970: 1_001)
        )

        XCTAssertNil(updated.temperature(for: .smc))
        XCTAssertEqual(
            updated.temperature(for: .battery),
            TemperatureReading(celsius: 31, source: .battery)
        )
        XCTAssertEqual(updated.temperature, TemperatureReading(celsius: 31, source: .battery))
    }

}
