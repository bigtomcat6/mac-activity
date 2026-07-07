import AppKit
import Darwin.Mach
import XCTest
@testable import MacActivityCore

final class MemoryProviderTests: XCTestCase {
    func testMemoryProviderSamplesCurrentSystemMemory() async throws {
        let provider = MemoryProvider()

        let update = await provider.sample()

        let reading = try XCTUnwrap(Mirror(reflecting: update).children.first?.value as? MemoryReading)

        XCTAssertGreaterThan(reading.totalBytes, 0)
        XCTAssertLessThanOrEqual(reading.usedBytes, reading.totalBytes)
    }

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

    func testDiskProviderReadingUsesAppleVolumeCapacityValues() throws {
        let reading = try XCTUnwrap(DiskProvider.makeReading(totalBytes: 1_000, availableBytes: 250))

        XCTAssertEqual(reading, DiskReading(usedBytes: 750, totalBytes: 1_000))
        XCTAssertEqual(reading.usagePercent, 75, accuracy: 0.001)
    }

    func testDiskProviderReadingRejectsInvalidVolumeCapacityValues() {
        XCTAssertNil(DiskProvider.makeReading(totalBytes: 0, availableBytes: 0))
        XCTAssertEqual(
            DiskProvider.makeReading(totalBytes: 1_000, availableBytes: 1_500),
            DiskReading(usedBytes: 0, totalBytes: 1_000)
        )
    }

    func testSwapProviderReadingUsesAppleSysctlSwapUsageValues() throws {
        var usage = xsw_usage()
        usage.xsu_total = 4_096
        usage.xsu_used = 1_024
        usage.xsu_avail = 3_072

        let reading = try XCTUnwrap(SwapProvider.makeReading(usage: usage))

        XCTAssertEqual(reading, SwapReading(usedBytes: 1_024, totalBytes: 4_096))
        XCTAssertEqual(reading.usagePercent, 25, accuracy: 0.001)
    }

    func testSwapProviderReadingReportsZeroWhenNoSwapIsAllocated() throws {
        var usage = xsw_usage()
        usage.xsu_total = 0
        usage.xsu_used = 0
        usage.xsu_avail = 0

        let reading = try XCTUnwrap(SwapProvider.makeReading(usage: usage))

        XCTAssertEqual(reading, SwapReading(usedBytes: 0, totalBytes: 0))
        XCTAssertEqual(reading.usagePercent, 0, accuracy: 0.001)
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
            )
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

    func testActiveAppMemoryEntryMatchesTerminationTargetUsingStableBundleIdentity() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let entry = ActiveAppMemoryEntry(
            processIdentifier: 104,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: bundleURL,
            residentMemoryBytes: 4_096,
            isTerminable: true
        )

