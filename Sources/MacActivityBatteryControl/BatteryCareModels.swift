import Foundation

public struct BatteryCareSettings: Equatable, Codable, Sendable {
    public let isEnabled: Bool
    public let limit: Int

    public init(isEnabled: Bool = false, limit: Int = 80) throws {
        try Self.validate(limit)
        self.isEnabled = isEnabled
        self.limit = limit
    }

    public static let `default` = try! BatteryCareSettings()

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidLimit(Int)
    }

    private static func validate(_ limit: Int) throws {
        guard (50...100).contains(limit) else { throw ValidationError.invalidLimit(limit) }
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, limit }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            isEnabled: container.decode(Bool.self, forKey: .isEnabled),
            limit: container.decode(Int.self, forKey: .limit)
        )
    }

    public func encode(to encoder: Encoder) throws {
        try Self.validate(limit)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(limit, forKey: .limit)
    }
}

public struct BatteryCareIdentity: Equatable, Sendable {
    public let batteryID: String
    public let modelIdentifier: String
    public let osBuild: String

    public init(batteryID: String, modelIdentifier: String, osBuild: String) {
        self.batteryID = batteryID
        self.modelIdentifier = modelIdentifier
        self.osBuild = osBuild
    }
}

public enum BatteryCarePresence: Equatable, Sendable {
    case internalBattery, absent, unknown
}

public struct BatteryCareSample: Equatable, Sendable {
    public let identity: BatteryCareIdentity?
    public let presence: BatteryCarePresence
    public let sequence: UInt64
    /// Monotonic nanoseconds in the collector's boot epoch; not a UI refresh time.
    public let observedAtUptime: UInt64
    public let systemPercentage: Double?
    public let externalPower: Bool?
    public let isCharging: Bool?
    public let lowBatteryProtection: Bool?

    public init(
        identity: BatteryCareIdentity?, presence: BatteryCarePresence,
        sequence: UInt64, observedAtUptime: UInt64, systemPercentage: Double?,
        externalPower: Bool?, isCharging: Bool?, lowBatteryProtection: Bool?
    ) {
        self.identity = identity
        self.presence = presence
        self.sequence = sequence
        self.observedAtUptime = observedAtUptime
        self.systemPercentage = systemPercentage
        self.externalPower = externalPower
        self.isCharging = isCharging
        self.lowBatteryProtection = lowBatteryProtection
    }
}

public enum BatteryCareOperation: CaseIterable, Hashable, Sendable {
    case regularLimit, manualDischarge, temporaryFullCharge, releaseOwnedControls
}

public enum BatteryCareCapability: Equatable, Sendable {
    case unverified
    case unsupported(reason: String)
    case verified(recordID: String)
}

public struct BatteryCareSafetyLimits: Equatable, Sendable {
    public let sampleIntervalNanoseconds: UInt64
    public let maxSampleAgeNanoseconds: UInt64
    public let maxCommandAgeNanoseconds: UInt64
    public let maxReadbackNanoseconds: UInt64
    public let maxStopNanoseconds: UInt64
    public let leaseNanoseconds: UInt64
    public let maxTemporaryModeNanoseconds: UInt64
    public let maxNoProgressNanoseconds: UInt64

    public enum ValidationError: Error, Equatable, Sendable { case zeroDuration }

    /// Positivity is structural only. Device-specific timing relationships require G3 evidence.
    public init(
        sampleIntervalNanoseconds: UInt64, maxSampleAgeNanoseconds: UInt64,
        maxCommandAgeNanoseconds: UInt64, maxReadbackNanoseconds: UInt64,
        maxStopNanoseconds: UInt64, leaseNanoseconds: UInt64,
        maxTemporaryModeNanoseconds: UInt64, maxNoProgressNanoseconds: UInt64
    ) throws {
        guard [sampleIntervalNanoseconds, maxSampleAgeNanoseconds, maxCommandAgeNanoseconds,
               maxReadbackNanoseconds, maxStopNanoseconds, leaseNanoseconds,
               maxTemporaryModeNanoseconds, maxNoProgressNanoseconds].allSatisfy({ $0 > 0 }) else {
            throw ValidationError.zeroDuration
        }
        self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
        self.maxSampleAgeNanoseconds = maxSampleAgeNanoseconds
        self.maxCommandAgeNanoseconds = maxCommandAgeNanoseconds
        self.maxReadbackNanoseconds = maxReadbackNanoseconds
        self.maxStopNanoseconds = maxStopNanoseconds
        self.leaseNanoseconds = leaseNanoseconds
        self.maxTemporaryModeNanoseconds = maxTemporaryModeNanoseconds
        self.maxNoProgressNanoseconds = maxNoProgressNanoseconds
    }
}

public enum BatteryCareCompletion: Equatable, Sendable {
    case unknown, notComplete
    case confirmed(recordID: String, sampleSequence: UInt64)
}

