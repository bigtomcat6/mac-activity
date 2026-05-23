import Darwin.Mach
import XCTest
@testable import MacActivityCore

final class MemoryProviderTests: XCTestCase {
    func testMakeReadingExcludesReclaimablePagesFromUsedMemory() {
        var stats = vm_statistics64_data_t()
        stats.inactive_count = 7
        stats.internal_page_count = 10
        stats.purgeable_count = 4
        stats.wire_count = 3
        stats.compressor_page_count = 2

        let reading = MemoryProvider.makeReading(
            pageSize: 1_024,
            stats: stats,
            totalBytes: 32_768
        )

        XCTAssertEqual(
            reading,
            MemoryReading(usedBytes: 11_264, totalBytes: 32_768)
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

    func testActiveAppMemoryRankingSortsDescendingAndUsesNameTieBreaker() {
        let entries = [
            ActiveAppMemoryEntry(
                processIdentifier: 101,
                name: "Notes",
                bundleIdentifier: "com.apple.Notes",
                residentMemoryBytes: 2_048,
                isTerminable: true
            ),
            ActiveAppMemoryEntry(
                processIdentifier: 102,
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                residentMemoryBytes: 4_096,
                isTerminable: true
            ),
            ActiveAppMemoryEntry(
                processIdentifier: 103,
                name: "Calendar",
                bundleIdentifier: "com.apple.iCal",
                residentMemoryBytes: 2_048,
                isTerminable: true
            ),
        ]

        let ranked = ActiveAppMemoryService.sortedByMemory(entries, limit: 3)

        XCTAssertEqual(
            ranked.map(\.name),
            ["Safari", "Calendar", "Notes"]
        )
    }

    func testIOAcceleratorCacheReusesFreshStatsAcrossProviders() async {
        let recorder = IOAcceleratorReadRecorder()
        let cache = IOAcceleratorStatsCache(
            ttl: .seconds(60),
            readStats: {
                await recorder.nextStats()
            }
        )
        let gpuProvider = GPUProvider(cache: cache)
        let vramProvider = VRAMProvider(cache: cache)

        _ = await gpuProvider.sample()
        _ = await vramProvider.sample()

        let readCount = await recorder.currentReadCount()
        XCTAssertEqual(readCount, 1)
    }
}

private actor IOAcceleratorReadRecorder {
    private var readCount = 0

    func nextStats() -> IOAcceleratorStats {
        readCount += 1
        return IOAcceleratorStats(
            gpuUsagePercent: 55,
            memory: VRAMReading(usedBytes: 1_024, totalBytes: 2_048)
        )
    }

    func currentReadCount() -> Int {
        readCount
    }
}
