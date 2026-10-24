import Foundation

public actor BatteryCareSession: BatteryCareServicing {
    private struct Request {
        let id: UUID
        let generation: UInt64
        let event: BatteryCareEvent
        let enqueuedAt: UInt64
        var continuation: CheckedContinuation<BatteryCareReply, Never>?
        var reply: BatteryCareReply?
        var outcome: BatteryCareReply.Outcome = .accepted
        var reduced = false
    }

    private struct Write {
        let effect: BatteryCareEffect
        let generation: UInt64
        let enqueuedAt: UInt64
        let stateBeforeQueue: BatteryCareState
        let event: BatteryCareEvent
    }

    private let backend: any BatteryCareBackend
    private let now: @Sendable () -> UInt64
    private var state = BatteryCareState()
    private var context: BatteryCareContext?
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    // One current-generation idempotency record, one waiter, one writer and the reducer's ordered effects.
    private var request: Request?
    private var writes: [Write] = []
    private var inFlight: Write?
    private var draining = false
    private var refreshRequested = false
    private var observationVersion: UInt64 = 0
    private var leaseRenewedAt: UInt64?
    private var lastNow: UInt64?
    private var readback: BatteryCareReadback = .unknown
    private var physicalObservation: BatteryCarePhysicalObservation = .unknown
    private var subscribers: [UUID: AsyncStream<BatteryCareSnapshot>.Continuation] = [:]

    public init(backend: any BatteryCareBackend, now: @escaping @Sendable () -> UInt64) {
        self.backend = backend
        self.now = now
    }

    public func send(_ command: BatteryCareCommand) async -> BatteryCareReply {
        await submit(id: command.requestID, generation: command.generation, event: .intent(command.intent))
    }

    public func handleLifecycle(_ event: BatteryCareLifecycleEvent, generation: UInt64) async -> BatteryCareReply {
        await submit(id: UUID(), generation: generation, event: .lifecycle(event))
    }

    public func snapshot() -> BatteryCareSnapshot {
        let status: BatteryCareRequestStatus
        if let request {
            switch request.reply?.outcome {
            case .accepted: status = .accepted(requestID: request.id)
            case .rejected(let reason): status = .rejected(requestID: request.id, reason: reason)
            case .outcomeUnknown: status = .outcomeUnknown(requestID: request.id)
            case nil: status = .pending(requestID: request.id)
            }
        } else { status = .idle }
        return .init(settings: state.settings, sample: context?.sample,
                     capabilities: context?.capabilities ?? [:], authorization: context?.authorization ?? .notAuthorized,
                     requestStatus: status, readback: readback, physicalObservation: physicalObservation,
                     recoveryStatus: state.recoveryStatus, safetyLimits: context?.safetyLimits,
                     generation: generation, revision: revision, confirmedPhase: state.confirmedPhase,
                     temporaryMode: state.temporaryMode, completion: state.completion,
                     pauseReason: state.pauseReason, requiresRetry: state.requiresRetry, isSuspended: state.isSuspended)
    }

    /// Latest-state delivery: intermediate revisions may be coalesced, never synthesized.
    public func updates() -> AsyncStream<BatteryCareSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BatteryCareSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    /// Internal collector/watchdog ingress; caller intents and receipts must use their owned paths.
    public func receive(_ event: BatteryCareEvent) async {
        switch event {
        case .tick:
            checkTime()
            reduce(.tick)
            if state.requiresRetry, request?.reply == nil, request?.reduced == true { finish(.outcomeUnknown) }
        case .sampleChanged:
            observationVersion += 1
            refreshRequested = true
        default: return
        }
        publish()
        startDrain()
    }

    private func submit(id: UUID, generation incoming: UInt64, event: BatteryCareEvent) async -> BatteryCareReply {
        if let prior = request, incoming == generation, id == prior.id {
            guard event == prior.event else { return reply(id, incoming, .rejected(reason: "requestIDConflict")) }
            // A duplicate never adds another waiter or another backend operation.
            return prior.reply ?? reply(id, incoming, prior.reduced ? prior.outcome : .rejected(reason: "requestPending"))
        }
        guard incoming > generation else { return reply(id, incoming, .rejected(reason: "staleGeneration")) }
        if let previous = request, previous.reply == nil {
            // Supersession replaces the waiter, not an intent the Policy has already accepted.
            finish(previous.reduced
                ? (inFlight == nil ? previous.outcome : .outcomeUnknown)
                : .rejected(reason: "superseded"))
        }
        checkTime()
        generation = incoming
        return await withCheckedContinuation { continuation in
            request = Request(id: id, generation: incoming, event: event, enqueuedAt: now(), continuation: continuation)
            if needsAdmissionObservation(event) {
                if let pending = state.pendingEffect, isStop(pending) {
                    request?.reduced = true
                    finish(.rejected(reason: "admissionBlockedByStop"))
                }
            } else if context != nil || isStop(event) {
                processRequest()
            }
            publish()
            startDrain()
        }
    }

    private func processRequest() {
        guard let current = request, !current.reduced else { return }
        request?.reduced = true
        let offlineEdit: Bool
        if case .intent(.setLimit) = current.event { offlineEdit = !state.settings.isEnabled }
        else { offlineEdit = false }
        if !isStop(current.event), !offlineEdit,
           !isYoung(current.enqueuedAt, budget: context?.safetyLimits?.maxCommandAgeNanoseconds) {
            finish(.rejected(reason: "commandExpired"))
            return
        }
        let previousSettings = state.settings
        reduce(current.event)
        if case .intent(let intent) = current.event {
            let reason: String?
            switch intent {
            case .setLimit(let limit): reason = (50...100).contains(limit) ? nil : "invalidLimit"
            case .setManagement(true):
                reason = !hasAuthority(for: .regularLimit) || state.requiresRetry
                    || state.isSuspended || state.recoveryStatus != .released
                    ? state.pauseReason ?? "managementAdmissionBlocked" : nil
            case .startDischarge:
                reason = state.temporaryMode == .discharging ? nil : state.pauseReason ?? "temporaryStartBlocked"
            case .startFullCharge:
                reason = state.temporaryMode == .chargingToFull ? nil : state.pauseReason ?? "temporaryStartBlocked"
            case .retryRegular: reason = state.requiresRetry ? "retryBlocked" : nil
            default: reason = nil
            }
            if let reason {
                if intent == .setManagement(true) { state.settings = previousSettings }
                finish(.rejected(reason: reason))
            } else if !state.requiresRetry {
                leaseRenewedAt = now()
            }
        }
    }

    private func reduce(_ event: BatteryCareEvent) {
        let previous = state
        var input = context ?? BatteryCareContext(nowUptime: now())
        input.nowUptime = now()
        let transition = BatteryCarePolicy.reduce(state: state, event: event, context: input)
        state = transition.state
        // Policy retains a pending stop across new L; only an explicit safety upgrade replaces it.
        writes.removeAll { $0.generation != state.generation || $0.effect != state.pendingEffect }
        for effect in transition.effects {
            let enqueuedAt: UInt64
            switch event {
            case .intent, .lifecycle: enqueuedAt = request?.enqueuedAt ?? now()
            default: enqueuedAt = now()
            }
            writes.append(.init(effect: effect, generation: state.generation,
                                enqueuedAt: enqueuedAt, stateBeforeQueue: previous, event: event))
            readback = .unknown
            physicalObservation = .unknown
        }
    }

    private func startDrain() {
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while true {
            if request?.reduced == false || (refreshRequested && writes.isEmpty) {
                let observedGeneration = generation
                let version = observationVersion
                refreshRequested = false
                let observed = await backend.observe()
                guard observedGeneration == generation, version == observationVersion else {
                    refreshRequested = true
                    continue
                }
                adopt(observed)
                checkTime()
                if request?.reduced == false { processRequest() }
                else { reduce(.sampleChanged) }
                publish()
                continue
            }
            guard let write = writes.first else { break }
            let observedGeneration = generation
            let version = observationVersion
            refreshRequested = false
            let observed = await backend.observe()
            guard observedGeneration == generation, version == observationVersion else { continue }
            adopt(observed)
            checkTime()
            reduce(.tick) // Freshness, capabilities, deadlines and generation after the await.
            if state.requiresRetry, request?.reply == nil { request?.outcome = .outcomeUnknown }
            if state.generation == write.generation, state.pendingEffect == write.effect {
                revalidateQueuedRegular(write)
            }
            guard writes.first?.generation == write.generation,
                  state.generation == write.generation, state.pendingEffect == write.effect else {
                publish()
                continue
            }
            if !isStop(write.effect), !isYoung(write.enqueuedAt, budget: context?.safetyLimits?.maxCommandAgeNanoseconds) {
                reduce(.lifecycle(.connectionLost))
                request?.outcome = .outcomeUnknown
                publish()
                continue
            }
            if isStop(write.effect) {
                // A previously queued release is not authority to write after authority is lost.
                guard hasAuthority(for: .releaseOwnedControls) else { break }
            }
            writes.removeFirst()
            inFlight = write
            publish()
            let execution = await backend.apply(write.effect)
            // No timeout or Task cancellation can clear this slot before apply actually returns.
            inFlight = nil
            checkTime()
            let matches = execution.effect == write.effect
            context?.execution = .init(effect: write.effect, generation: write.generation,
                outcome: matches ? execution.outcome : .outcomeUnknown,
                readback: matches ? execution.readback : .contradicted,
                physicalObservation: execution.physicalObservation, recoveryStatus: execution.recoveryStatus)
            context?.recoveryStatus = execution.recoveryStatus
            if execution.recoveryStatus == .conflict { state.recoveryStatus = .conflict }
            let current = state.generation == write.generation && state.pendingEffect == write.effect
            if current {
                readback = matches ? execution.readback : .contradicted
                physicalObservation = execution.physicalObservation
            }
            reduce(.executionObserved)
            context?.execution = nil
            if current, state.requiresRetry || state.pendingEffect == write.effect {
                request?.outcome = .outcomeUnknown
            }
            publish()
        }
        draining = false
        if request?.reply == nil, request?.reduced == true {
            let unknown = state.recoveryStatus == .unconfirmed || state.recoveryStatus == .conflict
            finish(unknown ? .outcomeUnknown : request?.outcome ?? .accepted)
        }
    }

    private func adopt(_ observed: BatteryCareContext) {
        context = observed
        context?.execution = nil // Only this session's apply invocation can produce a receipt.
        context?.nowUptime = now()
    }

    private func revalidateQueuedRegular(_ write: Write) {
        guard inFlight == nil, state.temporaryMode == .none,
              write.effect == .allowCharging || write.effect == .inhibitCharging,
              var input = context else { return }
        input.nowUptime = now()
        // This effect has never executed: replay its real Policy decision, including new-L hysteresis reset.
        var previous = write.stateBeforeQueue
        previous.generation = state.generation
        let updated = BatteryCarePolicy.reduce(state: previous, event: write.event, context: input)
        guard updated.effects != [write.effect] else { return }
        let since = state.pendingSinceUptime
        state = updated.state
        if state.pendingEffect != nil { state.pendingSinceUptime = since }
        writes = updated.effects.map {
            Write(effect: $0, generation: state.generation, enqueuedAt: write.enqueuedAt,
                  stateBeforeQueue: previous, event: write.event)
        }
    }

    private func checkTime() {
        let time = now()
        let backwards = lastNow.map { time < $0 } ?? false
        lastNow = time
        context?.nowUptime = time
        if backwards || (leaseRenewedAt != nil && !isYoung(leaseRenewedAt!, budget: context?.safetyLimits?.leaseNanoseconds)) {
            reduce(.lifecycle(.connectionLost))
            leaseRenewedAt = nil
            if request?.reply == nil, request?.reduced == true { finish(.outcomeUnknown) }
        }
    }

    private func isYoung(_ since: UInt64, budget: UInt64?) -> Bool {
        let time = now()
        guard let budget, time >= since else { return false }
        return time - since < budget
    }

    private func hasAuthority(for operation: BatteryCareOperation) -> Bool {
        guard let context, context.authorization == .authorized, context.safetyLimits != nil,
              case .verified = context.capabilities[operation],
              case .verified = context.capabilities[.releaseOwnedControls] else { return false }
        return true
    }

    private func needsAdmissionObservation(_ event: BatteryCareEvent) -> Bool {
        switch event {
        case .intent(.setManagement(true)), .intent(.startDischarge), .intent(.startFullCharge), .intent(.retryRegular): true
        default: false
        }
    }

    private func isStop(_ effect: BatteryCareEffect) -> Bool {
        effect == .endTemporaryMode || effect == .releaseOwnedControls
    }

    private func isStop(_ event: BatteryCareEvent) -> Bool {
        switch event {
        case .lifecycle, .intent(.setManagement(false)), .intent(.stopDischarge),
             .intent(.cancelFullCharge), .intent(.releaseOwnedControls): true
        default: false
        }
    }

    private func reply(_ id: UUID, _ generation: UInt64, _ outcome: BatteryCareReply.Outcome) -> BatteryCareReply {
        .init(requestID: id, generation: generation, revision: revision, outcome: outcome)
    }

    private func finish(_ outcome: BatteryCareReply.Outcome) {
        guard let current = request, current.reply == nil else { return }
        revision += 1
        let result = reply(current.id, current.generation, outcome)
        request?.reply = result
        request?.continuation = nil
        current.continuation?.resume(returning: result)
        let value = snapshot()
        for subscriber in subscribers.values { subscriber.yield(value) }
    }

    private func publish() {
        revision += 1
        let value = snapshot()
        for subscriber in subscribers.values { subscriber.yield(value) }
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
}
