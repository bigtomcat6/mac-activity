import AppKit
import Darwin
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
        let pageBytes = UInt64(pageSize)

        // Match Activity Monitor's visible "Memory Used" denominator: physical
        // memory minus free pages and file-backed cached pages. Purgeable pages
        // still count as used here; treating them as cached files undercounts
        // the value shown by Activity Monitor.
        // Apple Silicon GPU memory is collected separately by VRAMProvider,
        // and is not added to pressurePercent to avoid double-counting unified
        // memory.
        let anonymousPages = UInt64(stats.internal_page_count)
        let freeBytes = UInt64(stats.free_count) * pageBytes
        let wiredBytes = UInt64(stats.wire_count) * pageBytes
        let activeBytes = anonymousPages * pageBytes
        let compressedBytes = UInt64(stats.compressor_page_count) * pageBytes
        let cachedBytes = UInt64(stats.external_page_count) * pageBytes
        let availableBytes = min(freeBytes + cachedBytes, totalBytes)
        let usedBytes = totalBytes - availableBytes

        return MemoryReading(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            breakdown: MemoryBreakdown(
                wiredBytes: wiredBytes,
                activeBytes: activeBytes,
                compressedBytes: compressedBytes,
                cachedBytes: min(cachedBytes, totalBytes),
                availableBytes: availableBytes
            )
        )
    }
}

public struct ActiveAppMemoryEntry: Identifiable, Equatable, Sendable {
    public let id: pid_t
    public let processIdentifier: pid_t
    public let name: String
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    public let residentMemoryBytes: UInt64
    public let isTerminable: Bool

    public init(
        processIdentifier: pid_t,
        name: String,
        bundleIdentifier: String?,
        bundleURL: URL? = nil,
        residentMemoryBytes: UInt64,
        isTerminable: Bool
    ) {
        self.id = processIdentifier
        self.processIdentifier = processIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.residentMemoryBytes = residentMemoryBytes
        self.isTerminable = isTerminable
    }

    public var formattedResidentMemory: String {
        ByteCountFormatter.string(fromByteCount: Int64(min(residentMemoryBytes, UInt64(Int64.max))), countStyle: .memory)
    }

    public var hasStableTerminationIdentity: Bool {
        Self.hasStableTerminationIdentity(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL)
    }

    public static func hasStableTerminationIdentity(bundleIdentifier: String?, bundleURL: URL?) -> Bool {
        normalizedBundleIdentifier(bundleIdentifier) != nil || normalizedBundlePath(bundleURL) != nil
    }

    public func matchesTerminationTarget(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        bundleURL: URL?
    ) -> Bool {
        guard self.processIdentifier == processIdentifier else { return false }

        var matchedStableIdentity = false
        if let expectedBundleIdentifier = Self.normalizedBundleIdentifier(self.bundleIdentifier) {
            guard expectedBundleIdentifier == Self.normalizedBundleIdentifier(bundleIdentifier) else {
                return false
            }
            matchedStableIdentity = true
        }
        if let expectedBundlePath = Self.normalizedBundlePath(self.bundleURL) {
            guard expectedBundlePath == Self.normalizedBundlePath(bundleURL) else {
                return false
            }
            matchedStableIdentity = true
        }

        return matchedStableIdentity
    }

