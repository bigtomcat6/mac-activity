import Darwin
import Foundation

public struct DiskProvider: MetricProvider {
    public let kind: MetricKind = .disk
    public let cadence: MetricCadenceLane = .slow

    private let volumeURL: URL

    public init(volumeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.volumeURL = volumeURL
    }

    public func sample() async -> MetricUpdate {
        guard let reading = readDisk() else {
            return .stale(kind: .disk, reason: "Unable to read disk usage")
        }

        return .disk(reading)
    }

    private func readDisk() -> DiskReading? {
        guard let values = try? volumeURL.resourceValues(
            forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ]
        ) else {
            return nil
        }

        let availableCapacity = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        guard let totalCapacity = values.volumeTotalCapacity,
              let availableCapacity else {
            return nil
        }

        return Self.makeReading(
            totalBytes: UInt64(max(0, totalCapacity)),
            availableBytes: UInt64(max(0, availableCapacity))
        )
    }

    public static func makeReading(totalBytes: UInt64, availableBytes: UInt64) -> DiskReading? {
        guard totalBytes > 0 else { return nil }
        let usedBytes = totalBytes - min(availableBytes, totalBytes)
        return DiskReading(usedBytes: usedBytes, totalBytes: totalBytes)
    }
}

public struct SwapProvider: MetricProvider {
    public let kind: MetricKind = .swap
    public let cadence: MetricCadenceLane = .slow

    public init() {}

    public func sample() async -> MetricUpdate {
        guard let reading = readSwap() else {
            return .stale(kind: .swap, reason: "Unable to read swap usage")
        }

        return .swap(reading)
    }

    private func readSwap() -> SwapReading? {
        var usage = xsw_usage()
        var length = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &length, nil, 0)
        guard result == 0 else {
            return nil
        }

        return Self.makeReading(usage: usage)
    }

    public static func makeReading(usage: xsw_usage) -> SwapReading? {
        let totalBytes = UInt64(usage.xsu_total)
        guard totalBytes > 0 else { return nil }
        let usedBytes = min(UInt64(usage.xsu_used), totalBytes)
        return SwapReading(usedBytes: usedBytes, totalBytes: totalBytes)
    }
}