public enum BatteryCareConfirmedPhase: Equatable, Sendable {
    case unknown, allowed, inhibited
}

public enum BatteryCareTemporaryMode: Equatable, Sendable {
    case none, discharging, chargingToFull
}

public enum BatteryCareAuthorization: Equatable, Sendable {
    case notAuthorized, authorized
}

public enum BatteryCareRecoveryStatus: Equatable, Sendable {
    case unknown, unconfirmed, conflict, released
}

public enum BatteryCareRequestStatus: Equatable, Sendable {
    case idle
    case pending(requestID: UUID)
    case accepted(requestID: UUID)
    case rejected(requestID: UUID, reason: String)
    case outcomeUnknown(requestID: UUID)
}

public enum BatteryCareReadback: Equatable, Sendable {
    case unknown
    case confirmed(BatteryCareConfirmedPhase)
    case contradicted
}

public enum BatteryCarePhysicalObservation: Equatable, Sendable {
    case unknown
    case observed(sampleSequence: UInt64)
}

public enum BatteryCareLifecycleEvent: Equatable, Sendable {
    case unplugged, willSleep, didWake, pluggedIn, quit, connectionLost
}

public enum BatteryCareReleaseReason: Equatable, Sendable {
    case userRequested, shutdown
}

/// Client intent only; observations and completion evidence never enter through this enum.
public enum BatteryCareIntent: Equatable, Sendable {
    case setManagement(Bool), setLimit(Int)
    case startDischarge, stopDischarge, startFullCharge, cancelFullCharge, retryRegular
    case releaseOwnedControls(reason: BatteryCareReleaseReason)
}

public enum BatteryCareEvent: Equatable, Sendable {
    case intent(BatteryCareIntent)
    case settingsAccepted(BatteryCareSettings)
    case sampleChanged, executionObserved, tick, retryRequested
    case lifecycle(BatteryCareLifecycleEvent)
}

/// Backend observation, not client-supplied completion or proof of physical charging.
public struct BatteryCareExecution: Equatable, Sendable {
    public let effect: BatteryCareEffect
    public let generation: UInt64
    public let outcome: BatteryCareReply.Outcome
    public let readback: BatteryCareReadback
    public let physicalObservation: BatteryCarePhysicalObservation
    public let recoveryStatus: BatteryCareRecoveryStatus

    public init(effect: BatteryCareEffect, generation: UInt64,
                outcome: BatteryCareReply.Outcome, readback: BatteryCareReadback,
                physicalObservation: BatteryCarePhysicalObservation = .unknown,
                recoveryStatus: BatteryCareRecoveryStatus = .unknown) {
        self.effect = effect
        self.generation = generation
        self.outcome = outcome
        self.readback = readback
        self.physicalObservation = physicalObservation
        self.recoveryStatus = recoveryStatus
    }
}

/// Trusted collector/backend inputs. Synthetic verified records do not authenticate a device.
public struct BatteryCareContext: Equatable, Sendable {
    public var sample: BatteryCareSample?
    public var expectedIdentity: BatteryCareIdentity?
    public var capabilities: [BatteryCareOperation: BatteryCareCapability]
    public var authorization: BatteryCareAuthorization
    public var recoveryStatus: BatteryCareRecoveryStatus
    public var safetyLimits: BatteryCareSafetyLimits?
    public var completion: BatteryCareCompletion
    public var execution: BatteryCareExecution?
    public var nowUptime: UInt64

    public init(
        sample: BatteryCareSample? = nil, expectedIdentity: BatteryCareIdentity? = nil,
        capabilities: [BatteryCareOperation: BatteryCareCapability] = [:],
        authorization: BatteryCareAuthorization = .notAuthorized,
        recoveryStatus: BatteryCareRecoveryStatus = .unknown, safetyLimits: BatteryCareSafetyLimits? = nil,
        completion: BatteryCareCompletion = .unknown, execution: BatteryCareExecution? = nil,
        nowUptime: UInt64
    ) {
        self.sample = sample
        self.expectedIdentity = expectedIdentity
        self.capabilities = capabilities
        self.authorization = authorization
        self.recoveryStatus = recoveryStatus
        self.safetyLimits = safetyLimits
        self.completion = completion
        self.execution = execution
        self.nowUptime = nowUptime
    }
}

public struct BatteryCareState: Equatable, Sendable {
    public var settings: BatteryCareSettings
    public var confirmedPhase: BatteryCareConfirmedPhase
    public var temporaryMode: BatteryCareTemporaryMode
    public var generation: UInt64
    public var pendingRequest: UUID?
    public var pauseReason: String?
    public var recoveryStatus: BatteryCareRecoveryStatus

