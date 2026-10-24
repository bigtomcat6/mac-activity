import Foundation

public enum BatteryCarePolicy {
    public static func reduce(
        state: BatteryCareState, event: BatteryCareEvent, context: BatteryCareContext
    ) -> BatteryCareTransition {
        var next = state
        var event = event
        var rebuildPhase = false
        var shouldEndTemporary = false
        // Intent carries no observations; settings still enter through the existing accepted-settings path.
        switch event {
        case .intent(.setManagement(let enabled)):
            event = .settingsAccepted(try! .init(isEnabled: enabled, limit: next.settings.limit))
        case .intent(.setLimit(let limit)):
            guard let settings = try? BatteryCareSettings(isEnabled: next.settings.isEnabled, limit: limit) else {
                if next.temporaryMode != .none {
                    return fault(&next, reason: "invalidLimit", context: context)
                }
                next.pauseReason = "invalidLimit"
                return BatteryCareTransition(state: next, effects: [])
            }
            event = .settingsAccepted(settings)
        case .intent(.retryRegular): event = .retryRequested
        default: break
        }
        // A pending release is acknowledged only by its execution + recovery observation.
        if next.pendingEffect != .releaseOwnedControls && next.pendingEffect != .endTemporaryMode
            && next.recoveryStatus != .unconfirmed && next.recoveryStatus != .conflict {
            next.recoveryStatus = context.recoveryStatus
        }

        switch event {
        case .intent(let intent):
            switch intent {
            case .stopDischarge where next.temporaryMode == .discharging,
                 .cancelFullCharge where next.temporaryMode == .chargingToFull:
                shouldEndTemporary = true
            case .releaseOwnedControls:
                next.isSuspended = true
                next.sampleNotBeforeUptime = context.nowUptime
                return release(&next, context: context)
            default: break
            }
        case .settingsAccepted(let settings):
            if settings != next.settings {
                let differentLimit = settings.limit != next.settings.limit
                next.settings = settings
                if differentLimit { next.temporaryExitLimit = nil }
                if !settings.isEnabled { return release(&next, context: context) }
                if next.pendingEffect == .endTemporaryMode || next.pendingEffect == .releaseOwnedControls {
                    break // Keep the stop's generation/deadline; a new L cannot cancel it.
                }
                if next.temporaryMode == .chargingToFull && differentLimit {
                    shouldEndTemporary = true
                    break
                }
                if next.temporaryMode == .discharging { break }
                if next.pendingEffect != nil {
                    return release(&next, context: context)
                }
                if !settings.isEnabled || settings.limit == 100 {
                    return release(&next, context: context)
                }
                rebuildPhase = true
            }
        case .lifecycle(let lifecycle):
            if lifecycle == .unplugged,
               admittedPercentage(state: next, context: context, requiresExternalPower: false) != nil {
                next.lastSample = context.sample
            }
            next.sampleNotBeforeUptime = context.nowUptime
            switch lifecycle {
            case .didWake, .pluggedIn:
                next.isSuspended = false
            case .unplugged, .willSleep, .quit, .connectionLost:
                next.isSuspended = true
            }
            if lifecycle == .connectionLost { next.requiresRetry = true }
            return release(&next, context: context)
        case .retryRequested:
            if next.temporaryMode == .none && next.pendingEffect == nil && next.pendingRequest == nil
                && (next.requiresRetry || next.isSuspended)
                && admittedPercentage(state: next, context: context) != nil {
                next.requiresRetry = false
                next.pauseReason = nil
                next.temporaryExitLimit = nil
                next.isSuspended = false
                rebuildPhase = true
            }
        case .sampleChanged, .executionObserved, .tick:
            break
        }

        if let effect = next.pendingEffect {
            let budget = effect == .releaseOwnedControls || effect == .endTemporaryMode
                ? context.safetyLimits?.maxStopNanoseconds
                : context.safetyLimits.map { min($0.maxCommandAgeNanoseconds, $0.maxReadbackNanoseconds) }
            let inTime: Bool
            if let since = next.pendingSinceUptime, let budget, context.nowUptime >= since {
                inTime = context.nowUptime - since < budget
            } else {
                inTime = false
            }
            if !inTime {
                // Late release evidence can settle recovery, but must not clear the fault latch.
                guard effect == .releaseOwnedControls, event == .executionObserved else {
                    return fault(&next, reason: "executionDeadline", context: context)
                }
                next.requiresRetry = true
                next.pauseReason = "executionDeadline"
            }
        }
        if next.pendingEffect == .endTemporaryMode,
           observedPercentage(state: next, context: context) == nil {
            return fault(&next, reason: "temporaryExitEvidenceUnavailable", context: context)
        }
        if next.temporaryMode != .none, event == .executionObserved,
           let execution = context.execution, execution.generation == next.generation,
           execution.effect == next.pendingEffect {
            let expected: BatteryCareConfirmedPhase = next.temporaryMode == .discharging ? .inhibited : .allowed
            guard execution.outcome == .accepted, execution.readback == .confirmed(expected) else {
                return fault(&next, reason: "temporaryReadbackUnconfirmed", context: context)
            }
        }
        if next.temporaryMode != .none {
            if context.sample?.externalPower == false {
                if admittedPercentage(state: next, context: context, requiresExternalPower: false) != nil {
                    next.lastSample = context.sample
                }
                next.sampleNotBeforeUptime = context.nowUptime
                return release(&next, context: context)
            }
            guard let p = admittedPercentage(state: next, context: context),
                  temporaryEvidenceIsValid(state: next, context: context) else {
                return fault(&next, reason: "temporaryEvidenceUnavailable", context: context)
            }
            guard let limits = context.safetyLimits, let start = next.temporaryStartedAtUptime,
                  let progress = next.temporaryProgressAtUptime,
                  context.nowUptime >= start, context.nowUptime >= progress,
                  context.nowUptime - start < limits.maxTemporaryModeNanoseconds,
                  context.nowUptime - progress < limits.maxNoProgressNanoseconds else {
                return fault(&next, reason: "temporaryDeadline", context: context)
            }
            if shouldEndTemporary { return endTemporary(&next, context: context) }
            next.lastSample = context.sample
            if let prior = next.temporaryProgressPercentage,
               (next.temporaryMode == .discharging ? p < prior : p > prior) {
                next.temporaryProgressPercentage = p
                next.temporaryProgressAtUptime = context.nowUptime
            }
            if next.temporaryMode == .discharging && p <= Double(next.settings.limit) {
                return endTemporary(&next, context: context)
            }
            if next.temporaryMode == .chargingToFull,
               case .confirmed(_, let sequence) = context.completion,
               let startSequence = next.temporaryStartSequence, sequence > startSequence,
               let startedAt = next.temporaryStartedAtUptime,
               let observedAt = context.sample?.observedAtUptime, observedAt > startedAt {
                next.completion = context.completion
                return endTemporary(&next, context: context)
            }
            // A newly accepted L that did not stop discharge becomes its later exit's same-L baseline.
            next.temporaryExitLimit = next.settings.limit
        }

        if event == .executionObserved {
            // Ignoring a stale receipt must not hide a current loss of safety admission.
            if next.pendingEffect != .releaseOwnedControls && next.pendingEffect != .endTemporaryMode,
               next.pendingEffect != nil || next.confirmedPhase != .unknown,
               admittedPercentage(state: next, context: context) == nil {
                return fault(&next, reason: "admissionUnavailable", context: context)
            }
            guard let execution = context.execution, execution.generation == next.generation,
                  execution.effect == next.pendingEffect else {
                return BatteryCareTransition(state: next, effects: [])
            }
            if execution.effect == .releaseOwnedControls || execution.effect == .endTemporaryMode {
                guard execution.outcome == .accepted, execution.readback != .contradicted,
                      execution.readback != .confirmed(.inhibited),
                      context.recoveryStatus == .released else {
                    return fault(&next, reason: "releaseUnconfirmed", context: context)
                }
                next.pendingEffect = nil
                next.pendingSinceUptime = nil
                next.confirmedPhase = .unknown
                next.recoveryStatus = .released
                return BatteryCareTransition(state: next, effects: [])
            }
            if next.temporaryMode != .none {
                next.pendingEffect = nil
                next.pendingSinceUptime = nil
                return BatteryCareTransition(state: next, effects: [])
            }
            let expected: BatteryCareConfirmedPhase = execution.effect == .allowCharging ? .allowed : .inhibited
            guard !next.requiresRetry, next.recoveryStatus == .released,
                  execution.effect == .allowCharging || execution.effect == .inhibitCharging,
                  execution.outcome == .accepted, execution.readback == .confirmed(expected),
                  admittedPercentage(state: next, context: context) != nil else {
                return fault(&next, reason: "readbackUnconfirmed", context: context)
            }
            next.pendingEffect = nil
            next.pendingSinceUptime = nil
            next.confirmedPhase = expected
            next.lastSample = context.sample
            return BatteryCareTransition(state: next, effects: [])
        }

        if next.pendingEffect == .endTemporaryMode || next.pendingEffect == .releaseOwnedControls {
            return BatteryCareTransition(state: next, effects: [])
        }
        if next.temporaryMode == .none, case .intent(let intent) = event,
           intent == .startDischarge || intent == .startFullCharge {
            return startTemporary(intent == .startDischarge ? .discharging : .chargingToFull,
                                  state: &next, context: context)
        }
        guard next.settings.isEnabled, !next.isSuspended else {
            return release(&next, context: context)
        }
        guard next.temporaryMode == .none else {
            return BatteryCareTransition(state: next, effects: [])
        }
        if next.settings.limit == 100 {
            return release(&next, context: context)
        }
        if context.sample?.externalPower == false {
            if admittedPercentage(state: next, context: context, requiresExternalPower: false) != nil {
                next.lastSample = context.sample
            }
            next.sampleNotBeforeUptime = context.nowUptime
            return release(&next, context: context)
        }
        if let boundary = next.sampleNotBeforeUptime, let sample = context.sample,
           sample.observedAtUptime <= boundary {
            return release(&next, context: context)
        }
        guard let percentage = admittedPercentage(state: next, context: context) else {
            return fault(&next, reason: "admissionUnavailable", context: context)
        }
        next.lastSample = context.sample
        guard !next.requiresRetry, next.pendingEffect == nil, next.pendingRequest == nil else {
            return BatteryCareTransition(state: next, effects: [])
        }
        next.pauseReason = nil
        let limit = Double(next.settings.limit)
        let desired: BatteryCareConfirmedPhase
        let phase = next.temporaryExitLimit == next.settings.limit ? .inhibited : next.confirmedPhase
        switch rebuildPhase ? .unknown : phase {
        case .unknown: desired = percentage >= limit ? .inhibited : .allowed
        case .allowed: desired = percentage >= limit ? .inhibited : .allowed
        case .inhibited: desired = percentage <= limit - 5 ? .allowed : .inhibited
        }
        guard desired != next.confirmedPhase else {
            return BatteryCareTransition(state: next, effects: [])
        }
        next.temporaryExitLimit = nil
        return request(desired == .allowed ? .allowCharging : .inhibitCharging, state: &next, context: context)
    }

