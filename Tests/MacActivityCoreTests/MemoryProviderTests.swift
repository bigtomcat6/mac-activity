import Darwin.Mach
import XCTest
@testable import MacActivityCore

final class MemoryProviderTests: XCTestCase {
    func testMakeReadingExcludesFileBackedInactivePagesFromUsedMemory() {
        var stats = vm_statistics64_data_t()
        stats.inactive_count = 7
        stats.wire_count = 3
        stats.compressor_page_count = 2
        stats.internal_page_count = 4

        let reading = MemoryProvider.makeReading(
            pageSize: 1_024,
            stats: stats,
            totalBytes: 32_768
        )

        XCTAssertEqual(
            reading,
            MemoryReading(usedBytes: 9_216, totalBytes: 32_768)
        )
    }

    func testMakeReadingClampsUsageToPhysicalMemory() {
        var stats = vm_statistics64_data_t()
        stats.wire_count = 8
        stats.compressor_page_count = 8
        stats.internal_page_count = 8

        let reading = MemoryProvider.makeReading(
            pageSize: 1_024,
            stats: stats,
            totalBytes: 16_384
        )

        XCTAssertEqual(
            reading,
            MemoryReading(usedBytes: 16_384, totalBytes: 16_384)
        )
    }
}
