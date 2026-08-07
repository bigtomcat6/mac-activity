import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactModelTests: XCTestCase {
    func testImmediateBaselineOneSecondCadenceAndThreeSecondPublication() async throws {
        let provider = ControlledEnergyImpactProvider()
        var requestedSleeps = [UInt64]()
        let model = EnergyImpactModel(
            provider: provider,
            sampleIntervalNanoseconds: 1,
            publicationIntervalNanoseconds: 3,
            sleep: { duration in
                requestedSleeps.append(duration)
                if requestedSleeps.count == 4 {
                    throw CancellationError()
                }
            }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(provider.sampleRequests.count, 4)
        XCTAssertEqual(provider.requestCountBeforeFirstPublish, 4)
        XCTAssertEqual(Array(requestedSleeps.prefix(3)), [1, 1, 1])
        XCTAssertEqual(model.entries.first?.name, "Run 1")
        XCTAssertEqual(provider.maximumConcurrentRequests, 1)
        XCTAssertTrue(provider.didEndCurrentSessionAfterCancellation)
        XCTAssertFalse(model.isRefreshing)
    }

    func testRapidRunsSerializeProviderRequestsAndOnlyNewestRunPublishes() async {
        let provider = ControlledEnergyImpactProvider(suspendFirstSample: true)
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: provider,
            sampleIntervalNanoseconds: 1,
            publicationIntervalNanoseconds: 3,
            sleep: { _ in
                sleepCount += 1
                if sleepCount == 4 {
                    throw CancellationError()
                }
            }
        )

        let oldTask = Task { await model.refreshWhileVisible() }
        await provider.waitUntilFirstSampleStarts()
        let newTask = Task { await model.refreshWhileVisible() }
        await Task.yield()
        provider.resumeFirstSample()
        await oldTask.value
        await newTask.value

        XCTAssertEqual(provider.maximumConcurrentRequests, 1)
        XCTAssertEqual(provider.beginCount, 2)
        XCTAssertEqual(provider.sampleRequests.count, 5)
        XCTAssertEqual(provider.endedRunNumbers, [2])
        XCTAssertEqual(model.entries.first?.name, "Run 2")
        XCTAssertFalse(model.isRefreshing)
    }

    func testCancellationAfterSamplePreventsPublicationAndEndsCurrentSession() async {
        let provider = ControlledEnergyImpactProvider(cancelOnPublicationSample: true)
        let model = EnergyImpactModel(
            provider: provider,
            sampleIntervalNanoseconds: 1,
            publicationIntervalNanoseconds: 3,
            sleep: { _ in }
        )

        let task = Task { await model.refreshWhileVisible() }
        await task.value

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(provider.requestCountBeforeFirstPublish, 4)
        XCTAssertEqual(provider.endedRunNumbers, [1])
        XCTAssertFalse(model.isRefreshing)
    }

    func testThrowingSleeperEndsCurrentSession() async {
        let provider = ControlledEnergyImpactProvider()
        let model = EnergyImpactModel(
            provider: provider,
            sampleIntervalNanoseconds: 1,
            publicationIntervalNanoseconds: 3,
            sleep: { _ in throw SleeperFailure.expected }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(provider.sampleRequests.count, 1)
        XCTAssertEqual(provider.endedRunNumbers, [1])
        XCTAssertFalse(model.isRefreshing)
    }

    func testAlreadyCancelledVisibleRunPerformsNoProviderReads() async {
        let provider = ControlledEnergyImpactProvider()
        let model = EnergyImpactModel(
            provider: provider,
            sampleIntervalNanoseconds: 1,
            publicationIntervalNanoseconds: 3,
            sleep: { _ in }
        )

        let task = Task { await model.refreshWhileVisible() }
        task.cancel()
        await task.value

        XCTAssertEqual(provider.beginCount, 0)
        XCTAssertTrue(provider.sampleRequests.isEmpty)
        XCTAssertTrue(provider.endedRunNumbers.isEmpty)
        XCTAssertFalse(model.isRefreshing)
    }
}

private enum SleeperFailure: Error {
    case expected
}

@MainActor
private final class ControlledEnergyImpactProvider: EnergyImpactProviding {
    struct SampleRequest: Equatable {
        let runNumber: Int
        let publicationBoundary: Bool
    }

    private let suspendFirstSample: Bool
    private let cancelOnPublicationSample: Bool
    private var currentSessionID: EnergyImpactSessionID?
    private var runNumberBySessionID: [EnergyImpactSessionID: Int] = [:]
    private var activeRequestCount = 0
    private var firstSampleDidStart = false
    private var firstSampleStartWaiters = [CheckedContinuation<Void, Never>]()
    private var firstSampleContinuation: CheckedContinuation<Void, Never>?

    private(set) var beginCount = 0
    private(set) var sampleRequests = [SampleRequest]()
    private(set) var endedRunNumbers = [Int]()
    private(set) var maximumConcurrentRequests = 0
    private(set) var requestCountBeforeFirstPublish: Int?
    private(set) var didEndCurrentSessionAfterCancellation = false

    init(
        suspendFirstSample: Bool = false,
        cancelOnPublicationSample: Bool = false
    ) {
        self.suspendFirstSample = suspendFirstSample
        self.cancelOnPublicationSample = cancelOnPublicationSample
    }

    func beginSession() async -> EnergyImpactSessionID {
        enterRequest()
        defer { leaveRequest() }
        beginCount += 1
        let sessionID = EnergyImpactSessionID()
        runNumberBySessionID[sessionID] = beginCount
        currentSessionID = sessionID
        return sessionID
    }

    func sample(
        sessionID: EnergyImpactSessionID,
        limit: Int,
        scope: EnergyImpactAppScope,
        publicationBoundary: Bool
    ) async -> [EnergyImpactEntry]? {
        enterRequest()
        defer { leaveRequest() }
        guard let runNumber = runNumberBySessionID[sessionID],
              sessionID == currentSessionID else { return nil }
        sampleRequests.append(SampleRequest(
            runNumber: runNumber,
            publicationBoundary: publicationBoundary
        ))
        if publicationBoundary, requestCountBeforeFirstPublish == nil {
            requestCountBeforeFirstPublish = sampleRequests.count
        }
        if suspendFirstSample, sampleRequests.count == 1 {
            firstSampleDidStart = true
            let waiters = firstSampleStartWaiters
            firstSampleStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstSampleContinuation = continuation
            }
        }
        if publicationBoundary, cancelOnPublicationSample {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return [entry(name: "Run \(runNumber)")]
    }

    func endSession(_ sessionID: EnergyImpactSessionID) async {
        enterRequest()
        defer { leaveRequest() }
        guard let runNumber = runNumberBySessionID[sessionID] else { return }
        endedRunNumbers.append(runNumber)
        if currentSessionID == sessionID {
            currentSessionID = nil
            didEndCurrentSessionAfterCancellation = true
        }
    }

    func waitUntilFirstSampleStarts() async {
        if firstSampleDidStart { return }
        await withCheckedContinuation { continuation in
            firstSampleStartWaiters.append(continuation)
        }
    }

    func resumeFirstSample() {
        firstSampleContinuation?.resume()
        firstSampleContinuation = nil
    }

    private func enterRequest() {
        activeRequestCount += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequestCount)
    }

    private func leaveRequest() {
        activeRequestCount -= 1
    }

    private func entry(name: String) -> EnergyImpactEntry {
        EnergyImpactEntry(
            identity: EnergyImpactAppIdentity(
                rootProcessIdentifier: 101,
                rootProcessStartAbsoluteTime: 10
            ),
            name: name,
            bundleIdentifier: "example.fixture",
            bundleURL: nil,
            currentPowerMicrowatts: 1,
            sustainedPowerMicrowatts: nil,
            rankingScore: 1,
            trend: .steady,
            coverage: EnergyImpactCoverage(
                discoveredProcessCount: 1,
                readableProcessCount: 1,
                validProcessSeconds: 1,
                discoveredProcessSeconds: 1
            ),
            status: .stable
        )
    }
}
