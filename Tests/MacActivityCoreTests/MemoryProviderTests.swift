import Darwin.Mach
import XCTest
@testable import MacActivityCore

final class MemoryProviderTests: XCTestCase {
    func testMakeReadingUsesActivityMonitorMemoryUsedSemantics() {
        var stats = vm_statistics64_data_t()
        stats.free_count = 2
        stats.external_page_count = 5
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
            MemoryReading(
                usedBytes: 25_600,
                totalBytes: 32_768,
                breakdown: MemoryBreakdown(
                    wiredBytes: 3_072,
                    activeBytes: 10_240,
                    compressedBytes: 2_048,
                    cachedBytes: 5_120,
                    availableBytes: 7_168
                )
            )
        )
        XCTAssertEqual(reading.pressurePercent, 78.125, accuracy: 0.001)
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
            MemoryReading(
                usedBytes: 16_384,
                totalBytes: 16_384,
                breakdown: MemoryBreakdown(
                    wiredBytes: 8_192,
                    activeBytes: 8_192,
                    compressedBytes: 8_192,
                    cachedBytes: 0,
                    availableBytes: 0
                )
            )
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

    func testCleanMemoryDefaultCommandUsesSystemPurgeWithoutArguments() {
        XCTAssertEqual(
            CleanMemoryService.defaultCommand,
            MemoryCleanCommand(executableURL: URL(fileURLWithPath: "/usr/bin/purge"))
        )
    }

    func testCleanMemoryServiceRunsDefaultCommandAndReportsSuccess() async {
        let runner = MemoryCleanCommandRecorder(result: .succeeded)
        let service = CleanMemoryService(runner: runner)

        let result = await service.cleanMemory()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(commands, [CleanMemoryService.defaultCommand])
    }

    func testCleanMemoryServicePropagatesUnavailableCommand() async {
        let runner = MemoryCleanCommandRecorder(result: .unavailable)
        let service = CleanMemoryService(runner: runner)

        let result = await service.cleanMemory()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(commands, [CleanMemoryService.defaultCommand])
    }

    func testCleanMemoryServicePropagatesFailedExitCode() async {
        let runner = MemoryCleanCommandRecorder(result: .failed(exitCode: 72))
        let service = CleanMemoryService(runner: runner)

        let result = await service.cleanMemory()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .failed(exitCode: 72))
        XCTAssertEqual(commands, [CleanMemoryService.defaultCommand])
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

private actor MemoryCleanCommandRecorder: MemoryCleanCommandRunning {
    private let result: CleanMemoryResult
    private var commands: [MemoryCleanCommand] = []

    init(result: CleanMemoryResult) {
        self.result = result
    }

    func run(_ command: MemoryCleanCommand) async -> CleanMemoryResult {
        commands.append(command)
        return result
    }

    func recordedCommands() -> [MemoryCleanCommand] {
        commands
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
