import Combine
import Foundation
import MacActivityBatteryControl
import MacActivityCore

enum BatteryCareShutdownResult: Equatable, Sendable {
    /// This process never acquired control; says nothing about prior-process residual state.
    case noControlAcquired, released, unconfirmed
}

struct BatteryCarePresentation: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case regular(limit: Int), discharge(limit: Int), fullCharge, systemManaged
    }
    enum DisabledReason: Equatable, Sendable {
        case noInternalBattery, unknownBattery, unverified, unsupported(String), notAuthorized
        case managementDisabled, noExternalPower, sampleUnknown, recoveryUnconfirmed, suspended
        case temporaryModeActive, regularAlreadyAllowsFull
    }
    struct Action: Equatable, Sendable {
        var disabledReason: DisabledReason?
        var isEnabled: Bool { disabledReason == nil }
    }
    enum SaveFailure: Equatable, Sendable { case limit, enable, disable }

    var savedLimit = 80
    var savedEnabled = false
    var acceptedSettings: BatteryCareSettings?
    var previewLimit: Int?
    var pendingLimit: Int?
    var requestedTarget: Target?
    var effectiveTarget: Target?
    var currentSystemPercentage: Double?
    var sample: BatteryCareSample?
    var presence: BatteryCarePresence = .unknown
    var isCharging: Bool?
    var capabilities: [BatteryCareOperation: BatteryCareCapability] = [:]
    var authorization: BatteryCareAuthorization = .notAuthorized
    var requestOutcome: BatteryCareReply.Outcome?
    var requestStatus: BatteryCareRequestStatus = .idle
    var lastIntent: BatteryCareIntent?
    var readback: BatteryCareReadback = .unknown
    var physicalObservation: BatteryCarePhysicalObservation = .unknown
    var completion: BatteryCareCompletion = .unknown
    var temporaryMode: BatteryCareTemporaryMode = .none
    var requiresRetry = false
    var recoveryStatus: BatteryCareRecoveryStatus = .unknown
    var saveFailure: SaveFailure?
    var isPending = false
    var isSuspended = true
    var pauseReason: String?
    var generation: UInt64 = 0
    var revision: UInt64 = 0
    var editLimit = Action()
    var enableManagement = Action(disabledReason: .unverified)
    var disableManagement = Action()
    var startDischarge = Action(disabledReason: .unverified)
    var stopDischarge = Action(disabledReason: .managementDisabled)
    var startFullCharge = Action(disabledReason: .unverified)
    var cancelFullCharge = Action(disabledReason: .managementDisabled)
    var retryRegular = Action(disabledReason: .unverified)
}

@MainActor
final class BatteryCareModel: ObservableObject {
    @Published private(set) var presentation = BatteryCarePresentation()

    private let preferences: PreferencesController
    private let service: any BatteryCareServicing
    private let now: @Sendable () -> UInt64
    private var startup: Task<Void, Never>?
    private var subscription: Task<Void, Never>?
    private var snapshot: BatteryCareSnapshot?
    private var generation: UInt64 = 0
    private var replyRevision: UInt64 = 0
    // A limit edit supersedes a waiter, not an admitted enable. Stops/lifecycle invalidate that grant.
    private var managementEpoch: UInt64 = 0
    private var managementChoice = UUID()
    private var managementRequested: Bool
    private var locallySuspended = false
    private var controlMayHaveBeenAcquired = false
    private var pendingRiskRequests = 0
    private var dischargeMayNeedStop = false
    private var fullChargeMayNeedStop = false
    private var isShuttingDown = false
    private var shutdownTask: Task<BatteryCareShutdownResult, Never>?

    init(preferences: PreferencesController, service: any BatteryCareServicing,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.preferences = preferences
        self.service = service
        self.now = now
        managementRequested = preferences.state.batteryCare.isEnabled
        render()
        startup = Task { [weak self, service] in
            let stream = await service.updates()
            let initial = await service.snapshot()
            guard let self else { return }
            self.receive(initial)
            guard !self.isShuttingDown else { return }
            self.subscription = Task { [weak self] in
                for await value in stream {
                    guard !Task.isCancelled else { break }
                    self?.receive(value)
                }
            }
        }
    }

