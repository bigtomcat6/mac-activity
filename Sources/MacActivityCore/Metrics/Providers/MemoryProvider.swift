import AppKit
import Darwin
import Darwin.Mach
import Foundation
import IOKit

public struct MemoryProvider: MetricProvider {
    public let kind: MetricKind = .memory
    public let cadence: MetricCadenceLane = .medium

    public init() {}

    public func sample() async -> MetricUpdate {
        guard let reading = readMemory() else {
            return .stale(kind: .memory, reason: "Unable to read memory usage")
        }

        return .memory(reading)
    }

    private func readMemory() -> MemoryReading? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return nil
        }

        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        let totalBytes = ProcessInfo.processInfo.physicalMemory

        return Self.makeReading(pageSize: pageSize, stats: info, totalBytes: totalBytes)
    }

    static func makeReading(
        pageSize: vm_size_t,
        stats: vm_statistics64_data_t,
        totalBytes: UInt64
    ) -> MemoryReading {
        // Keep reclaimable purgeable anonymous pages out of the "used" figure so
        // cached or discardable memory does not inflate the dashboard reading.
        let anonymousPages = UInt64(stats.internal_page_count)
        let reclaimableAnonymousPages = UInt64(min(stats.purgeable_count, stats.internal_page_count))
        let usedPages = UInt64(
            anonymousPages -
            reclaimableAnonymousPages +
            UInt64(stats.wire_count) +
            UInt64(stats.compressor_page_count)
        )
        let usedBytes = usedPages * UInt64(pageSize)

        return MemoryReading(
            usedBytes: min(usedBytes, totalBytes),
            totalBytes: totalBytes
        )
    }
}

public struct ActiveAppMemoryEntry: Identifiable, Equatable, Sendable {
    public let id: pid_t
    public let processIdentifier: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let residentMemoryBytes: UInt64
    public let isTerminable: Bool

    public init(
        processIdentifier: pid_t,
        name: String,
        bundleIdentifier: String?,
        residentMemoryBytes: UInt64,
        isTerminable: Bool
    ) {
        self.id = processIdentifier
        self.processIdentifier = processIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.residentMemoryBytes = residentMemoryBytes
        self.isTerminable = isTerminable
    }

    public var formattedResidentMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(min(residentMemoryBytes, UInt64(Int64.max))), countStyle: .memory)
    }
}

public enum ActiveAppTerminationResult: Equatable, Sendable {
    case requested
    case notFound
    case notTerminable
}

@MainActor
public final class ActiveAppMemoryService {
    private let workspace: NSWorkspace
    private let memoryReader: ProcessResidentMemoryReading

    public init(
        workspace: NSWorkspace = .shared,
        memoryReader: ProcessResidentMemoryReading = MachProcessResidentMemoryReader()
    ) {
        self.workspace = workspace
        self.memoryReader = memoryReader
    }

    public func topApps(limit: Int = 8) -> [ActiveAppMemoryEntry] {
        let entries = workspace.runningApplications.compactMap { app -> ActiveAppMemoryEntry? in
            guard app.activationPolicy == .regular else { return nil }
            let pid = app.processIdentifier
            guard let residentBytes = memoryReader.residentMemoryBytes(for: pid), residentBytes > 0 else { return nil }

            return ActiveAppMemoryEntry(
                processIdentifier: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "Process \(pid)",
                bundleIdentifier: app.bundleIdentifier,
                residentMemoryBytes: residentBytes,
                isTerminable: app.isTerminated == false
            )
        }

        return Self.sortedByMemory(entries, limit: limit)
    }