    private static func startTemporary(
        _ mode: BatteryCareTemporaryMode, state: inout BatteryCareState, context: BatteryCareContext
    ) -> BatteryCareTransition {
        if state.confirmedPhase != .unknown || state.pendingEffect == .allowCharging || state.pendingEffect == .inhibitCharging {
            guard admittedPercentage(state: state, context: context) != nil else {
                return fault(&state, reason: "admissionUnavailable", context: context)
            }
        }
        guard state.generation < UInt64.max else {
            state.requiresRetry = true
            state.pauseReason = "generationExhausted"
            return BatteryCareTransition(state: state, effects: [])
        }
        guard state.settings.isEnabled, !state.isSuspended, !state.requiresRetry,
              state.pendingEffect == nil, state.pendingRequest == nil, state.recoveryStatus == .released else {
            state.pauseReason = "temporaryStartBlocked"
            return BatteryCareTransition(state: state, effects: [])
        }
        if mode == .chargingToFull && state.settings.limit == 100 {
            state.pauseReason = "regularAlreadyAllowsFull"
            return BatteryCareTransition(state: state, effects: [])
        }
        let operation: BatteryCareOperation = mode == .discharging ? .manualDischarge : .temporaryFullCharge
        guard let p = admittedPercentage(state: state, context: context),
              case .verified(let recordID) = context.capabilities[operation], !recordID.isEmpty,
              mode != .discharging || p > Double(state.settings.limit),
              mode != .chargingToFull || fullEvidenceIsValid(context: context, recordID: recordID) else {
            state.pauseReason = "temporaryAdmissionUnavailable"
            return BatteryCareTransition(state: state, effects: [])
        }
        state.temporaryMode = mode
        state.temporaryStartedAtUptime = context.nowUptime
        state.temporaryStartSequence = context.sample?.sequence
        state.temporaryRecordID = recordID
        state.temporaryProgressPercentage = p
        state.temporaryProgressAtUptime = context.nowUptime
        state.temporaryExitLimit = state.settings.limit
        state.completion = .unknown
        state.lastSample = context.sample
        state.pauseReason = nil
        return request(mode == .discharging ? .startDischarge : .allowCharging, state: &state, context: context)
    }

