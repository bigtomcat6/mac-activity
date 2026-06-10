import Darwin
import Darwin.Mach
import Foundation
import MacActivityCore

private enum DebugMemoryReleaseMode: String, Encodable {
    case sampleOnly
    case release
    case cooldownProbe
}

private struct DebugMemoryReleaseOptions {
    var mode: DebugMemoryReleaseMode = .sampleOnly
    var strategy: MemoryReleaseStrategy = .full
    var settleMilliseconds = 1_000
    var postSampleMilliseconds: [Int] = []
    var attempts = 3
    var spacingMilliseconds = 1_000
    var json = false
}

private struct VMStatsSnapshot {
    let pageSize: vm_size_t
    let stats: vm_statistics64_data_t
    let physicalMemory: UInt64
    let memoryReading: MemoryReading?
    let directReclaimableBytes: UInt64?
    let serviceEstimateBytes: UInt64?
}

private struct DebugMemoryReleaseReport: Encodable {
    let schemaVersion: Int
    let mode: DebugMemoryReleaseMode
    let strategy: String
    let settleMilliseconds: Int
    let postSampleMilliseconds: [Int]
    let currentReleasableBytes: UInt64?
    let currentReclaimableBytes: UInt64?
    let before: SnapshotReport
    let after: SnapshotReport?
    let afterSamples: [TimedSnapshotReport]
    let observedReleasedBytes: UInt64
    let classification: String
    let releaseResult: ReleaseResultReport?
    let cooldownAttempts: [CooldownAttemptReport]
    let warnings: [String]
}

private struct TimedSnapshotReport: Encodable {
    let offsetMilliseconds: Int
    let snapshot: SnapshotReport
}

private struct SnapshotReport: Encodable {
    let pageSize: UInt64
    let physicalMemoryBytes: UInt64
    let currentReleasableBytes: UInt64?
    let currentReclaimableBytes: UInt64?
    let inactivePlusPurgeableBytes: UInt64
    let freePlusInactivePlusPurgeableBytes: UInt64
    let vmCounters: VMCountersReport
    let memoryProvider: MemoryReadingReport?
}

private struct VMCountersReport: Encodable {
    let freeCount: UInt64
    let speculativeCount: UInt64
    let activeCount: UInt64
    let inactiveCount: UInt64
    let purgeableCount: UInt64
    let wireCount: UInt64
    let compressorPageCount: UInt64
    let externalPageCount: UInt64
    let internalPageCount: UInt64
}

private struct MemoryReadingReport: Encodable {
    let usedBytes: UInt64
    let totalBytes: UInt64
    let pressurePercent: Double
    let wiredBytes: UInt64
    let activeBytes: UInt64
    let compressedBytes: UInt64
    let cachedBytes: UInt64
    let availableBytes: UInt64
}

private struct ReleaseResultReport: Encodable {
    let classification: String
    let observedReleasedBytes: UInt64
    let percentOfTotal: Double?
    let remainingCooldownSeconds: Double?
    let exitCode: Int32?
}

private struct CooldownAttemptReport: Encodable {
    let attempt: Int
    let result: ReleaseResultReport
}

