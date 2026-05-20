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
        // Use anonymous, wired, and compressed pages so file-backed cached pages
        // are not reported as "used memory".
        let usedPages = UInt64(
            stats.internal_page_count +
            stats.wire_count +
            stats.compressor_page_count
        )
        let usedBytes = usedPages * UInt64(pageSize)

        return MemoryReading(
            usedBytes: min(usedBytes, totalBytes),
            totalBytes: totalBytes
        )
    }
}

public struct GPUProvider: MetricProvider {
    public let kind: MetricKind = .gpu
    public let cadence: MetricCadenceLane = .fast

    public init() {}

    public func sample() async -> MetricUpdate {
        guard let usagePercent = IOAcceleratorStatsReader.read().gpuUsagePercent else {
            return .unavailable(kind: .gpu, reason: "GPU usage is not exposed by IOAccelerator")
        }

        return .gpu(GPUReading(usagePercent: usagePercent))
    }
}

public struct VRAMProvider: MetricProvider {
    public let kind: MetricKind = .vram
    public let cadence: MetricCadenceLane = .medium

    public init() {}

    public func sample() async -> MetricUpdate {
        guard let memory = IOAcceleratorStatsReader.read().memory,
              memory.totalBytes > 0 else {
            return .unavailable(kind: .vram, reason: "GPU memory usage is not exposed by IOAccelerator")
        }

        return .vram(VRAMReading(usedBytes: memory.usedBytes, totalBytes: memory.totalBytes))
    }
}

private enum IOAcceleratorStatsReader {
    struct Stats {
        var gpuUsagePercent: Double?
        var memory: VRAMReading?
    }

    static func read() -> Stats {
        guard let matching = IOServiceMatching("IOAccelerator") else {
            return Stats()
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return Stats()
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
        return Stats(gpuUsagePercent: usage, memory: memory)
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
