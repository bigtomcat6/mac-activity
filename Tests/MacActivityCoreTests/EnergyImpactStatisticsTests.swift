import Darwin
import XCTest
@testable import MacActivityCore

final class EnergyImpactStatisticsTests: XCTestCase {
    func testTimeAwareEMAUsesFourSecondHalfLife() throws {
        var ema = TimeAwareEnergyEMA(halfLifeSeconds: 4)

        XCTAssertEqual(ema.update(value: 100, elapsedSeconds: 3), 100)
        let decayed = try XCTUnwrap(ema.update(value: 0, elapsedSeconds: 3))
        XCTAssertEqual(
            decayed,
            59.460_355_75,
            accuracy: 0.000_001
        )
    }

    func testNewProcessGenerationDoesNotInheritOldSmoothing() {
        var smoother = EnergyImpactSmoother(halfLifeSeconds: 4)
        let old = EnergyImpactProcessIdentity(
            processIdentifier: 101,
            processStartAbsoluteTime: 10
        )
        let replacement = EnergyImpactProcessIdentity(
            processIdentifier: 101,
            processStartAbsoluteTime: 20
        )

        XCTAssertEqual(smoother.update(identity: old, value: 100, elapsedSeconds: 3), 100)
        XCTAssertEqual(smoother.update(identity: replacement, value: 5, elapsedSeconds: 3), 5)
    }

    func testInvalidEMAInputDoesNotBecomeZeroOrMutateState() {
        var ema = TimeAwareEnergyEMA(halfLifeSeconds: 4)
        XCTAssertEqual(ema.update(value: 100, elapsedSeconds: 1), 100)
        XCTAssertNil(ema.update(value: .nan, elapsedSeconds: 1))
        XCTAssertNil(ema.update(value: -1, elapsedSeconds: 1))
        XCTAssertEqual(ema.update(value: 100, elapsedSeconds: 1), 100)
    }

    func testRankerRequiresTwoTenPercentLeadsButAcceptsTwentyFivePercentImmediately() {
        var ranker = StableEnergyImpactRanker()
        let a = fixtureEntry(pid: 1, score: 100)
        let b = fixtureEntry(pid: 2, score: 90)
        XCTAssertEqual(ranker.rank([a, b], atPublicationBoundary: true).map(\.processIdentifier), [1, 2])

        let nearLead = fixtureEntry(pid: 2, score: 112)
        XCTAssertEqual(ranker.rank([a, nearLead], atPublicationBoundary: true).map(\.processIdentifier), [1, 2])
        XCTAssertEqual(ranker.rank([a, nearLead], atPublicationBoundary: true).map(\.processIdentifier), [2, 1])

        let immediate = fixtureEntry(pid: 1, score: 150)
        XCTAssertEqual(ranker.rank([immediate, nearLead], atPublicationBoundary: true).map(\.processIdentifier), [1, 2])
    }

    func testPositiveChallengerImmediatelyPassesZeroIncumbent() {
        var ranker = StableEnergyImpactRanker()
        let incumbent = fixtureEntry(pid: 1, score: 0)
        let zeroChallenger = fixtureEntry(pid: 2, score: 0)

        XCTAssertEqual(
            ranker.rank([incumbent, zeroChallenger], atPublicationBoundary: true)
                .map(\.processIdentifier),
            [1, 2]
        )

        let positiveChallenger = fixtureEntry(pid: 2, score: 1)
        XCTAssertEqual(
            ranker.rank([incumbent, positiveChallenger], atPublicationBoundary: true)
                .map(\.processIdentifier),
            [2, 1]
        )
    }

    func testStableEntryRanksAheadOfHigherScoringStaleEntry() {
        var ranker = StableEnergyImpactRanker()
        let stable = fixtureEntry(pid: 1, score: 1, status: .stable)
        let stale = fixtureEntry(pid: 2, score: 1_000, status: .stale)

        XCTAssertEqual(
            ranker.rank([stale, stable], atPublicationBoundary: true).map(\.processIdentifier),
            [1, 2]
        )
    }

    func testNumericStaleEntriesUseDisplayPowerForDeterministicOrdering() {
        var ranker = StableEnergyImpactRanker()
        let low = fixtureEntry(
            pid: 1,
            score: 1,
            status: .stale,
            hasRankingScore: false,
            name: "Alpha"
        )
        let high = fixtureEntry(
            pid: 2,
            score: 100,
            status: .stale,
            hasRankingScore: false,
            name: "Zulu"
        )

        let ranked = ranker.rank([low, high], atPublicationBoundary: true)

        XCTAssertEqual(ranked.map(\.processIdentifier), [2, 1])
        XCTAssertTrue(ranked.allSatisfy { $0.rankingScore == nil })
    }