    private static func temporaryEvidenceIsValid(state: BatteryCareState, context: BatteryCareContext) -> Bool {
        let operation: BatteryCareOperation = state.temporaryMode == .discharging ? .manualDischarge : .temporaryFullCharge
        guard let recordID = state.temporaryRecordID,
              context.capabilities[operation] == .verified(recordID: recordID) else { return false }
        if state.temporaryMode == .discharging { return true }
        return fullEvidenceIsValid(context: context, recordID: recordID)
    }

    private static func fullEvidenceIsValid(
        context: BatteryCareContext, recordID: String
    ) -> Bool {
        guard context.sample?.isCharging != nil else { return false }
        switch context.completion {
        case .unknown: return false
        case .notComplete: return true
        case .confirmed(let record, let sequence):
            return record == recordID && sequence == context.sample?.sequence
                && context.sample?.isCharging == false
        }
    }

    private static func endTemporary(
        _ state: inout BatteryCareState, context: BatteryCareContext
    ) -> BatteryCareTransition {
        guard state.temporaryMode != .none else { return BatteryCareTransition(state: state, effects: []) }
        guard admittedPercentage(state: state, context: context) != nil,
              temporaryEvidenceIsValid(state: state, context: context) else {
            return fault(&state, reason: "temporaryExitEvidenceUnavailable", context: context)
        }
        // Revocation is immediate. The pending stop/recovery latch is a separate fact.
        state.temporaryMode = .none
        state.recoveryStatus = .unconfirmed
        return request(.endTemporaryMode, state: &state, context: context)
    }