    public nonisolated static func sortedByMemory(_ entries: [ActiveAppMemoryEntry], limit: Int) -> [ActiveAppMemoryEntry] {
        entries
            .sorted { lhs, rhs in
                if lhs.residentMemoryBytes == rhs.residentMemoryBytes {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.residentMemoryBytes > rhs.residentMemoryBytes
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    @discardableResult
    public func requestTermination(processIdentifier: pid_t) -> ActiveAppTerminationResult {
        guard let app = workspace.runningApplications.first(where: { $0.processIdentifier == processIdentifier }) else {
            return .notFound
        }
        guard app.activationPolicy == .regular, app.isTerminated == false else {
            return .notTerminable
        }
        return app.terminate() ? .requested : .notTerminable
    }
}

public protocol ProcessResidentMemoryReading: Sendable {
    func residentMemoryBytes(for processIdentifier: pid_t) -> UInt64?
}

public struct MachProcessResidentMemoryReader: ProcessResidentMemoryReading {
    public init() {}

    public func residentMemoryBytes(for processIdentifier: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let byteCount = proc_pidinfo(
            processIdentifier,
            PROC_PIDTASKINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_taskinfo>.size)
        )
        guard byteCount == Int32(MemoryLayout<proc_taskinfo>.size) else {
            return nil
        }
        return UInt64(info.pti_resident_size)
    }
}

public struct GPUProvider: MetricProvider {
    public let kind: MetricKind = .gpu
    public let cadence: MetricCadenceLane = .fast
    private let cache: IOAcceleratorStatsCache

    public init() {
        self.init(cache: .shared)
    }

    init(cache: IOAcceleratorStatsCache) {
        self.cache = cache
    }

    public func sample() async -> MetricUpdate {
        guard let usagePercent = await cache.current().gpuUsagePercent else {
            return .unavailable(kind: .gpu, reason: "GPU usage is not exposed by IOAccelerator")
        }

        return .gpu(GPUReading(usagePercent: usagePercent))
    }
}

public struct VRAMProvider: MetricProvider {
    public let kind: MetricKind = .vram
    public let cadence: MetricCadenceLane = .medium
    private let cache: IOAcceleratorStatsCache

    public init() {
        self.init(cache: .shared)
    }

    init(cache: IOAcceleratorStatsCache) {
        self.cache = cache
    }

    public func sample() async -> MetricUpdate {
        guard let memory = await cache.current().memory,
              memory.totalBytes > 0 else {
            return .unavailable(kind: .vram, reason: "GPU memory usage is not exposed by IOAccelerator")
        }

        return .vram(VRAMReading(usedBytes: memory.usedBytes, totalBytes: memory.totalBytes))
    }
}

struct IOAcceleratorStats: Equatable, Sendable {
    var gpuUsagePercent: Double?
    var memory: VRAMReading?
}

actor IOAcceleratorStatsCache {
    static let shared = IOAcceleratorStatsCache()

    private let ttl: Duration
    private let readStats: @Sendable () async -> IOAcceleratorStats
    private let clock = ContinuousClock()
    private var cachedStats: (stats: IOAcceleratorStats, timestamp: ContinuousClock.Instant)?

    init(
        ttl: Duration = .seconds(1),
        readStats: @escaping @Sendable () async -> IOAcceleratorStats = {
            IOAcceleratorStatsReader.read()
        }
    ) {
        self.ttl = ttl
        self.readStats = readStats
    }

    func current() async -> IOAcceleratorStats {
        let now = clock.now
        if let cachedStats,
           cachedStats.timestamp.duration(to: now) < ttl {
            return cachedStats.stats
        }

        let stats = await readStats()
        cachedStats = (stats, now)
        return stats
    }
}

private enum IOAcceleratorStatsReader {
    static func read() -> IOAcceleratorStats {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            return IOAcceleratorStats()
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return IOAcceleratorStats()
        }
        defer {
            IOObjectRelease(iterator)
        }

        var usageCandidates: [Double] = []
        var usedBytes: UInt64 = 0
        var totalBytes: UInt64 = 0

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else {
                break
            }
            defer {
                IOObjectRelease(service)
            }

            guard let performanceStatistics = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            if let utilization = firstNumber(
                in: performanceStatistics,
                keys: [
                    "Device Utilization %",
                    "GPU Core Utilization %",
                    "Renderer Utilization %",
                    "Tiler Utilization %",
                ]
            ) {
                usageCandidates.append(utilization)
            }

            usedBytes += UInt64(firstNumber(in: performanceStatistics, keys: ["In use system memory"]) ?? 0)
            totalBytes += UInt64(firstNumber(in: performanceStatistics, keys: ["Alloc system memory"]) ?? 0)
        }

        let usage = usageCandidates.max().map { clamp($0, min: 0, max: 100) }
        let memory = totalBytes > 0 ? VRAMReading(usedBytes: min(usedBytes, totalBytes), totalBytes: totalBytes) : nil
        return IOAcceleratorStats(gpuUsagePercent: usage, memory: memory)
    }

    private static func firstNumber(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dictionary[key] as? NSNumber {
                return value.doubleValue
            }

            if let value = dictionary[key] as? Double {
                return value
            }

            if let value = dictionary[key] as? Int {
                return Double(value)
            }
        }

        return nil
    }

    private static func clamp(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}
