import Foundation

/// In-process intent, not a wire DTO or a source of trusted observations.
public struct BatteryCareCommand: Equatable, Sendable {
    public let requestID: UUID
    public let generation: UInt64
    public let intent: BatteryCareIntent

    public init(requestID: UUID, generation: UInt64, intent: BatteryCareIntent) {
        self.requestID = requestID
        self.generation = generation
        self.intent = intent
    }
}

public protocol BatteryCareServicing: Sendable {
    func send(_ command: BatteryCareCommand) async -> BatteryCareReply
    func handleLifecycle(_ event: BatteryCareLifecycleEvent, generation: UInt64) async -> BatteryCareReply
    func snapshot() async -> BatteryCareSnapshot
    func updates() async -> AsyncStream<BatteryCareSnapshot>
}

/// A-stage executable implementations live in Tests only. No production hardware backend.
public protocol BatteryCareBackend: Sendable {
    func observe() async -> BatteryCareContext
    func apply(_ effect: BatteryCareEffect) async -> BatteryCareExecution
}