    private static func admittedPercentage(
        state: BatteryCareState, context: BatteryCareContext, requiresExternalPower: Bool = true
    ) -> Double? {
        guard state.recoveryStatus == .released,
              context.authorization == .authorized, context.recoveryStatus == .released,
              verified(.regularLimit, context), verified(.releaseOwnedControls, context) else { return nil }
        return observedPercentage(state: state, context: context, requiresExternalPower: requiresExternalPower)
    }

    private static func observedPercentage(
        state: BatteryCareState, context: BatteryCareContext, requiresExternalPower: Bool = true
    ) -> Double? {
        guard let limits = context.safetyLimits, let sample = context.sample,
              let expected = context.expectedIdentity, sample.identity == expected,
              !expected.batteryID.isEmpty, !expected.modelIdentifier.isEmpty, !expected.osBuild.isEmpty,
              sample.presence == .internalBattery,
              sample.externalPower == true || (!requiresExternalPower && sample.externalPower == false),
              sample.lowBatteryProtection == false,
              let percentage = sample.systemPercentage, percentage.isFinite,
              (0...100).contains(percentage), percentage > 20,
              context.nowUptime >= sample.observedAtUptime,
              context.nowUptime - sample.observedAtUptime < limits.maxSampleAgeNanoseconds else { return nil }
        if let boundary = state.sampleNotBeforeUptime, sample.observedAtUptime <= boundary { return nil }
        if let last = state.lastSample {
            guard sample.identity == last.identity else { return nil }
            if sample.sequence == last.sequence {
                guard sample == last else { return nil }
            } else {
                guard sample.sequence > last.sequence, sample.observedAtUptime > last.observedAtUptime else { return nil }
            }
        }
        return percentage
    }

