import XCTest
@testable import MacActivityCore

final class MetricProviderSampleTests: XCTestCase {
    func testCPUProviderSamplesInitialAndDeltaUsage() async throws {
        let provider = CPUProvider()

        let firstUpdate = await provider.sample()
        let secondUpdate = await provider.sample()

        let firstReading = try XCTUnwrap(Mirror(reflecting: firstUpdate).children.first?.value as? CPUReading)
        let secondReading = try XCTUnwrap(Mirror(reflecting: secondUpdate).children.first?.value as? CPUReading)

        XCTAssertEqual(firstReading.usagePercent, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(secondReading.usagePercent, 0)
        XCTAssertLessThanOrEqual(secondReading.usagePercent, 100)
    }

    func testDiskProviderSamplesTemporaryVolume() async throws {
        let provider = DiskProvider(volumeURL: FileManager.default.temporaryDirectory)

        let update = await provider.sample()

        let reading = try XCTUnwrap(Mirror(reflecting: update).children.first?.value as? DiskReading)

        XCTAssertGreaterThan(reading.totalBytes, 0)
        XCTAssertLessThanOrEqual(reading.usedBytes, reading.totalBytes)
    }

    func testDiskProviderReportsStaleForMissingVolume() async {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let provider = DiskProvider(volumeURL: missingURL)

        let update = await provider.sample()

        XCTAssertEqual(update, .stale(kind: .disk, reason: "Unable to read disk usage"))
    }

    func testSwapProviderSamplesSystemSwapState() async throws {
        let provider = SwapProvider()

        let update = await provider.sample()

        let reading = try XCTUnwrap(Mirror(reflecting: update).children.first?.value as? SwapReading)

        XCTAssertLessThanOrEqual(reading.usedBytes, reading.totalBytes)
    }

    func testNoopLaunchAtLoginServiceIgnoresStateChanges() throws {
        let service = NoopLaunchAtLoginService()

        try service.setEnabled(true)
        XCTAssertFalse(service.currentStatus())

        try service.setEnabled(false)
        XCTAssertFalse(service.currentStatus())
    }
}