    deinit { startup?.cancel(); subscription?.cancel() }

    func previewLimit(_ value: Int) {
        guard (50...100).contains(value), presentation.editLimit.isEnabled else { return }
        presentation.previewLimit = value
    }

    func cancelPreview() { presentation.previewLimit = nil }

    /// Keep committed input visible until local persistence resolves, independently of later previews.
    func capturePreviewCommit() -> Int? {
        guard let limit = presentation.previewLimit, presentation.editLimit.isEnabled else { return nil }
        var presentation = self.presentation
        presentation.pendingLimit = limit
        presentation.previewLimit = nil
        self.presentation = presentation
        return limit
    }

    func commitPreview() async {
        guard let limit = capturePreviewCommit() else { return }
        await commitLimit(limit)
    }

    /// A native input boundary captures its value before a later event can cancel/change the preview.
    func commitLimit(_ limit: Int) async {
        guard (50...100).contains(limit) else { return }
        await startup?.value
        guard !isShuttingDown else { finishLimitCommit(limit); return }
        guard presentation.editLimit.isEnabled else { finishLimitCommit(limit); return }
        do {
            try preferences.setBatteryCareSettings(.init(isEnabled: preferences.state.batteryCare.isEnabled, limit: limit))
            presentation.saveFailure = nil
        } catch {
            presentation.saveFailure = .limit
            finishLimitCommit(limit)
            return
        }
        finishLimitCommit(limit)
        _ = await send(.setLimit(limit))
    }

    private func finishLimitCommit(_ limit: Int) {
        render { if $0.pendingLimit == limit { $0.pendingLimit = nil } }
    }

    func setManagementEnabled(_ enabled: Bool) async {
        await startup?.value
        guard !isShuttingDown else { return }
        managementEpoch += 1
        let epoch = managementEpoch
        let choice = UUID()
        managementChoice = choice
        managementRequested = enabled
        locallySuspended = false
        if !enabled {
            // Local risk intent is retired before persistence; a failed save cannot prevent release.
            presentation.requestedTarget = nil
            presentation.effectiveTarget = nil
            do {
                try preferences.setBatteryCareSettings(.init(limit: preferences.state.batteryCare.limit))
                presentation.saveFailure = nil
            } catch { presentation.saveFailure = .disable }
            _ = await send(.setManagement(false))
            return
        }
        var preparedLimit = snapshot?.settings.limit
        while preparedLimit != preferences.state.batteryCare.limit {
            let limit = preferences.state.batteryCare.limit
            let preparation = await send(.setLimit(limit))
            guard managementEpoch == epoch else {
                if !preferences.state.batteryCare.isEnabled, snapshot?.settings.isEnabled == true {
                    await withdrawUnpersistedEnable(ifChoiceIs: choice)
                }
                return
            }
            guard let preparation, preparation.outcome == .accepted else {
                managementRequested = preferences.state.batteryCare.isEnabled
                if !preferences.state.batteryCare.isEnabled, snapshot?.settings.isEnabled == true {
                    await withdrawUnpersistedEnable(ifChoiceIs: choice)
                }
                render()
                return
            }
            if let snapshot, snapshot.generation >= preparation.generation, snapshot.revision >= preparation.revision {
                preparedLimit = snapshot.settings.limit
            } else { preparedLimit = limit }
        }
        let reply = await send(.setManagement(true))
        guard managementEpoch == epoch else {
            if !preferences.state.batteryCare.isEnabled,
               reply?.outcome == .accepted || reply?.outcome == .outcomeUnknown {
                await withdrawUnpersistedEnable(ifChoiceIs: choice)
            }
            return
        }
        guard reply?.outcome == .accepted else {
            managementRequested = preferences.state.batteryCare.isEnabled
            if reply?.outcome == .outcomeUnknown
                || (!preferences.state.batteryCare.isEnabled && snapshot?.settings.isEnabled == true) {
                await withdrawUnpersistedEnable(ifChoiceIs: choice)
            }
            render()
            return
        }
        do {
            // A newer setLimit may have completed while admission was pending: save that latest L.
            try preferences.setBatteryCareSettings(.init(isEnabled: true, limit: preferences.state.batteryCare.limit))
            presentation.saveFailure = nil
            render()
        } catch {
            presentation.saveFailure = .enable
            await withdrawUnpersistedEnable(ifChoiceIs: choice)
        }
    }

