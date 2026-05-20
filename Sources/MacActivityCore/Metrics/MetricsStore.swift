import Combine
import Foundation

public struct MetricHistorySample: Equatable, Sendable {
    public var timestamp: Date
    public var cpuUsagePercent: Double?
    public var gpuUsagePercent: Double?
    public var memoryUsedPercent: Double?
    public var vramUsedPercent: Double?
    public var downloadBytesPerSecond: Double?
    public var uploadBytesPerSecond: Double?
    public var batteryPercent: Double?

    public init(snapshot: MetricsSnapshot) {
        self.timestamp = snapshot.timestamp
        self.cpuUsagePercent = snapshot.cpu?.usagePercent
        self.gpuUsagePercent = snapshot.gpu?.usagePercent
        if let memory = snapshot.memory, memory.totalBytes > 0 {
            self.memoryUsedPercent = Double(memory.usedBytes) / Double(memory.totalBytes) * 100
        } else {
            self.memoryUsedPercent = nil
        }
        if let vram = snapshot.vram, vram.totalBytes > 0 {
            self.vramUsedPercent = Double(vram.usedBytes) / Double(vram.totalBytes) * 100
        } else {
            self.vramUsedPercent = nil
        }
        self.downloadBytesPerSecond = snapshot.network?.downloadBytesPerSecond
        self.uploadBytesPerSecond = snapshot.network?.uploadBytesPerSecond
        self.batteryPercent = snapshot.battery?.percentage
    }
}

public struct MetricsHistory: Equatable, Sendable {
    public private(set) var samples: [MetricHistorySample]
    public let capacity: Int

    public init(samples: [MetricHistorySample] = [], capacity: Int = 60) {
        self.capacity = capacity
        self.samples = Array(samples.suffix(capacity))
    }

    public func appending(_ sample: MetricHistorySample) -> MetricsHistory {
        MetricsHistory(samples: samples + [sample], capacity: capacity)
    }
}

@MainActor
public final class MetricsStore: ObservableObject {
    @Published public private(set) var snapshot: MetricsSnapshot
    @Published public private(set) var history: MetricsHistory

    public init(snapshot: MetricsSnapshot = MetricsSnapshot(), history: MetricsHistory = MetricsHistory()) {
        self.snapshot = snapshot
        self.history = history
    }

    public func apply(_ updates: [MetricUpdate], timestamp: Date = .now) {
        snapshot = snapshot.applying(updates, timestamp: timestamp)
        history = history.appending(MetricHistorySample(snapshot: snapshot))
    }
}