@main
struct DebugMemoryRelease {
    static func main() async {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            let report = await buildReport(options: options)
            if options.json {
                printJSON(report)
            } else {
                printText(report)
            }
        } catch {
            fputs("\(error.localizedDescription)\n\n", stderr)
            printUsage(to: stderr)
            exit(2)
        }
    }

    private static func parseOptions(_ arguments: [String]) throws -> DebugMemoryReleaseOptions {
        var options = DebugMemoryReleaseOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                printUsage(to: stdout)
                exit(0)
            case "--sample-only":
                options.mode = .sampleOnly
            case "--release":
                options.mode = .release
            case "--cooldown-probe":
                options.mode = .cooldownProbe
            case "--strategy":
                let value = try value(after: argument, in: arguments, index: &index)
                guard let strategy = MemoryReleaseStrategy(rawValue: value) else {
                    throw DebugMemoryReleaseError.invalidValue(argument: argument, value: value)
                }
                options.strategy = strategy
            case "--settle-ms":
                options.settleMilliseconds = try intValue(after: argument, in: arguments, index: &index)
            case "--post-samples":
                let value = try value(after: argument, in: arguments, index: &index)
                options.postSampleMilliseconds = try parseMillisecondsList(value, argument: argument)
            case "--attempts":
                options.attempts = try intValue(after: argument, in: arguments, index: &index)
            case "--spacing-ms":
                options.spacingMilliseconds = try intValue(after: argument, in: arguments, index: &index)
            case "--json":
                options.json = true
            default:
                throw DebugMemoryReleaseError.unknownArgument(argument)
            }

            index += 1
        }

        guard options.settleMilliseconds >= 0,
              options.attempts > 0,
              options.spacingMilliseconds >= 0,
              options.postSampleMilliseconds.allSatisfy({ $0 >= 0 }) else {
            throw DebugMemoryReleaseError.invalidNumericArgument
        }

        return options
    }

    private static func buildReport(options: DebugMemoryReleaseOptions) async -> DebugMemoryReleaseReport {
        let before = await captureSnapshot()
        var releaseResult: MemoryReleaseResult?
        var cooldownAttempts: [CooldownAttemptReport] = []
        var warnings: [String] = []

        switch options.mode {
        case .sampleOnly:
            break
        case .release:
            releaseResult = await releaseMemory(options: options)
        case .cooldownProbe:
            let service = memoryReleaseService(options: options)
            for attempt in 1...options.attempts {
                let result = await service.release(strategy: options.strategy)
                cooldownAttempts.append(
                    CooldownAttemptReport(
                        attempt: attempt,
                        result: releaseResultReport(for: result)
                    )
                )
                if attempt < options.attempts, options.spacingMilliseconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(options.spacingMilliseconds) * 1_000_000)
                }
            }
            releaseResult = cooldownAttempts.first.map(memoryReleaseResult)
        }

        let samples = await collectPostSamples(milliseconds: postSampleMilliseconds(for: options))
        if options.mode == .sampleOnly, options.postSampleMilliseconds.isEmpty == false {
            warnings.append("postSamples were collected without running a release action")
        }

        let after = samples.last?.snapshot
        let releaseReport = releaseResult.map(releaseResultReport)

        return DebugMemoryReleaseReport(
            schemaVersion: 1,
            mode: options.mode,
            strategy: options.strategy.rawValue,
            settleMilliseconds: options.settleMilliseconds,
            postSampleMilliseconds: options.postSampleMilliseconds,
            currentReleasableBytes: before.serviceEstimateBytes,
            currentReclaimableBytes: before.directReclaimableBytes,
            before: snapshotReport(before),
            after: after,
            afterSamples: samples,
            observedReleasedBytes: releaseReport?.observedReleasedBytes ?? 0,
            classification: releaseReport?.classification ?? "sampled",
            releaseResult: releaseReport,
            cooldownAttempts: cooldownAttempts,
            warnings: warnings
        )
    }

    private static func releaseMemory(options: DebugMemoryReleaseOptions) async -> MemoryReleaseResult {
        await memoryReleaseService(options: options).release(strategy: options.strategy)
    }

    private static func memoryReleaseService(options: DebugMemoryReleaseOptions) -> MemoryReleaseService {
        MemoryReleaseService(
            measurementPolicy: MemoryReleaseMeasurementPolicy(
                settleDelayNanoseconds: UInt64(options.settleMilliseconds) * 1_000_000,
                significanceThresholdBytes: 1_024 * 1_024
            )
        )
    }

    private static func postSampleMilliseconds(for options: DebugMemoryReleaseOptions) -> [Int] {
        if options.postSampleMilliseconds.isEmpty, options.mode != .sampleOnly {
            return [0]
        }
        return options.postSampleMilliseconds.sorted()
    }

    private static func collectPostSamples(milliseconds: [Int]) async -> [TimedSnapshotReport] {
        var samples: [TimedSnapshotReport] = []
        var elapsedMilliseconds = 0

        for milliseconds in milliseconds {
            let waitMilliseconds = max(0, milliseconds - elapsedMilliseconds)
            if waitMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitMilliseconds) * 1_000_000)
            }
            elapsedMilliseconds = milliseconds
            samples.append(
                TimedSnapshotReport(
                    offsetMilliseconds: milliseconds,
                    snapshot: snapshotReport(await captureSnapshot())
                )
            )
        }

        return samples
    }

    private static func captureSnapshot() async -> VMStatsSnapshot {
        let vmStats = readVMStats()
        let memoryReading: MemoryReading?
        switch await MemoryProvider().sample() {
        case .memory(let reading):
            memoryReading = reading
        default:
            memoryReading = nil
        }

        return VMStatsSnapshot(
            pageSize: vmStats.pageSize,
            stats: vmStats.stats,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            memoryReading: memoryReading,
            directReclaimableBytes: SystemLocalMemoryReclaimer.currentReclaimableByteCount(),
            serviceEstimateBytes: await MemoryReleaseService().currentReleasableBytes()
        )
    }

    private static func readVMStats() -> (pageSize: vm_size_t, stats: vm_statistics64_data_t) {
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(mach_host_self(), &pageSize)
        guard pageResult == KERN_SUCCESS else {
            fatalError("host_page_size failed: \(pageResult)")
        }

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: stats) / MemoryLayout<integer_t>.size)
        let statsResult = withUnsafeMutablePointer(to: &stats) { statsPointer in
            statsPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard statsResult == KERN_SUCCESS else {
            fatalError("host_statistics64 failed: \(statsResult)")
        }

        return (pageSize, stats)
    }

    private static func snapshotReport(_ snapshot: VMStatsSnapshot) -> SnapshotReport {
        let inactivePlusPurgeable = bytes(
            pages: UInt64(snapshot.stats.inactive_count) + UInt64(snapshot.stats.purgeable_count),
            pageSize: snapshot.pageSize
        )
        let freePlusInactivePlusPurgeable = bytes(
            pages: UInt64(snapshot.stats.free_count)
                + UInt64(snapshot.stats.inactive_count)
                + UInt64(snapshot.stats.purgeable_count),
            pageSize: snapshot.pageSize
        )

        return SnapshotReport(
            pageSize: UInt64(snapshot.pageSize),
            physicalMemoryBytes: snapshot.physicalMemory,
            currentReleasableBytes: snapshot.serviceEstimateBytes,
            currentReclaimableBytes: snapshot.directReclaimableBytes,
            inactivePlusPurgeableBytes: inactivePlusPurgeable,
            freePlusInactivePlusPurgeableBytes: freePlusInactivePlusPurgeable,
            vmCounters: VMCountersReport(
                freeCount: UInt64(snapshot.stats.free_count),
                speculativeCount: UInt64(snapshot.stats.speculative_count),
                activeCount: UInt64(snapshot.stats.active_count),
                inactiveCount: UInt64(snapshot.stats.inactive_count),
                purgeableCount: UInt64(snapshot.stats.purgeable_count),
                wireCount: UInt64(snapshot.stats.wire_count),
                compressorPageCount: UInt64(snapshot.stats.compressor_page_count),
                externalPageCount: UInt64(snapshot.stats.external_page_count),
                internalPageCount: UInt64(snapshot.stats.internal_page_count)
            ),
            memoryProvider: snapshot.memoryReading.map(memoryReadingReport)
        )
    }

    private static func memoryReadingReport(_ reading: MemoryReading) -> MemoryReadingReport {
        MemoryReadingReport(
            usedBytes: reading.usedBytes,
            totalBytes: reading.totalBytes,
            pressurePercent: reading.pressurePercent,
            wiredBytes: reading.breakdown.wiredBytes,
            activeBytes: reading.breakdown.activeBytes,
            compressedBytes: reading.breakdown.compressedBytes,
            cachedBytes: reading.breakdown.cachedBytes,
            availableBytes: reading.breakdown.availableBytes
        )
    }

    private static func releaseResultReport(for result: MemoryReleaseResult) -> ReleaseResultReport {
        switch result {
        case .released(let bytes, let percentOfTotal):
            return ReleaseResultReport(
                classification: "released",
                observedReleasedBytes: bytes,
                percentOfTotal: percentOfTotal,
                remainingCooldownSeconds: nil,
                exitCode: nil
            )
        case .noSignificantRelease(let observedBytes):
            return ReleaseResultReport(
                classification: "noSignificantRelease",
                observedReleasedBytes: observedBytes,
                percentOfTotal: nil,
                remainingCooldownSeconds: nil,
                exitCode: nil
            )
        case .skippedCooldown(let remainingSeconds):
            return ReleaseResultReport(
                classification: "cooldown",
                observedReleasedBytes: 0,
                percentOfTotal: nil,
                remainingCooldownSeconds: remainingSeconds,
                exitCode: nil
            )
        case .unavailable:
            return ReleaseResultReport(
                classification: "unavailable",
                observedReleasedBytes: 0,
                percentOfTotal: nil,
                remainingCooldownSeconds: nil,
                exitCode: nil
            )
        case .failed(let exitCode):
            return ReleaseResultReport(
                classification: "failed",
                observedReleasedBytes: 0,
                percentOfTotal: nil,
                remainingCooldownSeconds: nil,
                exitCode: exitCode
            )
        case .failedToReadMemory:
            return ReleaseResultReport(
                classification: "failedToReadMemory",
                observedReleasedBytes: 0,
                percentOfTotal: nil,
                remainingCooldownSeconds: nil,
                exitCode: nil
            )
        }
    }

    private static func memoryReleaseResult(from attempt: CooldownAttemptReport) -> MemoryReleaseResult {
        switch attempt.result.classification {
        case "released":
            return .released(
                bytes: attempt.result.observedReleasedBytes,
                percentOfTotal: attempt.result.percentOfTotal ?? 0
            )
        case "noSignificantRelease":
            return .noSignificantRelease(observedBytes: attempt.result.observedReleasedBytes)
        case "cooldown":
            return .skippedCooldown(remainingSeconds: attempt.result.remainingCooldownSeconds ?? 0)
        case "failed":
            return .failed(exitCode: attempt.result.exitCode ?? -1)
        case "failedToReadMemory":
            return .failedToReadMemory
        default:
            return .unavailable
        }
    }

    private static func printJSON(_ report: DebugMemoryReleaseReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fatalError("Unable to encode debug report: \(error)")
        }
    }

    private static func printText(_ report: DebugMemoryReleaseReport) {
        print("MacActivity memory release debug")
        print("mode: \(report.mode.rawValue)")
        print("strategy: \(report.strategy)")
        print("settleMilliseconds: \(report.settleMilliseconds)")
        print("")
        printSnapshot(report.before, label: "before")

        if let releaseResult = report.releaseResult {
            print("")
            print("release classification: \(releaseResult.classification)")
            print("observed released: \(format(releaseResult.observedReleasedBytes)) (\(releaseResult.observedReleasedBytes) bytes)")
            if let percent = releaseResult.percentOfTotal {
                print("percent of total: \(String(format: "%.4f", percent))%")
            }
            if let remaining = releaseResult.remainingCooldownSeconds {
                print("cooldown remaining: \(String(format: "%.3f", remaining))s")
            }
            if let exitCode = releaseResult.exitCode {
                print("exit code: \(exitCode)")
            }
        } else {
            print("")
            print("Pass --release to run MemoryReleaseService.release() or --json for machine-readable output.")
        }

        for sample in report.afterSamples {
            print("")
            printSnapshot(sample.snapshot, label: "after +\(sample.offsetMilliseconds)ms")
        }

        if report.cooldownAttempts.isEmpty == false {
            print("")
            print("=== cooldown attempts ===")
            for attempt in report.cooldownAttempts {
                print("attempt \(attempt.attempt): \(attempt.result.classification)")
            }
        }

        for warning in report.warnings {
            print("warning: \(warning)")
        }
    }

    private static func printSnapshot(_ snapshot: SnapshotReport, label: String) {
        print("=== \(label) ===")
        print("pageSize: \(snapshot.pageSize)")
        print("physicalMemory: \(format(snapshot.physicalMemoryBytes)) (\(snapshot.physicalMemoryBytes) bytes)")
        print("currentReleasableBytes: \(formatOptional(snapshot.currentReleasableBytes))")
        print("currentReclaimableBytes: \(formatOptional(snapshot.currentReclaimableBytes))")
        print("inactive+purgeable: \(format(snapshot.inactivePlusPurgeableBytes)) (\(snapshot.inactivePlusPurgeableBytes) bytes)")
        print("free+inactive+purgeable: \(format(snapshot.freePlusInactivePlusPurgeableBytes)) (\(snapshot.freePlusInactivePlusPurgeableBytes) bytes)")

        printCounter("free_count", snapshot.vmCounters.freeCount, snapshot.pageSize)
        printCounter("inactive_count", snapshot.vmCounters.inactiveCount, snapshot.pageSize)
        printCounter("purgeable_count", snapshot.vmCounters.purgeableCount, snapshot.pageSize)
        printCounter("wire_count", snapshot.vmCounters.wireCount, snapshot.pageSize)
        printCounter("compressor_page_count", snapshot.vmCounters.compressorPageCount, snapshot.pageSize)
        printCounter("external_page_count", snapshot.vmCounters.externalPageCount, snapshot.pageSize)
        printCounter("internal_page_count", snapshot.vmCounters.internalPageCount, snapshot.pageSize)

        if let reading = snapshot.memoryProvider {
            print("MemoryProvider.usedBytes: \(format(reading.usedBytes)) (\(reading.usedBytes) bytes)")
            print("MemoryProvider.totalBytes: \(format(reading.totalBytes)) (\(reading.totalBytes) bytes)")
            print("MemoryProvider.pressurePercent: \(String(format: "%.2f", reading.pressurePercent))%")
            print("MemoryProvider.breakdown.cachedBytes: \(format(reading.cachedBytes)) (\(reading.cachedBytes) bytes)")
            print("MemoryProvider.breakdown.availableBytes: \(format(reading.availableBytes)) (\(reading.availableBytes) bytes)")
        } else {
            print("MemoryProvider reading: unavailable")
        }
    }

    private static func printCounter(_ name: String, _ pages: UInt64, _ pageSize: UInt64) {
        let byteCount = pages * pageSize
        print("\(name): \(pages) pages, \(format(byteCount)) (\(byteCount) bytes)")
    }

    private static func printUsage(to file: UnsafeMutablePointer<FILE>) {
        fputs("""
        Usage:
          scripts/debug-memory-release.command [--sample-only] [--post-samples 0,500,1000] [--json]
          scripts/debug-memory-release.command --release --strategy full|local|purge [--settle-ms 1000] [--post-samples 0,500,1000] [--json]
          scripts/debug-memory-release.command --cooldown-probe [--attempts 3] [--spacing-ms 1000] [--json]

        """, file)
    }

    private static func value(after argument: String, in arguments: [String], index: inout Int) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw DebugMemoryReleaseError.missingValue(argument: argument)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func intValue(after argument: String, in arguments: [String], index: inout Int) throws -> Int {
        let rawValue = try value(after: argument, in: arguments, index: &index)
        guard let value = Int(rawValue) else {
            throw DebugMemoryReleaseError.invalidValue(argument: argument, value: rawValue)
        }
        return value
    }

    private static func parseMillisecondsList(_ value: String, argument: String) throws -> [Int] {
        try value.split(separator: ",").map { part in
            guard let milliseconds = Int(part.trimmingCharacters(in: .whitespaces)) else {
                throw DebugMemoryReleaseError.invalidValue(argument: argument, value: String(part))
            }
            return milliseconds
        }
    }

    private static func bytes(pages: UInt64, pageSize: vm_size_t) -> UInt64 {
        pages * UInt64(pageSize)
    }

    private static func formatOptional(_ bytes: UInt64?) -> String {
        guard let bytes else { return "nil" }
        return "\(format(bytes)) (\(bytes) bytes)"
    }

    private static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
private enum DebugMemoryReleaseError: LocalizedError {
    case unknownArgument(String)
    case missingValue(argument: String)
    case invalidValue(argument: String, value: String)
    case invalidNumericArgument

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument)"
        case .missingValue(let argument):
            return "Missing value after \(argument)"
        case .invalidValue(let argument, let value):
            return "Invalid value for \(argument): \(value)"
        case .invalidNumericArgument:
            return "Numeric arguments must be positive where required"
        }
    }
}
