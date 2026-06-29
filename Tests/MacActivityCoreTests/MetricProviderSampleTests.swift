import XCTest
@testable import MacActivityCore

final class MetricProviderSampleTests: XCTestCase {
    func testCPUProviderSamplesInitialAndDeltaUsage() async {
        let provider = CPUProvider()

        let firstUpdate = await provider.sample()
        let secondUpdate = await provider.sample()

        guard case let .cpu(firstReading) = firstUpdate else {
            return XCTFail("Expected CPU update, got \(firstUpdate)")
        }
        guard case let .cpu(secondReading) = secondUpdate else {
            return XCTFail("Expected CPU update, got \(secondUpdate)")
        }

        XCTAssertEqual(firstReading.usagePercent, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(secondReading.usagePercent, 0)
        XCTAssertLessThanOrEqual(secondReading.usagePercent, 100)
    }

    func testDiskProviderSamplesTemporaryVolume() async {
        let provider = DiskProvider(volumeURL: FileManager.default.temporaryDirectory)

        let update = await provider.sample()

        guard case let .disk(reading) = update else {
            return XCTFail("Expected disk update, got \(update)")
        }

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

    func testSwapProviderSamplesSystemSwapState() async {
        let provider = SwapProvider()

        let update = await provider.sample()

        guard case let .swap(reading) = update else {
            return XCTFail("Expected swap update, got \(update)")
        }

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
