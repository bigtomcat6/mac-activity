import XCTest
@testable import MacActivityCore

final class MemoryReleaseServiceTests: XCTestCase {
    func testReleaseComputesReclaimedBytesAndPercent() async {
        let reader = MemoryReadingRecorder(readings: [
            MemoryReading(usedBytes: 8_000, totalBytes: 10_000),
            MemoryReading(usedBytes: 6_500, totalBytes: 10_000),
        ])
        let cleaner = MemoryCleanerRecorder(results: [.succeeded])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: cleaner)

        let result = await service.release()

        let callCount = await cleaner.callCount()
        XCTAssertEqual(result, .released(bytes: 1_500, percentOfTotal: 15))
        XCTAssertEqual(callCount, 1)
    }

    func testReleaseFloorsNegativeReclaimedBytesToZero() async {
        let reader = MemoryReadingRecorder(readings: [
            MemoryReading(usedBytes: 6_000, totalBytes: 10_000),
            MemoryReading(usedBytes: 7_000, totalBytes: 10_000),
        ])
        let cleaner = MemoryCleanerRecorder(results: [.succeeded])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: cleaner)

        let result = await service.release()

        XCTAssertEqual(result, .released(bytes: 0, percentOfTotal: 0))
    }

    func testReleasePropagatesUnavailable() async {
        let reader = MemoryReadingRecorder(readings: [
            MemoryReading(usedBytes: 8_000, totalBytes: 10_000),
        ])
        let cleaner = MemoryCleanerRecorder(results: [.unavailable])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: cleaner)

        let result = await service.release()

        XCTAssertEqual(result, .unavailable)
    }

    func testReleasePropagatesFailedExitCode() async {
        let reader = MemoryReadingRecorder(readings: [
            MemoryReading(usedBytes: 8_000, totalBytes: 10_000),
        ])
        let cleaner = MemoryCleanerRecorder(results: [.failed(exitCode: 9)])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: cleaner)

        let result = await service.release()

        XCTAssertEqual(result, .failed(exitCode: 9))
    }

    func testReleaseReportsFailedToReadMemoryWhenBeforeReadingIsMissing() async {
        let reader = MemoryReadingRecorder(readings: [nil])
        let cleaner = MemoryCleanerRecorder(results: [.succeeded])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: cleaner)

        let result = await service.release()

        let callCount = await cleaner.callCount()
        XCTAssertEqual(result, .failedToReadMemory)
        XCTAssertEqual(callCount, 0)
    }

    func testReleaseReportsFailedToReadMemoryWhenAfterReadingIsMissing() async {
        let reader = MemoryReadingRecorder(readings: [
            MemoryReading(usedBytes: 8_000, totalBytes: 10_000),
            nil,
        ])
        let cleaner = MemoryCleanerRecorder(results: [.succeeded])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: cleaner)

        let result = await service.release()

        let callCount = await cleaner.callCount()
        XCTAssertEqual(result, .failedToReadMemory)
        XCTAssertEqual(callCount, 1)
    }

    func testCurrentReadingReturnsReaderValue() async {
        let reading = MemoryReading(usedBytes: 8_000, totalBytes: 10_000)
        let reader = MemoryReadingRecorder(readings: [reading])
        let cleaner = MemoryCleanerRecorder(results: [])
        let service = MemoryReleaseService(memoryReader: reader, cleaner: cleaner)

        let result = await service.currentReading()

        XCTAssertEqual(result, reading)
    }

    func testCurrentReleasableBytesReturnsCleanerEstimate() async {
        let reader = MemoryReadingRecorder(readings: [])
        let cleaner = MemoryCleanerRecorder(results: [], estimatedReleasableBytes: 1_500)
        let service = MemoryReleaseService(memoryReader: reader, cleaner: cleaner)

        let result = await service.currentReleasableBytes()

        XCTAssertEqual(result, 1_500)
    }
}

private actor MemoryReadingRecorder: MemoryReadingProviding {
    private var readings: [MemoryReading?]

    init(readings: [MemoryReading?]) {
        self.readings = readings
    }

    func memoryReading() async -> MemoryReading? {
        guard !readings.isEmpty else { return nil }
        return readings.removeFirst()
    }
}

private actor MemoryCleanerRecorder: MemoryCleaning {
    private var results: [CleanMemoryResult]
    private let estimatedReleasableBytesValue: UInt64?
    private var calls = 0

    init(results: [CleanMemoryResult], estimatedReleasableBytes: UInt64? = nil) {
        self.results = results
        self.estimatedReleasableBytesValue = estimatedReleasableBytes
    }

    func cleanMemory() async -> CleanMemoryResult {
        calls += 1
        guard !results.isEmpty else { return .succeeded }
        return results.removeFirst()
    }

    func estimatedReleasableBytes() async -> UInt64? {
        estimatedReleasableBytesValue
    }

    func callCount() -> Int {
        calls
    }
}