    private static func verified(_ operation: BatteryCareOperation, _ context: BatteryCareContext) -> Bool {
        if case .verified = context.capabilities[operation] { return true }
        return false
    }

    private static func fault(
        _ state: inout BatteryCareState, reason: String, context: BatteryCareContext
    ) -> BatteryCareTransition {
        if state.temporaryMode != .none || state.pendingEffect == .endTemporaryMode {
            state.sampleNotBeforeUptime = context.nowUptime
        }
        state.requiresRetry = true
        state.pauseReason = reason
        return release(&state, context: context)
    }

    private static func release(
        _ state: inout BatteryCareState, context: BatteryCareContext
    ) -> BatteryCareTransition {
        let wasTemporary = state.temporaryMode != .none
        let needsRelease = wasTemporary || state.confirmedPhase != .unknown || state.pendingEffect != nil
            || state.pendingRequest != nil || state.recoveryStatus == .unconfirmed || state.recoveryStatus == .conflict
        state.temporaryMode = .none
        state.temporaryExitLimit = nil
        if wasTemporary && state.pendingEffect == nil && state.generation < UInt64.max { state.generation += 1 }
        state.confirmedPhase = .unknown
        guard needsRelease else { return BatteryCareTransition(state: state, effects: []) }
        state.recoveryStatus = state.recoveryStatus == .conflict || context.recoveryStatus == .conflict ? .conflict : .unconfirmed
        // Retire queued risk now, even when no safe release path is currently available.
        if let pending = state.pendingEffect, pending != .releaseOwnedControls {
            state.pendingEffect = nil
            state.pendingSinceUptime = nil
            if state.generation < UInt64.max { state.generation += 1 }
        }
        guard state.pendingEffect != .releaseOwnedControls,
              context.authorization == .authorized, context.safetyLimits != nil,
              verified(.releaseOwnedControls, context) else {
            return BatteryCareTransition(state: state, effects: [])
        }
        return request(.releaseOwnedControls, state: &state, context: context)
    }

    private static func request(
        _ effect: BatteryCareEffect, state: inout BatteryCareState, context: BatteryCareContext
    ) -> BatteryCareTransition {
        guard state.generation < UInt64.max else {
            state.requiresRetry = true
            state.pauseReason = "generationExhausted"
            return BatteryCareTransition(state: state, effects: [])
        }
        state.generation += 1
        state.confirmedPhase = .unknown
        state.pendingEffect = effect
        state.pendingSinceUptime = context.nowUptime
        return BatteryCareTransition(state: state, effects: [effect])
    }
}
