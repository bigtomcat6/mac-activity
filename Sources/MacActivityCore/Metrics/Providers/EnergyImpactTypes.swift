import Darwin
import Foundation

public struct EnergyImpactAppIdentity: Hashable, Sendable {
    public let rootProcessIdentifier: pid_t
    public let rootProcessStartAbsoluteTime: UInt64?

    public init(
        rootProcessIdentifier: pid_t,
        rootProcessStartAbsoluteTime: UInt64?
    ) {
        self.rootProcessIdentifier = rootProcessIdentifier
        self.rootProcessStartAbsoluteTime = rootProcessStartAbsoluteTime
    }

    public var generation: EnergyImpactProcessIdentity? {
        guard let rootProcessStartAbsoluteTime else { return nil }
        return EnergyImpactProcessIdentity(
            processIdentifier: rootProcessIdentifier,
            processStartAbsoluteTime: rootProcessStartAbsoluteTime
        )
    }
}

public struct EnergyImpactProcessIdentity: Hashable, Sendable {
    public let processIdentifier: pid_t
    public let processStartAbsoluteTime: UInt64

    public init(processIdentifier: pid_t, processStartAbsoluteTime: UInt64) {
        self.processIdentifier = processIdentifier
        self.processStartAbsoluteTime = processStartAbsoluteTime
    }
}

public struct ProcessEnergyContribution: Equatable, Sendable {
    public let processIdentity: EnergyImpactProcessIdentity
    public let ownerRootProcessIdentifier: pid_t
    public let startTimeSeconds: TimeInterval
    public let endTimeSeconds: TimeInterval
    public let energyMicrojoules: Double

    public var durationSeconds: TimeInterval { endTimeSeconds - startTimeSeconds }

    public func clipped(to interval: Range<TimeInterval>) -> ProcessEnergyContribution? {
        let start = max(startTimeSeconds, interval.lowerBound)
        let end = min(endTimeSeconds, interval.upperBound)
        guard durationSeconds > 0, end > start else { return nil }
        let fraction = (end - start) / durationSeconds
        return ProcessEnergyContribution(
            processIdentity: processIdentity,
            ownerRootProcessIdentifier: ownerRootProcessIdentifier,
            startTimeSeconds: start,
            endTimeSeconds: end,
            energyMicrojoules: energyMicrojoules * fraction
        )
    }
}

public enum EnergyImpactAppKind: String, Equatable, Codable, Sendable {
    case regular
    case accessory
}

public enum EnergyImpactAppScope: String, Equatable, Codable, CaseIterable, Sendable {
    case regularOnly
    case regularAndAccessory
}

public enum EnergyImpactStatus: String, Equatable, Sendable {
    case collecting
    case stable
    case partial
    case stale
    case unavailable
}

public enum EnergyImpactTrend: String, Equatable, Sendable {
    case rising
    case steady
    case falling
}

struct EnergyImpactSessionRequest: Hashable, Sendable {
    let generation: UInt64

    init(generation: UInt64) {
        self.generation = generation
    }
}

public struct EnergyImpactSamplingLease: Hashable, Sendable {
    let requestGeneration: UInt64
    let token: UUID

    init(requestGeneration: UInt64, token: UUID = UUID()) {
        self.requestGeneration = requestGeneration
        self.token = token
    }
}

protocol EnergyImpactSampling: Sendable {
    func beginSession(
        _ request: EnergyImpactSessionRequest
    ) async -> EnergyImpactSamplingLease?

    func observe(
        lease: EnergyImpactSamplingLease,
        apps: [EnergyImpactAppSnapshot],
        limit: Int
    ) async -> [EnergyImpactEntry]?

    func endSession(_ lease: EnergyImpactSamplingLease) async
}

public struct EnergyImpactCoverage: Equatable, Sendable {
    public let discoveredProcessCount: Int
    public let readableProcessCount: Int
    public let validProcessSeconds: TimeInterval
    public let discoveredProcessSeconds: TimeInterval

    public init(
        discoveredProcessCount: Int,
        readableProcessCount: Int,
        validProcessSeconds: TimeInterval,
        discoveredProcessSeconds: TimeInterval
    ) {
        self.discoveredProcessCount = max(0, discoveredProcessCount)
        self.readableProcessCount = max(0, readableProcessCount)
        self.validProcessSeconds = max(0, validProcessSeconds)
        self.discoveredProcessSeconds = max(0, discoveredProcessSeconds)
    }

    public var fraction: Double {
        guard discoveredProcessSeconds > 0 else { return 0 }
        return min(max(validProcessSeconds / discoveredProcessSeconds, 0), 1)
    }

    public static let unavailable = EnergyImpactCoverage(
        discoveredProcessCount: 0,
        readableProcessCount: 0,
        validProcessSeconds: 0,
        discoveredProcessSeconds: 0
    )
}

public struct EnergyImpactEntry: Identifiable, Equatable, Sendable {
    public let id: EnergyImpactAppIdentity
    public let identity: EnergyImpactAppIdentity
    public let name: String
    public let bundleIdentifier: String?
    public let bundleURL: URL?
    public let kind: EnergyImpactAppKind
    public let currentPowerMicrowatts: Double?
    public let sustainedPowerMicrowatts: Double?
    public let rankingScore: Double?
    public let trend: EnergyImpactTrend
    public let coverage: EnergyImpactCoverage
    public let status: EnergyImpactStatus

    public init(
        identity: EnergyImpactAppIdentity,
        name: String,
        bundleIdentifier: String?,
        bundleURL: URL?,
        kind: EnergyImpactAppKind = .regular,
        currentPowerMicrowatts: Double?,
        sustainedPowerMicrowatts: Double?,
        rankingScore: Double?,
        trend: EnergyImpactTrend,
        coverage: EnergyImpactCoverage,
        status: EnergyImpactStatus
    ) {
        self.id = identity
        self.identity = identity
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.kind = kind
        self.currentPowerMicrowatts = currentPowerMicrowatts
        self.sustainedPowerMicrowatts = sustainedPowerMicrowatts
        self.rankingScore = rankingScore
        self.trend = trend
        self.coverage = coverage
        self.status = status
    }

    public var processIdentifier: pid_t {
        identity.rootProcessIdentifier
    }

    public var displayPowerMicrowatts: Double? {
        currentPowerMicrowatts
    }
}

public protocol EnergyImpactClock: Sendable {
    func nowSeconds() -> TimeInterval
}

public struct SystemEnergyImpactClock: EnergyImpactClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public init() {}

    public func nowSeconds() -> TimeInterval {
        let ticks = mach_continuous_time()
        let nanoseconds = Double(ticks)
            * Double(Self.timebase.numer)
            / Double(Self.timebase.denom)
        return nanoseconds / 1_000_000_000
    }
}

public struct EnergyImpactConfiguration: Equatable, Sendable {
    public let observationIntervalSeconds: TimeInterval
    public let maximumGapSeconds: TimeInterval
    public let fastHalfLifeSeconds: TimeInterval
    public let sustainedWindowSeconds: TimeInterval

    public init(
        observationIntervalSeconds: TimeInterval = 3,
        maximumGapSeconds: TimeInterval = 10,
        fastHalfLifeSeconds: TimeInterval = 4,
        sustainedWindowSeconds: TimeInterval = 30
    ) {
        self.observationIntervalSeconds = observationIntervalSeconds
        self.maximumGapSeconds = maximumGapSeconds
        self.fastHalfLifeSeconds = fastHalfLifeSeconds
        self.sustainedWindowSeconds = sustainedWindowSeconds
    }

    public static let production = EnergyImpactConfiguration()
}