    // Pure reducer bookkeeping; request IDs/serialization and execution ownership belong to A4/B.
    public var pendingEffect: BatteryCareEffect?
    public var pendingSinceUptime: UInt64?
    public var lastSample: BatteryCareSample?
    public var sampleNotBeforeUptime: UInt64?
    public var requiresRetry = false
    public var isSuspended = false
    /// A confirmed-full fact survives a failed regular restoration; it is not a restoration result.
    public var completion: BatteryCareCompletion = .unknown
    public var temporaryStartedAtUptime: UInt64?
    public var temporaryStartSequence: UInt64?
    public var temporaryRecordID: String?
    public var temporaryProgressPercentage: Double?
    public var temporaryProgressAtUptime: UInt64?
    /// Same accepted limit at normal exit uses the inhibited-side hysteresis, after exit confirmation.
    public var temporaryExitLimit: Int?

    public init(
        settings: BatteryCareSettings = .default,
        confirmedPhase: BatteryCareConfirmedPhase = .unknown,
        temporaryMode: BatteryCareTemporaryMode = .none, generation: UInt64 = 0,
        pendingRequest: UUID? = nil, pauseReason: String? = nil,
        recoveryStatus: BatteryCareRecoveryStatus = .unknown
    ) {
        self.settings = settings
        self.confirmedPhase = confirmedPhase
        self.temporaryMode = temporaryMode
        self.generation = generation
        self.pendingRequest = pendingRequest
        self.pauseReason = pauseReason
        self.recoveryStatus = recoveryStatus
    }
}

/// Policy output vocabulary, not an arbitrary hardware or wire API.
public enum BatteryCareEffect: Equatable, Sendable {
    case allowCharging, inhibitCharging, startDischarge, endTemporaryMode, releaseOwnedControls
}

public struct BatteryCareTransition: Equatable, Sendable {
    public let state: BatteryCareState
    public let effects: [BatteryCareEffect]

    public init(state: BatteryCareState, effects: [BatteryCareEffect]) {
        self.state = state
        self.effects = effects
    }
}

public struct BatteryCareSnapshot: Equatable, Sendable {
    public let settings: BatteryCareSettings
    public let sample: BatteryCareSample?
    public let capabilities: [BatteryCareOperation: BatteryCareCapability]
    public let authorization: BatteryCareAuthorization
    public let requestStatus: BatteryCareRequestStatus
    public let readback: BatteryCareReadback
    public let physicalObservation: BatteryCarePhysicalObservation
    public let recoveryStatus: BatteryCareRecoveryStatus
    public let safetyLimits: BatteryCareSafetyLimits?
    public let generation: UInt64
    public let revision: UInt64
    public let confirmedPhase: BatteryCareConfirmedPhase
    public let temporaryMode: BatteryCareTemporaryMode
    public let completion: BatteryCareCompletion
    public let pauseReason: String?
    public let requiresRetry: Bool
    public let isSuspended: Bool

    public init(
        settings: BatteryCareSettings = .default, sample: BatteryCareSample? = nil,
        capabilities: [BatteryCareOperation: BatteryCareCapability] = [:],
        authorization: BatteryCareAuthorization = .notAuthorized,
        requestStatus: BatteryCareRequestStatus = .idle, readback: BatteryCareReadback = .unknown,
        physicalObservation: BatteryCarePhysicalObservation = .unknown,
        recoveryStatus: BatteryCareRecoveryStatus = .unknown, safetyLimits: BatteryCareSafetyLimits? = nil,
        generation: UInt64 = 0, revision: UInt64 = 0,
        confirmedPhase: BatteryCareConfirmedPhase = .unknown,
        temporaryMode: BatteryCareTemporaryMode = .none, completion: BatteryCareCompletion = .unknown,
        pauseReason: String? = nil, requiresRetry: Bool = false, isSuspended: Bool = false
    ) {
        self.settings = settings
        self.sample = sample
        self.capabilities = Dictionary(uniqueKeysWithValues: BatteryCareOperation.allCases.map {
            ($0, capabilities[$0] ?? .unverified)
        })
        self.authorization = authorization
        self.requestStatus = requestStatus
        self.readback = readback
        self.physicalObservation = physicalObservation
        self.recoveryStatus = recoveryStatus
        self.safetyLimits = safetyLimits
        self.generation = generation
        self.revision = revision
        self.confirmedPhase = confirmedPhase
        self.temporaryMode = temporaryMode
        self.completion = completion
        self.pauseReason = pauseReason
        self.requiresRetry = requiresRetry
        self.isSuspended = isSuspended
    }
}

public struct BatteryCareReply: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case accepted
        case rejected(reason: String)
        case outcomeUnknown
    }

    public let requestID: UUID
    public let generation: UInt64
    public let revision: UInt64
    public let outcome: Outcome

    public init(requestID: UUID, generation: UInt64, revision: UInt64, outcome: Outcome) {
        self.requestID = requestID
        self.generation = generation
        self.revision = revision
        self.outcome = outcome
    }
}
