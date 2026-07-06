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

public struct GPUReading: Equatable, Sendable {
    public var usagePercent: Double

    public init(usagePercent: Double) {
        self.usagePercent = usagePercent
    }
}

public struct MemoryBreakdown: Equatable, Sendable {
    public var wiredBytes: UInt64
    public var activeBytes: UInt64
    public var compressedBytes: UInt64
    public var cachedBytes: UInt64
    public var availableBytes: UInt64

    public init(
        wiredBytes: UInt64 = 0,
        activeBytes: UInt64 = 0,
        compressedBytes: UInt64 = 0,
        cachedBytes: UInt64 = 0,
        availableBytes: UInt64 = 0
    ) {
        self.wiredBytes = wiredBytes
        self.activeBytes = activeBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.availableBytes = availableBytes
    }
}

public struct MemoryReading: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var breakdown: MemoryBreakdown

    public init(
        usedBytes: UInt64,
        totalBytes: UInt64,
        breakdown: MemoryBreakdown = MemoryBreakdown()
    ) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.breakdown = breakdown
    }

    public var pressurePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

public struct VRAMReading: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }
}

public struct DiskReading: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    public var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

public struct SwapReading: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    public var usagePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
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
    public var isConnectedToPower: Bool
    public var hardwarePercentage: Double?

    public init(
        percentage: Double,
        isCharging: Bool,
        isConnectedToPower: Bool? = nil,
        hardwarePercentage: Double? = nil
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isConnectedToPower = isConnectedToPower ?? isCharging
        self.hardwarePercentage = hardwarePercentage
    }

    public func displayPercentage(showsHardwarePercentage: Bool) -> Double {
        guard showsHardwarePercentage, let hardwarePercentage else {
            return percentage
        }

        return hardwarePercentage
    }
}

public struct TemperatureReading: Equatable, Sendable {
    public var celsius: Double
    public var source: TemperatureSource

    public init(celsius: Double, source: TemperatureSource = .smc) {
        self.celsius = celsius
        self.source = source
    }
}

public struct FanReading: Equatable, Sendable {
    public var rpm: Int
    public var fanRPMs: [Int]

    public init(rpm: Int, fanRPMs: [Int]? = nil) {
        self.rpm = rpm
        self.fanRPMs = fanRPMs ?? [rpm]
    }
}

public enum MetricUpdate: Equatable, Sendable {
    case cpu(CPUReading)
    case gpu(GPUReading)
    case memory(MemoryReading)
    case vram(VRAMReading)
    case disk(DiskReading)
    case swap(SwapReading)
    case network(NetworkReading)
    case battery(BatteryReading)
    case temperature(TemperatureReading)
    case temperatures([TemperatureReading])
    case fan(FanReading)
    case unavailable(kind: MetricKind, reason: String)
    case stale(kind: MetricKind, reason: String)

    public var kind: MetricKind {
        switch self {
        case .cpu:
            return .cpu
        case .gpu:
            return .gpu
        case .memory:
            return .memory
        case .vram:
            return .vram
        case .disk:
            return .disk
        case .swap:
            return .swap
        case .network:
            return .network
        case .battery:
            return .battery
        case .temperature, .temperatures:
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
    public var gpu: GPUReading?
    public var memory: MemoryReading?
    public var vram: VRAMReading?
    public var disk: DiskReading?
    public var swap: SwapReading?
    public var network: NetworkReading?
    public var battery: BatteryReading?
    public var temperature: TemperatureReading?
    public var temperatures: [TemperatureSource: TemperatureReading]
    public var fan: FanReading?
    public var issues: [MetricKind: MetricIssue]

    public init(
        timestamp: Date = .now,
        cpu: CPUReading? = nil,
        gpu: GPUReading? = nil,
        memory: MemoryReading? = nil,
        vram: VRAMReading? = nil,
        disk: DiskReading? = nil,
        swap: SwapReading? = nil,
        network: NetworkReading? = nil,
        battery: BatteryReading? = nil,
        temperature: TemperatureReading? = nil,
        temperatures: [TemperatureSource: TemperatureReading] = [:],
        fan: FanReading? = nil,
        issues: [MetricKind: MetricIssue] = [:]
    ) {
        self.timestamp = timestamp
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.vram = vram
        self.disk = disk
        self.swap = swap
        self.network = network
        self.battery = battery
        var mergedTemperatures = temperatures
        if let temperature {
            mergedTemperatures[temperature.source] = temperature
        }
        self.temperature = temperature ?? mergedTemperatures[.smc] ?? mergedTemperatures[.battery]
        self.temperatures = mergedTemperatures
        self.fan = fan
        self.issues = issues
    }

    public func temperature(for source: TemperatureSource) -> TemperatureReading? {
        temperatures[source] ?? (temperature?.source == source ? temperature : nil)
    }

    public func applying(_ updates: [MetricUpdate], timestamp: Date = .now) -> MetricsSnapshot {
        var next = self
        next.timestamp = timestamp
        for update in updates {
            switch update {
            case .cpu(let reading):
                next.cpu = reading
                next.issues[.cpu] = nil
            case .gpu(let reading):
                next.gpu = reading
                next.issues[.gpu] = nil
            case .memory(let reading):
                next.memory = reading
                next.issues[.memory] = nil
            case .vram(let reading):
                next.vram = reading
                next.issues[.vram] = nil
            case .disk(let reading):
                next.disk = reading
                next.issues[.disk] = nil
            case .swap(let reading):
                next.swap = reading
                next.issues[.swap] = nil
            case .network(let reading):
                next.network = reading
                next.issues[.network] = nil
            case .battery(let reading):
                next.battery = reading
                next.issues[.battery] = nil
            case .temperature(let reading):
                next.temperature = reading
                next.temperatures[reading.source] = reading
                next.issues[.temperature] = nil
            case .temperatures(let readings):
                let readingsBySource = Dictionary(
                    uniqueKeysWithValues: readings.map { ($0.source, $0) }
                )
                next.temperatures = readingsBySource
                next.temperature = readingsBySource[.smc] ?? readingsBySource[.battery]
                if !readings.isEmpty {
                    next.issues[.temperature] = nil
                }
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
        case .gpu:
            gpu = nil
        case .memory:
            memory = nil
        case .vram:
            vram = nil
        case .disk:
            disk = nil
        case .swap:
            swap = nil
        case .network:
            network = nil
        case .battery:
            battery = nil
        case .temperature:
            temperature = nil
            temperatures = [:]
        case .fan:
            fan = nil
        }
    }
}
