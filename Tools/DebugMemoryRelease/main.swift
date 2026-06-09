import Darwin
import Darwin.Mach
import Foundation
import MacActivityCore

struct VMStatsSnapshot {
    let pageSize: vm_size_t
    let stats: vm_statistics64_data_t
    let physicalMemory: UInt64
    let memoryReading: MemoryReading?
    let directReclaimableBytes: UInt64?
    let serviceEstimateBytes: UInt64?
}

@main
struct DebugMemoryRelease {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let shouldRelease = arguments.contains("--release")

        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return
        }

        print("MacActivity memory release debug")
        print("mode: \(shouldRelease ? "sample + release" : "sample only")")
        print("")

        let before = await captureSnapshot()
        printSnapshot(before, label: "before")

        guard shouldRelease else {
            print("")
            print("Pass --release to run MemoryReleaseService.release() and print after-state deltas.")
            return
        }

        print("")
        print("running MemoryReleaseService.release() ...")
        let result = await MemoryReleaseService().release()
        print("release result: \(describe(result))")

        let after = await captureSnapshot()
        print("")
        printSnapshot(after, label: "after")
        print("")
        printDeltas(before: before, after: after)
    }

    private static func printUsage() {
        print("""
        Usage: scripts/debug-memory-release.command [--release]

        Without --release, prints the current VM counters, MemoryProvider reading,
        SystemLocalMemoryReclaimer.currentReclaimableByteCount(), and
        MemoryReleaseService.currentReleasableBytes().

        With --release, also runs MemoryReleaseService.release() once and prints
        before/after deltas.
        """)
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

    private static func printSnapshot(_ snapshot: VMStatsSnapshot, label: String) {
        print("=== \(label) ===")
        print("pageSize: \(snapshot.pageSize)")
        print("physicalMemory: \(format(snapshot.physicalMemory)) (\(snapshot.physicalMemory) bytes)")

        printCounter("free_count", snapshot.stats.free_count, snapshot.pageSize)
        printCounter("speculative_count", snapshot.stats.speculative_count, snapshot.pageSize)
        printCounter("active_count", snapshot.stats.active_count, snapshot.pageSize)
        printCounter("inactive_count", snapshot.stats.inactive_count, snapshot.pageSize)
        printCounter("purgeable_count", snapshot.stats.purgeable_count, snapshot.pageSize)
        printCounter("wire_count", snapshot.stats.wire_count, snapshot.pageSize)
        printCounter("compressor_page_count", snapshot.stats.compressor_page_count, snapshot.pageSize)
        printCounter("external_page_count", snapshot.stats.external_page_count, snapshot.pageSize)
        printCounter("internal_page_count", snapshot.stats.internal_page_count, snapshot.pageSize)

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
        let cappedDirect = snapshot.directReclaimableBytes.map {
            min($0, SystemLocalMemoryReclaimer.defaultMaximumByteCount)
        }

        print("formula inactive+purgeable: \(format(inactivePlusPurgeable)) (\(inactivePlusPurgeable) bytes)")
        print("old formula free+inactive+purgeable: \(format(freePlusInactivePlusPurgeable)) (\(freePlusInactivePlusPurgeable) bytes)")
        print("SystemLocalMemoryReclaimer.currentReclaimableByteCount(): \(formatOptional(snapshot.directReclaimableBytes))")
        print("SystemLocalMemoryReclaimer.defaultMaximumByteCount: \(format(SystemLocalMemoryReclaimer.defaultMaximumByteCount)) (\(SystemLocalMemoryReclaimer.defaultMaximumByteCount) bytes)")
        print("capped direct reclaimable: \(formatOptional(cappedDirect))")
        print("MemoryReleaseService.currentReleasableBytes(): \(formatOptional(snapshot.serviceEstimateBytes))")

        if let reading = snapshot.memoryReading {
            print("MemoryProvider.usedBytes: \(format(reading.usedBytes)) (\(reading.usedBytes) bytes)")
            print("MemoryProvider.totalBytes: \(format(reading.totalBytes)) (\(reading.totalBytes) bytes)")
            print("MemoryProvider.pressurePercent: \(String(format: "%.2f", reading.pressurePercent))%")
            print("MemoryProvider.breakdown.cachedBytes: \(format(reading.breakdown.cachedBytes)) (\(reading.breakdown.cachedBytes) bytes)")
            print("MemoryProvider.breakdown.availableBytes: \(format(reading.breakdown.availableBytes)) (\(reading.breakdown.availableBytes) bytes)")
        } else {
            print("MemoryProvider reading: unavailable")
        }
    }

    private static func printDeltas(before: VMStatsSnapshot, after: VMStatsSnapshot) {
        print("=== deltas ===")
        printDelta("MemoryProvider.usedBytes", before.memoryReading?.usedBytes, after.memoryReading?.usedBytes)
        printDelta("direct reclaimable", before.directReclaimableBytes, after.directReclaimableBytes)
        printDelta("service estimate", before.serviceEstimateBytes, after.serviceEstimateBytes)
        printPageDelta("free_count", before.stats.free_count, after.stats.free_count, before.pageSize)
        printPageDelta("inactive_count", before.stats.inactive_count, after.stats.inactive_count, before.pageSize)
        printPageDelta("purgeable_count", before.stats.purgeable_count, after.stats.purgeable_count, before.pageSize)
        printPageDelta("external_page_count", before.stats.external_page_count, after.stats.external_page_count, before.pageSize)
    }

    private static func describe(_ result: MemoryReleaseResult) -> String {
        switch result {
        case .released(let bytes, let percentOfTotal):
            return ".released(bytes: \(bytes), formatted: \(format(bytes)), percentOfTotal: \(String(format: "%.4f", percentOfTotal))%)"
        case .unavailable:
            return ".unavailable"
        case .failed(let exitCode):
            return ".failed(exitCode: \(exitCode))"
        case .failedToReadMemory:
            return ".failedToReadMemory"
        }
    }

    private static func printCounter(_ name: String, _ pages: UInt32, _ pageSize: vm_size_t) {
        let byteCount = bytes(pages: UInt64(pages), pageSize: pageSize)
        print("\(name): \(pages) pages, \(format(byteCount)) (\(byteCount) bytes)")
    }

    private static func printDelta(_ name: String, _ before: UInt64?, _ after: UInt64?) {
        guard let before, let after else {
            print("\(name) delta: unavailable")
            return
        }
        let delta = Int64(clamping: after) - Int64(clamping: before)
        print("\(name) delta: \(signedFormat(delta)) (\(delta) bytes)")
    }

    private static func printPageDelta(_ name: String, _ before: UInt32, _ after: UInt32, _ pageSize: vm_size_t) {
        let deltaPages = Int64(after) - Int64(before)
        let deltaBytes = deltaPages * Int64(pageSize)
        print("\(name) delta: \(deltaPages) pages, \(signedFormat(deltaBytes)) (\(deltaBytes) bytes)")
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

    private static func signedFormat(_ bytes: Int64) -> String {
        if bytes < 0 {
            return "-\(format(UInt64(-bytes)))"
        }
        return "+\(format(UInt64(bytes)))"
    }

}
