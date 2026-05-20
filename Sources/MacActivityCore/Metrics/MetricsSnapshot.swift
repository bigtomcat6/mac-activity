import Foundation

public enum MetricIssue: Equatable, Sendable {
    case stale(String)
    case unsupported(String)
}

public struct CPUReading: Equatable, Sendable {
    public var usagePercent: Double

    public init(usagePercent: Double) {
        self.usagePercent = usagePercent
    }
}

public struct MemoryReading: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }
}

public struct NetworkReading: Equatable, Sendable {
    public var downloadBytesPerSecond: Double
    public var uploadBytesPerSecond: Double

    public init(downloadBytesPerSecond: Double, uploadBytesPerSecond: Double) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }
}

public struct BatteryReading: Equatable, Sendable {
    public var percentage: Double
    public var isCharging: Bool

    public init(percentage: Double, isCharging: Bool) {
        self.percentage = percentage
        self.isCharging = isCharging
    }
}

public struct TemperatureReading: Equatable, Sendable {
    public var celsius: Double

    public init(celsius: Double) {
        self.celsius = celsius
    }
}

public struct FanReading: Equatable, Sendable {
    public var rpm: Int

    public init(rpm: Int) {
        self.rpm = rpm
    }
}

public enum MetricUpdate: Equatable, Sendable {
    case cpu(CPUReading)
    case memory(MemoryReading)
    case network(NetworkReading)
    case battery(BatteryReading)
    case temperature(TemperatureReading)
    case fan(FanReading)
    case unavailable(kind: MetricKind, reason: String)
    case stale(kind: MetricKind, reason: String)

    public var kind: MetricKind {
        switch self {
        case .cpu:
            return .cpu
        case .memory:
            return .memory
        case .network:
            return .network
        case .battery:
            return .battery
        case .temperature:
            return .temperature
        case .fan:
            return .fan
        case .unavailable(let kind, _), .stale(let kind, _):
            return kind
        }
    }
}

public struct MetricsSnapshot: Equatable, Sendable {
    public var timestamp: Date
    public var cpu: CPUReading?
    public var memory: MemoryReading?
    public var network: NetworkReading?
    public var battery: BatteryReading?
    public var temperature: TemperatureReading?
    public var fan: FanReading?
    public var issues: [MetricKind: MetricIssue]

    public init(
        timestamp: Date = .now,
        cpu: CPUReading? = nil,
        memory: MemoryReading? = nil,
        network: NetworkReading? = nil,
        battery: BatteryReading? = nil,
        temperature: TemperatureReading? = nil,
        fan: FanReading? = nil,
        issues: [MetricKind: MetricIssue] = [:]
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.battery = battery
        self.temperature = temperature
        self.fan = fan
        self.issues = issues
    }

    public func applying(_ updates: [MetricUpdate], timestamp: Date = .now) -> MetricsSnapshot {
        var next = self
        next.timestamp = timestamp
        for update in updates {
            switch update {
            case .cpu(let reading):
                next.cpu = reading
                next.issues[.cpu] = nil
            case .memory(let reading):
                next.memory = reading
                next.issues[.memory] = nil
            case .network(let reading):
                next.network = reading
                next.issues[.network] = nil
            case .battery(let reading):
                next.battery = reading
                next.issues[.battery] = nil
            case .temperature(let reading):
                next.temperature = reading
                next.issues[.temperature] = nil
            case .fan(let reading):
                next.fan = reading
                next.issues[.fan] = nil
            case .unavailable(let kind, let reason):
                next.clearReading(for: kind)
                next.issues[kind] = .unsupported(reason)
            case .stale(let kind, let reason):
                next.issues[kind] = .stale(reason)
            }
        }
        return next
    }

    private mutating func clearReading(for kind: MetricKind) {
        switch kind {
        case .cpu:
            cpu = nil
        case .memory:
            memory = nil
        case .network:
            network = nil
        case .battery:
            battery = nil
        case .temperature:
            temperature = nil
        case .fan:
            fan = nil
        }
    }
}