    private func withdrawUnpersistedEnable(ifChoiceIs choice: UUID) async {
        guard managementChoice == choice else { return }
        managementRequested = false
        locallySuspended = true
        // Release alone retains Session.settings.isEnabled and can resume on wake.
        _ = await send(.setManagement(false))
    }

    func startDischarge() async { await startup?.value; _ = await send(.startDischarge) }
    func stopDischarge() async { await startup?.value; _ = await send(.stopDischarge) }
    func startFullCharge() async { await startup?.value; _ = await send(.startFullCharge) }
    func cancelFullCharge() async { await startup?.value; _ = await send(.cancelFullCharge) }
    func retryRegular() async {
        await startup?.value
        guard !isShuttingDown else { return }
        locallySuspended = false
        _ = await send(.retryRegular)
    }

    func handleLifecycle(_ event: BatteryCareLifecycleEvent) async {
        guard !isShuttingDown || event == .quit else { return }
        await startup?.value
        guard !Task.isCancelled, !isShuttingDown || event == .quit else { return }
        managementEpoch += 1
        cancelPreview()
        locallySuspended = event != .didWake && event != .pluggedIn
        guard let token = nextGeneration() else { return }
        render {
            $0.lastIntent = nil
            $0.requestOutcome = nil
            $0.requestedTarget = nil
            $0.isPending = true
        }
        let reply = await service.handleLifecycle(event, generation: token)
        if reply.generation == token, generation == token { acceptReply(reply) }
        receive(await service.snapshot())
    }

