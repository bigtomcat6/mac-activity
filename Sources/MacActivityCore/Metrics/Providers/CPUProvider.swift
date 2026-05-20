import Darwin.Mach
import Foundation

public actor CPUProvider: MetricProvider {
    public let kind: MetricKind = .cpu
    public let cadence: MetricCadenceLane = .fast
    private var previousSample: TickSample?

    private struct TickSample {
        let total: UInt64
        let idle: UInt64
    }

    public init() {}

    public func sample() async -> MetricUpdate {
        guard let currentSample = readTicks() else {
            return .stale(kind: .cpu, reason: "Unable to read CPU load")
        }

        defer {
            previousSample = currentSample
        }

        guard let previousSample else {
            return .cpu(CPUReading(usagePercent: 0))
        }

        let totalDelta = currentSample.total &- previousSample.total
        guard totalDelta > 0 else {
            return .cpu(CPUReading(usagePercent: 0))
        }

        let idleDelta = currentSample.idle &- previousSample.idle
        let busyDelta = totalDelta > idleDelta ? totalDelta - idleDelta : 0
        let percent = Double(busyDelta) / Double(totalDelta) * 100

        return .cpu(CPUReading(usagePercent: max(0, min(percent, 100))))
    }

    private func readTicks() -> TickSample? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        return TickSample(
            total: user + system + idle + nice,
            idle: idle
        )
    }
}
