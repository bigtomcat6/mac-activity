import Combine
import Foundation
import MacActivityCore

@MainActor
protocol EnergyImpactProviding: AnyObject {
    func beginSession() async -> EnergyImpactSessionID
    func sample(
        sessionID: EnergyImpactSessionID,
        limit: Int,
        scope: EnergyImpactAppScope,
        publicationBoundary: Bool
    ) async -> [EnergyImpactEntry]?
    func endSession(_ sessionID: EnergyImpactSessionID) async
}

extension EnergyImpactService: EnergyImpactProviding {}

@MainActor
final class EnergyImpactModel: ObservableObject {
    @Published private(set) var entries: [EnergyImpactEntry] = []
    @Published private(set) var isRefreshing = false

    private let provider: any EnergyImpactProviding
    private let limit: Int
    private let sampleIntervalNanoseconds: UInt64
    private let publicationIntervalNanoseconds: UInt64
    private let sleep: @MainActor (UInt64) async throws -> Void

    private var activeRunID: UUID?
    private var activeSessionID: EnergyImpactSessionID?
    private var providerRequestInFlight = false
    private var providerRequestWaiters = [CheckedContinuation<Void, Never>]()

    init(
        provider: any EnergyImpactProviding = EnergyImpactService(),
        limit: Int = 20,
        sampleIntervalNanoseconds: UInt64 = 1_000_000_000,
        publicationIntervalNanoseconds: UInt64 = 3_000_000_000,
        sleep: @escaping @MainActor (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.provider = provider
        self.limit = limit
        self.sampleIntervalNanoseconds = sampleIntervalNanoseconds
        self.publicationIntervalNanoseconds = publicationIntervalNanoseconds
        self.sleep = sleep
    }

    func refreshWhileVisible() async {
        let runID = UUID()
        activeRunID = runID
        activeSessionID = nil
        isRefreshing = true

        guard Task.isCancelled == false else {
            clearRunIfCurrent(runID)
            return
        }
        guard let sessionID = await beginProviderSession(for: runID),
              isCurrent(runID),
              Task.isCancelled == false else {
            clearRunIfCurrent(runID)
            return
        }
        activeSessionID = sessionID

        guard case let .sampled(initial) = await sampleProvider(
            for: runID,
            sessionID: sessionID,
            publicationBoundary: false
        ) else {
            await endProviderSessionIfCurrent(sessionID, for: runID)
            clearRunIfCurrent(runID)
            return
        }

        var latest = initial
        var elapsedSincePublication: UInt64 = 0
        do {
            while isCurrent(runID), Task.isCancelled == false {
                try await sleep(sampleIntervalNanoseconds)
                guard isCurrent(runID), Task.isCancelled == false else { break }

                let nextElapsed = elapsedSincePublication.addingReportingOverflow(
                    sampleIntervalNanoseconds
                )
                let willPublish = nextElapsed.overflow
                    || nextElapsed.partialValue >= publicationIntervalNanoseconds
                guard case let .sampled(sampled) = await sampleProvider(
                    for: runID,
                    sessionID: sessionID,
                    publicationBoundary: willPublish
                ) else { break }
                latest = sampled
                guard isCurrent(runID), Task.isCancelled == false else { break }

                elapsedSincePublication = nextElapsed.partialValue
                if willPublish {
                    entries = latest
                    isRefreshing = false
                    elapsedSincePublication = 0
                }
            }
        } catch is CancellationError {
            // Hiding the page normally cancels its view task.
        } catch {
            // Keep current rows visible. The next page appearance starts a fresh session.
        }

        await endProviderSessionIfCurrent(sessionID, for: runID)
        clearRunIfCurrent(runID)
    }

    private func beginProviderSession(for runID: UUID) async -> EnergyImpactSessionID? {
        await acquireProviderRequestGate()
        defer { releaseProviderRequestGate() }
        guard isCurrent(runID), Task.isCancelled == false else { return nil }
        return await provider.beginSession()
    }

    private func sampleProvider(
        for runID: UUID,
        sessionID: EnergyImpactSessionID,
        publicationBoundary: Bool
    ) async -> ProviderSampleResult {
        await acquireProviderRequestGate()
        defer { releaseProviderRequestGate() }
        guard isCurrent(runID),
              activeSessionID == sessionID,
              Task.isCancelled == false else { return .stopped }
        guard let sampled = await provider.sample(
            sessionID: sessionID,
            limit: limit,
            scope: .regularOnly,
            publicationBoundary: publicationBoundary
        ), isCurrent(runID), Task.isCancelled == false else {
            return .stopped
        }
        return .sampled(sampled)
    }

    private func endProviderSessionIfCurrent(
        _ sessionID: EnergyImpactSessionID,
        for runID: UUID
    ) async {
        await acquireProviderRequestGate()
        defer { releaseProviderRequestGate() }
        guard isCurrent(runID), activeSessionID == sessionID else { return }
        await provider.endSession(sessionID)
    }

    private func acquireProviderRequestGate() async {
        guard providerRequestInFlight else {
            providerRequestInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            providerRequestWaiters.append(continuation)
        }
    }

    private func releaseProviderRequestGate() {
        guard providerRequestWaiters.isEmpty == false else {
            providerRequestInFlight = false
            return
        }
        providerRequestWaiters.removeFirst().resume()
    }

    private func isCurrent(_ runID: UUID) -> Bool {
        activeRunID == runID
    }

    private func clearRunIfCurrent(_ runID: UUID) {
        guard isCurrent(runID) else { return }
        activeRunID = nil
        activeSessionID = nil
        isRefreshing = false
    }
}

private enum ProviderSampleResult {
    case sampled([EnergyImpactEntry])
    case stopped
}