    func testChallengerLosesConfirmationWhenItStopsBeingAdjacent() {
        var ranker = StableEnergyImpactRanker()
        let incumbent = fixtureEntry(pid: 1, score: 100)
        let challenger = fixtureEntry(pid: 2, score: 112)

        _ = ranker.rank(
            [incumbent, fixtureEntry(pid: 2, score: 90)],
            atPublicationBoundary: true
        )
        XCTAssertEqual(
            ranker.rank([incumbent, challenger], atPublicationBoundary: true)
                .map(\.processIdentifier),
            [1, 2]
        )
        XCTAssertEqual(
            ranker.rank([incumbent], atPublicationBoundary: true)
                .map(\.processIdentifier),
            [1]
        )
        XCTAssertEqual(
            ranker.rank([incumbent, challenger], atPublicationBoundary: true)
                .map(\.processIdentifier),
            [1, 2]
        )
        XCTAssertEqual(
            ranker.rank([incumbent, challenger], atPublicationBoundary: true)
                .map(\.processIdentifier),
            [2, 1]
        )
    }

    func testDisplacedPairDoesNotRetainConfirmationWhenItBecomesAdjacentAgain() {
        var ranker = StableEnergyImpactRanker()

        XCTAssertEqual(
            ranker.rank(
                [
                    fixtureEntry(pid: 1, score: 100),
                    fixtureEntry(pid: 2, score: 90),
                    fixtureEntry(pid: 3, score: 80),
                ],
                atPublicationBoundary: true
            ).map(\.processIdentifier),
            [1, 2, 3]
        )
        XCTAssertEqual(
            ranker.rank(
                [
                    fixtureEntry(pid: 1, score: 100),
                    fixtureEntry(pid: 2, score: 90),
                    fixtureEntry(pid: 3, score: 100),
                ],
                atPublicationBoundary: true
            ).map(\.processIdentifier),
            [1, 2, 3]
        )
        XCTAssertEqual(
            ranker.rank(
                [
                    fixtureEntry(pid: 1, score: 100),
                    fixtureEntry(pid: 2, score: 112),
                    fixtureEntry(pid: 3, score: 126),
                ],
                atPublicationBoundary: true
            ).map(\.processIdentifier),
            [1, 3, 2]
        )

        XCTAssertEqual(
            ranker.rank(
                [
                    fixtureEntry(pid: 1, score: 100),
                    fixtureEntry(pid: 2, score: 112),
                    fixtureEntry(pid: 3, score: 80),
                ],
                atPublicationBoundary: true
            ).map(\.processIdentifier),
            [1, 2, 3]
        )
    }

    func testNilGenerationEntriesUseNameThenPIDTieBreaks() {
        var ranker = StableEnergyImpactRanker()
        let stateful = fixtureEntry(pid: 4, score: 1, name: "Last")
        let zulu = fixtureEntry(pid: 1, score: 100, hasGeneration: false, name: "Zulu")
        let alphaHighPID = fixtureEntry(pid: 3, score: 100, hasGeneration: false, name: "Alpha")
        let alphaLowPID = fixtureEntry(pid: 2, score: 100, hasGeneration: false, name: "alpha")

        XCTAssertEqual(
            ranker.rank(
                [zulu, alphaHighPID, stateful, alphaLowPID],
                atPublicationBoundary: true
            )
                .map(\.processIdentifier),
            [4, 2, 3, 1]
        )
    }

    func testSameNameAndPIDGenerationsUseStartTimeTieBreak() {
        var ranker = StableEnergyImpactRanker()
        let newer = fixtureEntry(pid: 1, score: 100, startTime: 20, name: "App")
        let older = fixtureEntry(pid: 1, score: 100, startTime: 10, name: "App")

        XCTAssertEqual(
            ranker.rank([newer, older], atPublicationBoundary: false)
                .map(\.identity.rootProcessStartAbsoluteTime),
            [10, 20]
        )
    }
}

private func fixtureEntry(
    pid: pid_t,
    score: Double,
    status: EnergyImpactStatus = .stable,
    hasRankingScore: Bool = true,
    startTime: UInt64? = nil,
    hasGeneration: Bool = true,
    name: String? = nil
) -> EnergyImpactEntry {
    let identity = EnergyImpactAppIdentity(
        rootProcessIdentifier: pid,
        rootProcessStartAbsoluteTime: hasGeneration ? startTime ?? UInt64(pid) : nil
    )
    return EnergyImpactEntry(
        identity: identity,
        name: name ?? "App \(pid)",
        bundleIdentifier: nil,
        bundleURL: nil,
        currentPowerMicrowatts: score,
        sustainedPowerMicrowatts: nil,
        rankingScore: hasRankingScore ? score : nil,
        trend: .steady,
        coverage: EnergyImpactCoverage(
            discoveredProcessCount: 1,
            readableProcessCount: 1,
            validProcessSeconds: 3,
            discoveredProcessSeconds: 3
        ),
        status: status
    )
}