    private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, bundleIdentifier.isEmpty == false else { return nil }
        return bundleIdentifier
    }

    private static func normalizedBundlePath(_ bundleURL: URL?) -> String? {
        bundleURL?.standardizedFileURL.path
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
    private let processSnapshotReader: any ProcessMemorySnapshotReading

    public init(
        workspace: NSWorkspace = .shared,
        memoryReader: ProcessResidentMemoryReading = MachProcessResidentMemoryReader(),
        processSnapshotReader: any ProcessMemorySnapshotReading = SystemProcessMemorySnapshotReader()
    ) {
        self.workspace = workspace
        self.memoryReader = memoryReader
        self.processSnapshotReader = processSnapshotReader
    }

    public func topApps(limit: Int = 8) -> [ActiveAppMemoryEntry] {
        let regularApps = workspace.runningApplications.filter { $0.activationPolicy == .regular }
        let aggregates = ProcessTreeResidentMemoryAggregator.aggregate(
            rootProcessIdentifiers: regularApps.map(\.processIdentifier),
            snapshots: processSnapshotReader.snapshots()
        )

        let entries = regularApps.compactMap { app -> ActiveAppMemoryEntry? in
            let pid = app.processIdentifier
            let residentBytes = aggregates[pid]?.aggregateResidentBytes
                ?? memoryReader.residentMemoryBytes(for: pid)
            guard let residentBytes, residentBytes > 0 else { return nil }
            let bundleIdentifier = app.bundleIdentifier
            let bundleURL = app.bundleURL

            return ActiveAppMemoryEntry(
                processIdentifier: pid,
                name: app.localizedName ?? app.bundleIdentifier ?? "Process \(pid)",
                bundleIdentifier: bundleIdentifier,
                bundleURL: bundleURL,
                residentMemoryBytes: residentBytes,
                isTerminable: app.isTerminated == false
                    && ActiveAppMemoryEntry.hasStableTerminationIdentity(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL)
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
    public func requestTermination(_ target: ActiveAppMemoryEntry) -> ActiveAppTerminationResult {
        guard target.hasStableTerminationIdentity else {
            return .notTerminable
        }
        guard let app = workspace.runningApplications.first(
            where: { $0.processIdentifier == target.processIdentifier }
        ) else {
            return .notFound
        }
        guard app.activationPolicy == .regular, app.isTerminated == false else {
            return .notTerminable
        }
        guard target.matchesTerminationTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            bundleURL: app.bundleURL
        ) else {
            return .notFound
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

public struct ProcessMemorySnapshot: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let parentProcessIdentifier: pid_t
    public let residentMemoryBytes: UInt64

    public init(
        processIdentifier: pid_t,
        parentProcessIdentifier: pid_t,
        residentMemoryBytes: UInt64
    ) {
        self.processIdentifier = processIdentifier
        self.parentProcessIdentifier = parentProcessIdentifier
        self.residentMemoryBytes = residentMemoryBytes
    }
}

public struct ProcessTreeResidentMemoryAggregate: Equatable, Sendable {
    public let mainResidentBytes: UInt64
    public let childResidentBytes: UInt64
    public let aggregateResidentBytes: UInt64
    public let childCount: Int

    public init(
        mainResidentBytes: UInt64,
        childResidentBytes: UInt64,
        aggregateResidentBytes: UInt64,
        childCount: Int
    ) {
        self.mainResidentBytes = mainResidentBytes
        self.childResidentBytes = childResidentBytes
        self.aggregateResidentBytes = aggregateResidentBytes
        self.childCount = childCount
    }
}

public enum ProcessTreeResidentMemoryAggregator {
    public static func aggregate(
        rootProcessIdentifiers: [pid_t],
        snapshots: [ProcessMemorySnapshot]
    ) -> [pid_t: ProcessTreeResidentMemoryAggregate] {
        let snapshotsByPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.processIdentifier, $0) })
        let childrenByParent = Dictionary(grouping: snapshots, by: \.parentProcessIdentifier)

        return Dictionary(uniqueKeysWithValues: rootProcessIdentifiers.map { rootPID in
            let mainResidentBytes = snapshotsByPID[rootPID]?.residentMemoryBytes ?? 0
            var childResidentBytes: UInt64 = 0
            var childCount = 0
            var visited = Set<pid_t>([rootPID])
            var stack = childrenByParent[rootPID] ?? []

            while let child = stack.popLast() {
                guard visited.insert(child.processIdentifier).inserted else { continue }
                childResidentBytes += child.residentMemoryBytes
                childCount += 1
                stack.append(contentsOf: childrenByParent[child.processIdentifier] ?? [])
            }

            let aggregate = ProcessTreeResidentMemoryAggregate(
                mainResidentBytes: mainResidentBytes,
                childResidentBytes: childResidentBytes,
                aggregateResidentBytes: mainResidentBytes + childResidentBytes,
                childCount: childCount
            )
            return (rootPID, aggregate)
        })
    }
}

public protocol ProcessMemorySnapshotReading: Sendable {
    func snapshots() -> [ProcessMemorySnapshot]
}

public struct SystemProcessMemorySnapshotReader: ProcessMemorySnapshotReading {
    public init() {}

    public func snapshots() -> [ProcessMemorySnapshot] {
        let pidBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard pidBytes > 0 else { return [] }

        let pidCapacity = Int(pidBytes) / MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: pidCapacity)
        let filledBytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, pidBytes)
        }
        guard filledBytes > 0 else { return [] }

        let filledCount = min(Int(filledBytes) / MemoryLayout<pid_t>.stride, pids.count)
        return pids.prefix(filledCount).compactMap { pid -> ProcessMemorySnapshot? in
            guard pid > 0 else { return nil }

            var bsdInfo = proc_bsdinfo()
            let bsdByteCount = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &bsdInfo,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard bsdByteCount == Int32(MemoryLayout<proc_bsdinfo>.size) else {
                return nil
            }

            var taskInfo = proc_taskinfo()
            let taskByteCount = proc_pidinfo(
                pid,
                PROC_PIDTASKINFO,
                0,
                &taskInfo,
                Int32(MemoryLayout<proc_taskinfo>.size)
            )
            guard taskByteCount == Int32(MemoryLayout<proc_taskinfo>.size) else {
                return nil
            }

            return ProcessMemorySnapshot(
                processIdentifier: pid,
                parentProcessIdentifier: pid_t(bitPattern: bsdInfo.pbi_ppid),
                residentMemoryBytes: UInt64(taskInfo.pti_resident_size)
            )
        }
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