        XCTAssertTrue(entry.hasStableTerminationIdentity)
        XCTAssertTrue(
            entry.matchesTerminationTarget(
                processIdentifier: 104,
                bundleIdentifier: "com.apple.Safari",
                bundleURL: bundleURL
            )
        )
    }

    func testActiveAppMemoryEntryRejectsReusedPIDWithDifferentBundleIdentifier() {
        let entry = ActiveAppMemoryEntry(
            processIdentifier: 104,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            residentMemoryBytes: 4_096,
            isTerminable: true
        )

        XCTAssertFalse(
            entry.matchesTerminationTarget(
                processIdentifier: 104,
                bundleIdentifier: "com.example.Other",
                bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")
            )
        )
    }

    func testActiveAppMemoryEntryRejectsReusedPIDWithDifferentBundleURL() {
        let entry = ActiveAppMemoryEntry(
            processIdentifier: 104,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"),
            residentMemoryBytes: 4_096,
            isTerminable: true
        )

        XCTAssertFalse(
            entry.matchesTerminationTarget(
                processIdentifier: 104,
                bundleIdentifier: "com.apple.Safari",
                bundleURL: URL(fileURLWithPath: "/Applications/Other.app")
            )
        )
    }

    func testActiveAppMemoryEntryRequiresStableTerminationIdentity() {
        let entry = ActiveAppMemoryEntry(
            processIdentifier: 104,
            name: "Process 104",
            bundleIdentifier: nil,
            bundleURL: nil,
            residentMemoryBytes: 4_096,
            isTerminable: true
        )

        XCTAssertFalse(entry.hasStableTerminationIdentity)
        XCTAssertFalse(
            entry.matchesTerminationTarget(
                processIdentifier: 104,
                bundleIdentifier: nil,
                bundleURL: nil
            )
        )
    }

    @MainActor
    func testActiveAppMemoryServiceRejectsTerminationWithoutStableIdentity() {
        let service = ActiveAppMemoryService()
        let entry = ActiveAppMemoryEntry(
            processIdentifier: 104,
            name: "Process 104",
            bundleIdentifier: nil,
            bundleURL: nil,
            residentMemoryBytes: 4_096,
            isTerminable: true
        )

        XCTAssertEqual(service.requestTermination(entry), .notTerminable)
    }

    @MainActor
    func testActiveAppMemoryServiceReportsNotFoundForMissingStableTarget() {
        let service = ActiveAppMemoryService()
        let entry = ActiveAppMemoryEntry(
            processIdentifier: -1,
            name: "Missing App",
            bundleIdentifier: "com.example.missing",
            bundleURL: nil,
            residentMemoryBytes: 4_096,
            isTerminable: true
        )

        XCTAssertEqual(service.requestTermination(entry), .notFound)
    }

    @MainActor
    func testActiveAppMemoryServiceRejectsReusedPIDIdentityMismatch() throws {
        let runningApp = try XCTUnwrap(
            NSWorkspace.shared.runningApplications.first { app in
                app.activationPolicy == .regular
                    && app.isTerminated == false
                    && app.bundleIdentifier != nil
            }
        )
        let bundleIdentifier = try XCTUnwrap(runningApp.bundleIdentifier)
        let service = ActiveAppMemoryService()
        let entry = ActiveAppMemoryEntry(
            processIdentifier: runningApp.processIdentifier,
            name: runningApp.localizedName ?? bundleIdentifier,
            bundleIdentifier: "\(bundleIdentifier).mismatch",
            bundleURL: runningApp.bundleURL,
            residentMemoryBytes: 4_096,
            isTerminable: true
        )

        XCTAssertEqual(service.requestTermination(entry), .notFound)
    }

    func testCleanMemoryDefaultCommandsPreferSystemSbinPurgeThenLegacyUsrBinPurge() {
        XCTAssertEqual(
            CleanMemoryService.defaultCommands,
            [
                MemoryCleanCommand(executableURL: URL(fileURLWithPath: "/usr/sbin/purge")),
                MemoryCleanCommand(executableURL: URL(fileURLWithPath: "/usr/bin/purge"))
            ]
        )
    }

    func testCleanMemoryServiceUsesLocalReclaimerBeforePurgeCommand() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [true])
        let runner = MemoryCleanCommandRecorder(results: [.failed(exitCode: 1)])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory(strategy: .full)
        let localCallCount = await localReclaimer.currentCallCount()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(localCallCount, 1)
        XCTAssertEqual(commands, [])
    }

    func testCleanMemoryExtensionUsesFullStrategyAndForwardsEstimate() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [true], estimatedReleasableBytes: 123)
        let service: MemoryCleaning = CleanMemoryService(localReclaimer: localReclaimer, runner: MemoryCleanCommandRecorder(results: []))

        let result = await service.cleanMemory()
        let estimate = await service.estimatedReleasableBytes()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(estimate, 123)
    }

    func testCleanMemoryServiceSingleCommandInitializerAndEmptyCommands() async {
        let command = MemoryCleanCommand(executableURL: URL(fileURLWithPath: "/missing/purge"), arguments: ["--dry-run"])
        let singleRunner = MemoryCleanCommandRecorder(results: [.failed(exitCode: 42)])
        let singleCommandService = CleanMemoryService(
            localReclaimer: MemoryLocalReclaimerRecorder(results: [false]),
            command: command,
            runner: singleRunner
        )
        let emptyCommandService = CleanMemoryService(
            localReclaimer: MemoryLocalReclaimerRecorder(results: [false]),
            commands: [],
            runner: MemoryCleanCommandRecorder(results: [])
        )

        let singleResult = await singleCommandService.cleanMemory(strategy: .full)
        let singleCommands = await singleRunner.recordedCommands()
        let emptyResult = await emptyCommandService.cleanMemory(strategy: .purge)

        XCTAssertEqual(singleResult, .failed(exitCode: 42))
        XCTAssertEqual(singleCommands, [command])
        XCTAssertEqual(emptyResult, .unavailable)
    }

    func testCleanMemoryServiceRunsDefaultCommandWhenLocalReclaimerFails() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [false])
        let runner = MemoryCleanCommandRecorder(results: [.succeeded])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory(strategy: .full)
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(commands, [CleanMemoryService.defaultCommands[0]])
    }

    func testCleanMemoryServiceFallsBackWhenPreferredPurgeCommandIsUnavailable() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [false])
        let runner = MemoryCleanCommandRecorder(results: [.unavailable, .succeeded])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory(strategy: .full)
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(commands, CleanMemoryService.defaultCommands)
    }

    func testCleanMemoryServiceReportsFailedPurgeCommands() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [false])
        let runner = MemoryCleanCommandRecorder(results: [.failed(exitCode: 7), .failed(exitCode: 9)])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory(strategy: .full)
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .failed(exitCode: 9))
        XCTAssertEqual(commands, CleanMemoryService.defaultCommands)
    }

    func testCleanMemoryServiceLocalStrategyDoesNotRunPurgeCommands() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [false])
        let runner = MemoryCleanCommandRecorder(results: [.succeeded])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory(strategy: .local)
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(commands, [])
    }

    func testCleanMemoryServicePurgeStrategyDoesNotRunLocalReclaimer() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [true])
        let runner = MemoryCleanCommandRecorder(results: [.succeeded])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory(strategy: .purge)
        let localCallCount = await localReclaimer.currentCallCount()
        let commands = await runner.recordedCommands()

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(localCallCount, 0)
        XCTAssertEqual(commands, [CleanMemoryService.defaultCommands[0]])
    }

    func testCleanMemoryServiceReportsUnavailableWhenAllCommandsAreUnavailable() async {
        let localReclaimer = MemoryLocalReclaimerRecorder(results: [false])
        let runner = MemoryCleanCommandRecorder(results: [.unavailable, .unavailable])
        let service = CleanMemoryService(localReclaimer: localReclaimer, runner: runner)

        let result = await service.cleanMemory(strategy: .full)
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
                256 * 1_024 * 1_024
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

    func testSystemLocalMemoryReclaimerHandlesNilZeroAndInvalidTargets() async {
        let nilReaderReclaimer = SystemLocalMemoryReclaimer(
            reclaimableByteReader: { nil },
            pressureReclaimer: MemoryPressureReclaimerRecorder(results: [true])
        )
        let zeroReclaimerRecorder = MemoryPressureReclaimerRecorder(results: [true])
        let zeroReclaimer = SystemLocalMemoryReclaimer(
            reclaimableByteReader: { 0 },
            pressureReclaimer: zeroReclaimerRecorder
        )
        let invalidBatchReclaimer = SystemLocalMemoryReclaimer(
            maximumByteCount: 256,
            batchByteCount: 0,
            reclaimableByteReader: { 256 },
            pressureReclaimer: MemoryPressureReclaimerRecorder(results: [true])
        )

        let nilResult = await nilReaderReclaimer.reclaimMemory()
        let nilEstimate = await nilReaderReclaimer.estimatedReleasableBytes()
        let zeroResult = await zeroReclaimer.reclaimMemory()
        let zeroByteCounts = await zeroReclaimerRecorder.recordedByteCounts()
        let invalidBatchResult = await invalidBatchReclaimer.reclaimMemory()

        XCTAssertFalse(nilResult)
        XCTAssertNil(nilEstimate)
        XCTAssertTrue(zeroResult)
        XCTAssertEqual(zeroByteCounts, [0])
        XCTAssertFalse(invalidBatchResult)
    }

    func testSystemMemoryPressureReclaimerHandlesZeroByteRequest() async {
        let reclaimer = SystemMemoryPressureReclaimer()

        let result = await reclaimer.reclaim(byteCount: 0)

        XCTAssertTrue(result)
    }

    func testCurrentReclaimableByteCountReadsLiveVMStatistics() {
        XCTAssertNotNil(SystemLocalMemoryReclaimer.currentReclaimableByteCount())
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

    func testProcessTreeAggregatorAddsDescendantResidentMemoryToOwningApp() {
        let snapshots = [
            ProcessMemorySnapshot(processIdentifier: 100, parentProcessIdentifier: 1, residentMemoryBytes: 1_000),
            ProcessMemorySnapshot(processIdentifier: 101, parentProcessIdentifier: 100, residentMemoryBytes: 200),
            ProcessMemorySnapshot(processIdentifier: 102, parentProcessIdentifier: 100, residentMemoryBytes: 300),
            ProcessMemorySnapshot(processIdentifier: 103, parentProcessIdentifier: 102, residentMemoryBytes: 400),
            ProcessMemorySnapshot(processIdentifier: 999, parentProcessIdentifier: 1, residentMemoryBytes: 9_000)
        ]

        let aggregate = ProcessTreeResidentMemoryAggregator.aggregate(
            rootProcessIdentifiers: [100],
            snapshots: snapshots
        )

        XCTAssertEqual(
            aggregate[100],
            ProcessTreeResidentMemoryAggregate(
                mainResidentBytes: 1_000,
                childResidentBytes: 900,
                aggregateResidentBytes: 1_900,
                childCount: 3
            )
        )
    }

    func testProcessTreeAggregatorDoesNotAttachOrphansToUnrelatedApps() {
        let snapshots = [
            ProcessMemorySnapshot(processIdentifier: 100, parentProcessIdentifier: 1, residentMemoryBytes: 1_000),
            ProcessMemorySnapshot(processIdentifier: 200, parentProcessIdentifier: 404, residentMemoryBytes: 3_000)
        ]

        let aggregate = ProcessTreeResidentMemoryAggregator.aggregate(
            rootProcessIdentifiers: [100],
            snapshots: snapshots
        )

        XCTAssertEqual(
            aggregate[100],
            ProcessTreeResidentMemoryAggregate(
                mainResidentBytes: 1_000,
                childResidentBytes: 0,
                aggregateResidentBytes: 1_000,
                childCount: 0
            )
        )
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
                128 * 1_024 * 1_024
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

    func testGPUAndVRAMProvidersReturnReadingsAndUnavailableStates() async {
        let populatedCache = IOAcceleratorStatsCache(
            readStats: {
                IOAcceleratorStats(
                    gpuUsagePercent: 55,
                    memory: VRAMReading(usedBytes: 1_024, totalBytes: 2_048)
                )
            }
        )
        let emptyCache = IOAcceleratorStatsCache(readStats: { IOAcceleratorStats() })

        let gpuUpdate = await GPUProvider(cache: populatedCache).sample()
        let vramUpdate = await VRAMProvider(cache: populatedCache).sample()
        let unavailableGPUUpdate = await GPUProvider(cache: emptyCache).sample()
        let unavailableVRAMUpdate = await VRAMProvider(cache: emptyCache).sample()

        XCTAssertEqual(gpuUpdate, .gpu(GPUReading(usagePercent: 55)))
        XCTAssertEqual(vramUpdate, .vram(VRAMReading(usedBytes: 1_024, totalBytes: 2_048)))
        XCTAssertEqual(unavailableGPUUpdate, .unavailable(kind: .gpu, reason: "GPU usage is not exposed by IOAccelerator"))
        XCTAssertEqual(unavailableVRAMUpdate, .unavailable(kind: .vram, reason: "GPU memory usage is not exposed by IOAccelerator"))
    }

    func testProcessMemoryCleanCommandRunnerReportsUnavailableSuccessAndFailure() async {
        let runner = ProcessMemoryCleanCommandRunner()

        let unavailable = await runner.run(MemoryCleanCommand(executableURL: URL(fileURLWithPath: "/missing/purge")))
        let succeeded = await runner.run(MemoryCleanCommand(executableURL: URL(fileURLWithPath: "/usr/bin/true")))
        let failed = await runner.run(MemoryCleanCommand(executableURL: URL(fileURLWithPath: "/usr/bin/false")))

        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertEqual(succeeded, .succeeded)
        XCTAssertEqual(failed, .failed(exitCode: 1))
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
