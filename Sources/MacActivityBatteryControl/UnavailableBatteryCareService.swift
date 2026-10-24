import Foundation

/// Production A-stage service. No executable backend or hardware admission is assembled here.
public actor UnavailableBatteryCareService: BatteryCareServicing {
    private var settings = BatteryCareSettings.default
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var status: BatteryCareRequestStatus = .idle
    private var lastCommand: BatteryCareCommand?
    private var lastReply: BatteryCareReply?
    private var subscribers: [UUID: AsyncStream<BatteryCareSnapshot>.Continuation] = [:]

    public init() {}

    public func snapshot() -> BatteryCareSnapshot {
        .init(settings: settings, requestStatus: status, generation: generation, revision: revision,
              pauseReason: "serviceUnavailable", isSuspended: true)
    }

    public func updates() -> AsyncStream<BatteryCareSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<BatteryCareSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    public func send(_ command: BatteryCareCommand) -> BatteryCareReply {
        if command == lastCommand, let lastReply { return lastReply }
        guard command.generation > generation else {
            return .init(requestID: command.requestID, generation: command.generation, revision: revision,
                         outcome: .rejected(reason: "staleGeneration"))
        }
        let outcome: BatteryCareReply.Outcome
        switch command.intent {
        case .setLimit(let limit):
            if let updated = try? BatteryCareSettings(limit: limit) {
                settings = updated
                outcome = .accepted // Saved intent only; never hardware application.
            } else { outcome = .rejected(reason: "invalidLimit") }
        case .setManagement(true), .startDischarge, .startFullCharge, .retryRegular:
            outcome = .rejected(reason: "serviceUnavailable")
        case .setManagement(false), .stopDischarge, .cancelFullCharge, .releaseOwnedControls:
            outcome = .outcomeUnknown
        }
        let reply = finish(id: command.requestID, generation: command.generation, outcome: outcome)
        lastCommand = command
        lastReply = reply
        return reply
    }

    public func handleLifecycle(_ event: BatteryCareLifecycleEvent, generation: UInt64) -> BatteryCareReply {
        guard generation > self.generation else {
            return .init(requestID: UUID(), generation: generation, revision: revision,
                         outcome: .rejected(reason: "staleGeneration"))
        }
        lastCommand = nil
        lastReply = nil
        return finish(id: UUID(), generation: generation, outcome: .outcomeUnknown)
    }

    private func finish(id: UUID, generation: UInt64, outcome: BatteryCareReply.Outcome) -> BatteryCareReply {
        self.generation = generation
        revision += 1
        switch outcome {
        case .accepted: status = .accepted(requestID: id)
        case .rejected(let reason): status = .rejected(requestID: id, reason: reason)
        case .outcomeUnknown: status = .outcomeUnknown(requestID: id)
        }
        for subscriber in subscribers.values { subscriber.yield(snapshot()) }
        return .init(requestID: id, generation: generation, revision: revision, outcome: outcome)
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }
}
