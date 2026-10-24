import Foundation
import XCTest
import MacActivityBatteryControl

// SYNTHETIC observations and responses only; no thresholds or mode transitions here.
actor BatteryCareTestBackend: BatteryCareBackend {
    var context = BatteryCareTestBackend.context()
    var calls: [BatteryCareEffect] = []
    var responses: [(BatteryCareEffect, BatteryCareExecution)] = []
    var applyGate: CheckedContinuation<BatteryCareExecution, Never>?
    var observeGate: CheckedContinuation<BatteryCareContext, Never>?
    var holdApply = false
    var holdObserve = false
    var observationsBeforeHold = 0
    var applied: XCTestExpectation?
    var observed: XCTestExpectation?

    func configure(context: BatteryCareContext) { self.context = context }
    func suspendApply(_ expectation: XCTestExpectation) { holdApply = true; applied = expectation }
    func suspendObserve(_ expectation: XCTestExpectation, after observations: Int = 0) {
        holdObserve = true; observationsBeforeHold = observations; observed = expectation
    }
    func respond(to effect: BatteryCareEffect, with execution: BatteryCareExecution) { responses.append((effect, execution)) }
    func recorded() -> [BatteryCareEffect] { calls }

    func observe() async -> BatteryCareContext {
        if holdObserve {
            if observationsBeforeHold > 0 { observationsBeforeHold -= 1; return context }
            holdObserve = false
            return await withCheckedContinuation { observeGate = $0; observed?.fulfill(); observed = nil }
        }
        return context
    }

    func apply(_ effect: BatteryCareEffect) async -> BatteryCareExecution {
        calls.append(effect)
        if holdApply {
            holdApply = false
            return await withCheckedContinuation { applyGate = $0; applied?.fulfill(); applied = nil }
        }
        return responses.last(where: { $0.0 == effect })?.1 ?? Self.execution(effect)
    }

    func resumeApply(_ execution: BatteryCareExecution) { applyGate?.resume(returning: execution); applyGate = nil }
    func resumeObserve(returning value: BatteryCareContext? = nil) {
        observeGate?.resume(returning: value ?? context); observeGate = nil
    }

    static func execution(_ effect: BatteryCareEffect, outcome: BatteryCareReply.Outcome = .accepted,
                          readback: BatteryCareReadback? = nil,
                          recovery: BatteryCareRecoveryStatus = .released) -> BatteryCareExecution {
        let phase: BatteryCareConfirmedPhase = effect == .allowCharging ? .allowed : .inhibited
        let isStop = effect == .endTemporaryMode || effect == .releaseOwnedControls
        return .init(effect: effect, generation: 0, outcome: outcome,
                     readback: readback ?? (isStop ? .unknown : .confirmed(phase)),
                     physicalObservation: .unknown, recoveryStatus: recovery)
    }

    static func context(time: UInt64 = 100, sequence: UInt64 = 10, percentage: Double = 90,
                        sampleAge: UInt64 = 50, lease: UInt64 = 100, externalPower: Bool = true) -> BatteryCareContext {
        let identity = BatteryCareIdentity(batteryID: "test-battery", modelIdentifier: "test-model", osBuild: "test-build")
        return .init(sample: .init(identity: identity, presence: .internalBattery, sequence: sequence,
                                  observedAtUptime: time, systemPercentage: percentage, externalPower: externalPower,
                                  isCharging: false, lowBatteryProtection: false), expectedIdentity: identity,
                     capabilities: Dictionary(uniqueKeysWithValues: BatteryCareOperation.allCases.map {
                         ($0, .verified(recordID: "SYNTHETIC-\($0)"))
                     }), authorization: .authorized, recoveryStatus: .released,
                     safetyLimits: try! .init(sampleIntervalNanoseconds: 10, maxSampleAgeNanoseconds: sampleAge,
                         maxCommandAgeNanoseconds: 20, maxReadbackNanoseconds: 20, maxStopNanoseconds: 20,
                         leaseNanoseconds: lease, maxTemporaryModeNanoseconds: 200, maxNoProgressNanoseconds: 100),
                     completion: .notComplete, nowUptime: time)
    }
}

final class BatteryCareTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 100
    func now() -> UInt64 { lock.withLock { value } }
    func set(_ value: UInt64) { lock.withLock { self.value = value } }
}