    /// Synchronous quit barrier: queued startup/UI work cannot acquire control after termination begins.
    func requestShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        managementEpoch += 1
        locallySuspended = true
        cancelPreview()
        subscription?.cancel()
        render()
    }

    func shutdown() async -> BatteryCareShutdownResult {
        if let shutdownTask { return await shutdownTask.value }
        requestShutdown()
        let task = Task { @MainActor in
            // The service owns cleanup bounds. No invented hardware timeout or cancellation-as-release.
            await self.handleLifecycle(.quit)
            if let snapshot = self.snapshot, snapshot.generation == self.generation,
               snapshot.recoveryStatus == .released, snapshot.temporaryMode == .none,
               self.presentation.requestOutcome == .accepted { return BatteryCareShutdownResult.released }
            return self.controlMayHaveBeenAcquired || self.pendingRiskRequests > 0 ? .unconfirmed : .noControlAcquired
        }
        shutdownTask = task
        return await task.value
    }

    private func send(_ intent: BatteryCareIntent) async -> BatteryCareReply? {
        if isShuttingDown {
            switch intent {
            case .setManagement(false), .stopDischarge, .cancelFullCharge, .releaseOwnedControls: break
            default: return nil
            }
        }
        guard let token = nextGeneration() else { return nil }
        let command = BatteryCareCommand(requestID: UUID(), generation: token, intent: intent)
        let risk: Bool
        switch intent {
        case .setManagement(true), .startDischarge, .startFullCharge, .retryRegular: risk = true
        case .setLimit: risk = snapshot?.settings.isEnabled == true
        default: risk = false
        }
        if risk { pendingRiskRequests += 1 }
        defer { if risk { pendingRiskRequests -= 1 } }
        let previousDischargeStop = dischargeMayNeedStop
        let previousFullChargeStop = fullChargeMayNeedStop
        switch intent {
        case .startDischarge: dischargeMayNeedStop = true
        case .startFullCharge: fullChargeMayNeedStop = true
        default: break
        }
        render {
            $0.lastIntent = intent
            $0.requestOutcome = nil
            $0.isPending = true
        }
        let reply = await service.send(command)
        guard reply.requestID == command.requestID, reply.generation == token else { return nil }
        if generation == token, case .rejected = reply.outcome {
            if intent == .startDischarge { dischargeMayNeedStop = previousDischargeStop }
            if intent == .startFullCharge { fullChargeMayNeedStop = previousFullChargeStop }
        }
        if risk, reply.outcome == .accepted || reply.outcome == .outcomeUnknown {
            controlMayHaveBeenAcquired = true
        }
        if generation == token { acceptReply(reply) }
        receive(await service.snapshot())
        return reply
    }

    private func nextGeneration() -> UInt64? {
        guard generation < UInt64.max else {
            presentation.requestOutcome = .outcomeUnknown
            locallySuspended = true
            render()
            return nil
        }
        generation += 1
        return generation
    }

    private func acceptReply(_ reply: BatteryCareReply) {
        if let snapshot, snapshot.generation == reply.generation, snapshot.revision > reply.revision { return }
        replyRevision = max(replyRevision, reply.revision)
        render {
            $0.requestOutcome = reply.outcome
            $0.isPending = false
        }
    }

    private func receive(_ value: BatteryCareSnapshot) {
        guard value.generation >= generation, value.revision >= replyRevision,
              snapshot.map({ value.revision > $0.revision }) ?? true else { return }
        generation = value.generation
        snapshot = value
        if value.settings.isEnabled || value.temporaryMode != .none || value.confirmedPhase != .unknown
            || value.recoveryStatus == .unconfirmed || value.recoveryStatus == .conflict {
            controlMayHaveBeenAcquired = true
        }
        if value.temporaryMode == .discharging { dischargeMayNeedStop = true }
        if value.temporaryMode == .chargingToFull { fullChargeMayNeedStop = true }
        let requestIsPending: Bool
        if case .pending = value.requestStatus { requestIsPending = true }
        else { requestIsPending = false }
        // Before admission, released/none is the old baseline, not a stop acknowledgement.
        if !requestIsPending, value.recoveryStatus == .released, value.temporaryMode == .none {
            dischargeMayNeedStop = false
            fullChargeMayNeedStop = false
        }
        render { presentation in
            switch value.requestStatus {
            case .accepted: presentation.requestOutcome = .accepted; presentation.isPending = false
            case .rejected(_, let reason): presentation.requestOutcome = .rejected(reason: reason); presentation.isPending = false
            case .outcomeUnknown: presentation.requestOutcome = .outcomeUnknown; presentation.isPending = false
            case .pending: presentation.isPending = true
            case .idle: break
            }
        }
    }

    private func render(updating update: (inout BatteryCarePresentation) -> Void = { _ in }) {
        var presentation = self.presentation
        update(&presentation)
        defer { self.presentation = presentation }
        let saved = preferences.state.batteryCare
        let value = snapshot ?? BatteryCareSnapshot()
        let current = value.generation == generation
        presentation.savedLimit = saved.limit
        presentation.savedEnabled = saved.isEnabled
        presentation.acceptedSettings = snapshot?.settings
        presentation.generation = generation
        presentation.revision = value.revision
        presentation.sample = value.sample
        presentation.presence = value.sample?.presence ?? .unknown
        presentation.isCharging = value.sample?.isCharging
        presentation.capabilities = value.capabilities
        presentation.authorization = value.authorization
        presentation.requestStatus = current ? value.requestStatus : .idle
        presentation.readback = current ? value.readback : .unknown
        presentation.physicalObservation = current ? value.physicalObservation : .unknown
        presentation.completion = current ? value.completion : .unknown
        presentation.recoveryStatus = current ? value.recoveryStatus : .unknown
        presentation.temporaryMode = current ? value.temporaryMode : .none
        presentation.requiresRetry = value.requiresRetry
        presentation.pauseReason = value.pauseReason
        presentation.isSuspended = locallySuspended || value.isSuspended || (saved.isEnabled && !value.settings.isEnabled)
        presentation.currentSystemPercentage = validPercentage(value)
        presentation.editLimit = .init(disabledReason: presentation.presence == .absent ? .noInternalBattery : nil)
        presentation.enableManagement = .init(disabledReason: disabledReason(.regularLimit, value: value))
        presentation.startDischarge = .init(disabledReason: startReason(.manualDischarge, value: value))
        presentation.startFullCharge = .init(disabledReason: startReason(.temporaryFullCharge, value: value))
        presentation.retryRegular = .init(disabledReason: disabledReason(.regularLimit, value: value))
        presentation.stopDischarge = .init(disabledReason: dischargeMayNeedStop ? nil : .managementDisabled)
        presentation.cancelFullCharge = .init(disabledReason: fullChargeMayNeedStop ? nil : .managementDisabled)

        var target: BatteryCarePresentation.Target?
        if managementRequested && !locallySuspended {
            switch current ? value.temporaryMode : .none {
            case .discharging: target = .discharge(limit: value.settings.limit)
            case .chargingToFull: target = .fullCharge
            case .none: target = .regular(limit: saved.limit)
            }
            if presentation.isPending || !current {
                switch presentation.requestOutcome {
                case .rejected: break
                default:
                    switch presentation.lastIntent {
                    case .startDischarge: target = .discharge(limit: saved.limit)
                    case .startFullCharge: target = .fullCharge
                    default: break
                    }
                }
            }
        }
        presentation.requestedTarget = target
        presentation.effectiveTarget = nil
        guard current, !presentation.isPending, !presentation.isSuspended, !value.requiresRetry,
              value.recoveryStatus == .released else { return }
        if !value.settings.isEnabled, !managementRequested {
            // Released is a distinct service fact, never inferred from a saved false toggle.
            presentation.effectiveTarget = .systemManaged
        } else if let target, value.settings.isEnabled,
                  presentation.currentSystemPercentage != nil, value.sample?.externalPower == true,
                  disabledReason(operation(for: value.temporaryMode), value: value) == nil,
                  case .confirmed(let phase) = value.readback, phase != .unknown,
                  value.temporaryMode != .none || phase == value.confirmedPhase,
                  value.settings.limit == saved.limit {
            presentation.effectiveTarget = target
        }
    }

    private func operation(for mode: BatteryCareTemporaryMode) -> BatteryCareOperation {
        switch mode {
        case .none: .regularLimit
        case .discharging: .manualDischarge
        case .chargingToFull: .temporaryFullCharge
        }
    }

    private func validPercentage(_ value: BatteryCareSnapshot) -> Double? {
        guard let sample = value.sample, sample.presence == .internalBattery, sample.identity != nil,
              let percentage = sample.systemPercentage, percentage.isFinite, (0...100).contains(percentage),
              let age = value.safetyLimits?.maxSampleAgeNanoseconds else { return nil }
        let time = now()
        guard time >= sample.observedAtUptime, time - sample.observedAtUptime < age else { return nil }
        return percentage
    }

    private func disabledReason(_ operation: BatteryCareOperation, value: BatteryCareSnapshot) -> BatteryCarePresentation.DisabledReason? {
        if value.sample?.presence == .absent { return .noInternalBattery }
        for capability in [value.capabilities[operation], value.capabilities[.releaseOwnedControls]] {
            switch capability {
            case .verified: break
            case .unsupported(let reason): return .unsupported(reason)
            default: return .unverified
            }
        }
        if value.sample?.presence != .internalBattery || value.sample?.identity == nil { return .unknownBattery }
        if value.authorization != .authorized { return .notAuthorized }
        if value.safetyLimits == nil || validPercentage(value) == nil { return .sampleUnknown }
        if value.recoveryStatus != .released { return .recoveryUnconfirmed }
        return nil
    }

    private func startReason(_ operation: BatteryCareOperation, value: BatteryCareSnapshot) -> BatteryCarePresentation.DisabledReason? {
        if let reason = disabledReason(operation, value: value) { return reason }
        if !managementRequested || !preferences.state.batteryCare.isEnabled { return .managementDisabled }
        if locallySuspended || value.isSuspended || value.requiresRetry { return .suspended }
        if operation == .temporaryFullCharge && preferences.state.batteryCare.limit == 100 {
            return .regularAlreadyAllowsFull
        }
        if value.temporaryMode != .none || dischargeMayNeedStop || fullChargeMayNeedStop { return .temporaryModeActive }
        if value.sample?.externalPower != true { return .noExternalPower }
        if value.sample?.isCharging == nil || value.sample?.lowBatteryProtection == nil { return .sampleUnknown }
        return nil
    }
}
