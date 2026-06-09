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
                bundleURL: URL(fileURLWithPath: "/Applications/Notes.app"),
                residentMemoryBytes: 2_048,
                isTerminable: true
            ),
            ActiveAppMemoryEntry(
                processIdentifier: 102,
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
                residentMemoryBytes: 4_096,
                isTerminable: true
            ),
            ActiveAppMemoryEntry(
                processIdentifier: 103,
                name: "Calendar",
                bundleIdentifier: "com.apple.iCal",
                bundleURL: URL(fileURLWithPath: "/System/Applications/Calendar.app"),
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

    func testActiveAppMemoryEntryCarriesBundleURLForIconRendering() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let entry = ActiveAppMemoryEntry(
            processIdentifier: 104,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: bundleURL,
            residentMemoryBytes: 4_096,
            isTerminable: true
        )

        XCTAssertEqual(entry.bundleURL, bundleURL)
    }

    func testCleanMemoryDefaultCommandsPreferSystemSbinPurgeThenLegacyUsrBinPurge() {
        XCTAssertEqual(
            CleanMemoryService.defaultCommands,
            [
                MemoryCleanCommand(executableURL: URL(fileURLWithPath: "/usr/sbin/purge")),
                MemoryCleanCommand(executableURL: URL(fileURLWithPath: "/usr/bin/purge")),
            ]
        )
    }

    func testCleanMemoryServiceUsesLocalReclaimerBeforePurgeCommand() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [true])
        let runner = MemoryCleanCommandRecorder(results: [.failed(exitCode: 1)])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory()
        let localCallCount = await localReclaimer.currentCallCount()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(localCallCount, 1)
        XCTAssertEqual(commands, [])
    }

    func testCleanMemoryServiceRunsDefaultCommandWhenLocalReclaimerFails() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [false])
        let runner = MemoryCleanCommandRecorder(results: [.succeeded])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(commands, [CleanMemoryService.defaultCommands[0]])
    }

    func testCleanMemoryServiceFallsBackWhenPreferredPurgeCommandIsUnavailable() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [false])
        let runner = MemoryCleanCommandRecorder(results: [.unavailable, .succeeded])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(commands, CleanMemoryService.defaultCommands)
    }

    func testCleanMemoryServiceTreatsFailedPurgeCommandsAsCompletedFallback() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [false])
        let runner = MemoryCleanCommandRecorder(results: [.failed(exitCode: 1), .failed(exitCode: 1)])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(commands, CleanMemoryService.defaultCommands)
    }

    func testCleanMemoryServiceReportsUnavailableWhenAllCommandsAreUnavailable() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [false])
        let runner = MemoryCleanCommandRecorder(results: [.unavailable, .unavailable])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(commands, CleanMemoryService.defaultCommands)
    }

    func testSystemLocalMemoryReclaimerCapsAndBatchesPressureBytes() async {
        let pressureReclaimer = MemoryPressureReclaimerRecorder(results: [true, true, true])
        let reclaimer = SystemLocalMemoryReclaimer(
            maximumByteCount: 768 * 1_024 * 1_024,
            batchByteCount: 256 * 1_024 * 1_024,
            reclaimableByteReader: { 10 * 1_024 * 1_024 * 1_024 },
            pressureReclaimer: pressureReclaimer
        )

        let result = await reclaimer.reclaimMemory()
        let byteCounts = await pressureReclaimer.recordedByteCounts()

        XCTAssertEqual(result, true)
        XCTAssertEqual(
            byteCounts,
            [
                256 * 1_024 * 1_024,
                256 * 1_024 * 1_024,
                256 * 1_024 * 1_024,
            ]
        )
    }

    func testSystemLocalMemoryReclaimerDoesNotExposePressureTargetAsConfirmedReleasableBytes() async {
        let reclaimer = SystemLocalMemoryReclaimer(
            maximumByteCount: 768 * 1_024 * 1_024,
            batchByteCount: 256 * 1_024 * 1_024,
            reclaimableByteReader: { 10 * 1_024 * 1_024 * 1_024 },
            pressureReclaimer: MemoryPressureReclaimerRecorder(results: [])
        )

        let estimate = await reclaimer.estimatedReleasableBytes()

        XCTAssertEqual(estimate, 0)
    }

    func testSystemLocalMemoryReclaimerDoesNotEstimateSmallerPressureTargetAsConfirmedRelease() async {
        let reclaimer = SystemLocalMemoryReclaimer(
            maximumByteCount: 768 * 1_024 * 1_024,
            batchByteCount: 256 * 1_024 * 1_024,
            reclaimableByteReader: { 384 * 1_024 * 1_024 },
            pressureReclaimer: MemoryPressureReclaimerRecorder(results: [])
        )

        let estimate = await reclaimer.estimatedReleasableBytes()

        XCTAssertEqual(estimate, 0)
    }

    func testSystemLocalMemoryReclaimerDoesNotCountAlreadyFreePagesAsReleasable() {
        var stats = vm_statistics64_data_t()
        stats.free_count = 2_048
        stats.inactive_count = 3
        stats.purgeable_count = 2

        let reclaimableBytes = SystemLocalMemoryReclaimer.reclaimableByteCount(
            pageSize: 1_024,
            stats: stats
        )

        XCTAssertEqual(reclaimableBytes, 5 * 1_024)
    }

    func testSystemLocalMemoryReclaimerUsesSmallerFinalBatch() async {
        let pressureReclaimer = MemoryPressureReclaimerRecorder(results: [true, true])
        let reclaimer = SystemLocalMemoryReclaimer(
            maximumByteCount: 768 * 1_024 * 1_024,
            batchByteCount: 256 * 1_024 * 1_024,
            reclaimableByteReader: { 384 * 1_024 * 1_024 },
            pressureReclaimer: pressureReclaimer
        )

        let result = await reclaimer.reclaimMemory()
        let byteCounts = await pressureReclaimer.recordedByteCounts()

        XCTAssertEqual(result, true)
        XCTAssertEqual(
            byteCounts,
            [
                256 * 1_024 * 1_024,
                128 * 1_024 * 1_024,
            ]
        )
    }

    func testSystemLocalMemoryReclaimerReturnsFalseWhenFirstBatchFails() async {
        let pressureReclaimer = MemoryPressureReclaimerRecorder(results: [false])
        let reclaimer = SystemLocalMemoryReclaimer(
            maximumByteCount: 768 * 1_024 * 1_024,
            batchByteCount: 256 * 1_024 * 1_024,
            reclaimableByteReader: { 512 * 1_024 * 1_024 },
            pressureReclaimer: pressureReclaimer
        )

        let result = await reclaimer.reclaimMemory()
        let byteCounts = await pressureReclaimer.recordedByteCounts()

        XCTAssertEqual(result, false)
        XCTAssertEqual(byteCounts, [256 * 1_024 * 1_024])
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

private actor MemoryPressureReclaimerRecorder: MemoryPressureReclaiming {
    private var results: [Bool]
    private var byteCounts: [Int] = []

    init(results: [Bool]) {
        self.results = results
    }

    func reclaim(byteCount: Int) async -> Bool {
        byteCounts.append(byteCount)
        guard results.isEmpty == false else { return false }
        return results.removeFirst()
    }

    func recordedByteCounts() -> [Int] {
        byteCounts
    }
}

private actor MemoryLocalReclaimerRecorder: LocalMemoryReclaiming {
    private var results: [Bool]
    private let estimatedReleasableBytesValue: UInt64?
    private var callCount = 0

    init(results: [Bool], estimatedReleasableBytes: UInt64? = nil) {
        self.results = results
        self.estimatedReleasableBytesValue = estimatedReleasableBytes
    }

    func reclaimMemory() async -> Bool {
        callCount += 1
        guard results.isEmpty == false else { return false }
        return results.removeFirst()
    }

    func currentCallCount() -> Int {
        callCount
    }

    func estimatedReleasableBytes() async -> UInt64? {
        estimatedReleasableBytesValue
    }
}

private actor MemoryCleanCommandRecorder: MemoryCleanCommandRunning {
    private var results: [CleanMemoryResult]
    private var commands: [MemoryCleanCommand] = []

    init(results: [CleanMemoryResult]) {
        self.results = results
    }

    func run(_ command: MemoryCleanCommand) async -> CleanMemoryResult {
        commands.append(command)
        guard results.isEmpty == false else { return .unavailable }
        return results.removeFirst()
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
