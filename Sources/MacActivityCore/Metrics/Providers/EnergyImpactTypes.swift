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
