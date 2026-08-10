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

    func testNewProcessGenerationUsesAnIndependentAccumulator() throws {
        var old = EnergyImpactAccumulator(configuration: .production)
        var replacement = EnergyImpactAccumulator(configuration: .production)

        let oldEstimate = old.observe(
            sample: .init(
                endTimeSeconds: 3,
                durationSeconds: 3,
                contributions: [
                    contribution(pid: 101, start: 0, end: 3, energy: 300),
                ],
                discoveredProcessSeconds: 3
            ),
            rawPowerMicrowatts: 100
        )
        let replacementEstimate = replacement.observe(
            sample: .init(
                endTimeSeconds: 6,
                durationSeconds: 3,
                contributions: [
                    contribution(pid: 101, start: 3, end: 6, energy: 15),
                ],
                discoveredProcessSeconds: 3
            ),
            rawPowerMicrowatts: 5
        )

        XCTAssertEqual(try XCTUnwrap(oldEstimate).fast, 100)
        XCTAssertEqual(try XCTUnwrap(replacementEstimate).fast, 5)
    }

    func testAccumulatorCommitsPendingWallAndPIDTimeWithRecoveredEnergy() throws {
        var accumulator = EnergyImpactAccumulator(configuration: .production)

        XCTAssertNil(accumulator.observe(
            sample: .init(
                endTimeSeconds: 3,
                durationSeconds: 3,
                contributions: [],
                discoveredProcessSeconds: 3
            ),
            rawPowerMicrowatts: nil
        ))
        let recovered = try XCTUnwrap(accumulator.observe(
            sample: .init(
                endTimeSeconds: 6,
                durationSeconds: 3,
                contributions: [
                    contribution(pid: 101, start: 0, end: 6, energy: 6),
                ],
                discoveredProcessSeconds: 3
            ),
            rawPowerMicrowatts: 1
        ))

        XCTAssertEqual(try XCTUnwrap(recovered.sustained), 1, accuracy: 0.001)
        XCTAssertEqual(recovered.coverage, 1, accuracy: 0.001)
        XCTAssertEqual(recovered.validProcessSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(recovered.discoveredProcessSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(recovered.observedWallSeconds, 6, accuracy: 0.001)
    }

    func testTrendTreatsExactFifteenPercentBoundariesAsSteady() {
        let sustained = 100.0
        let fractionalSustained = 9.0

        XCTAssertEqual(
            EnergyImpactAccumulator.trend(
                fast: sustained * 1.15,
                sustained: sustained
            ),
            .steady
        )
        XCTAssertEqual(
            EnergyImpactAccumulator.trend(
                fast: sustained * 0.85,
                sustained: sustained
            ),
            .steady
        )
        XCTAssertEqual(
            EnergyImpactAccumulator.trend(
                fast: fractionalSustained * 0.85,
                sustained: fractionalSustained
            ),
            .steady
        )
        XCTAssertEqual(
            EnergyImpactAccumulator.trend(fast: 115.001, sustained: 100),
            .rising
        )
        XCTAssertEqual(
            EnergyImpactAccumulator.trend(fast: 84.999, sustained: 100),
            .falling
        )
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

    func testThirtySecondWindowWeightsIrregularDurations() throws {
        var window = TimeWeightedEnergyWindow(windowSeconds: 30)
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 1,
            durationSeconds: 1,
            contributions: [contribution(pid: 1, start: 0, end: 1, energy: 100)],
            discoveredProcessSeconds: 1
        )))
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 4,
            durationSeconds: 3,
            contributions: [contribution(pid: 1, start: 1, end: 4, energy: 900)],
            discoveredProcessSeconds: 3
        )))

        XCTAssertEqual(try XCTUnwrap(window.powerMicrowatts), 250, accuracy: 0.001)
        XCTAssertEqual(window.totalDurationSeconds, 4, accuracy: 0.001)
        XCTAssertEqual(window.validProcessSeconds, 4, accuracy: 0.001)
    }

    func testWindowTrimsOnlyTheExpiredFractionOfAnInterval() {
        var window = TimeWeightedEnergyWindow(windowSeconds: 30)
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 10,
            durationSeconds: 10,
            contributions: [contribution(pid: 1, start: 0, end: 10, energy: 1_000)],
            discoveredProcessSeconds: 10
        )))
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 35,
            durationSeconds: 25,
            contributions: [contribution(pid: 1, start: 10, end: 35, energy: 5_000)],
            discoveredProcessSeconds: 25
        )))

        XCTAssertEqual(window.totalEnergyMicrojoules, 5_500, accuracy: 0.001)
        XCTAssertEqual(window.totalDurationSeconds, 30, accuracy: 0.001)
    }

    func testWindowRejectsNonMonotonicSampleEndTimesWithoutCorruptingRetainedSamples() {
        var window = TimeWeightedEnergyWindow(windowSeconds: 30)
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 10,
            durationSeconds: 10,
            contributions: [contribution(pid: 1, start: 0, end: 10, energy: 1_000)],
            discoveredProcessSeconds: 10
        )))

        XCTAssertFalse(window.append(.init(
            endTimeSeconds: 9,
            durationSeconds: 1,
            contributions: [contribution(pid: 1, start: 8, end: 9, energy: 900)],
            discoveredProcessSeconds: 1
        )))

        XCTAssertEqual(window.totalEnergyMicrojoules, 1_000, accuracy: 0.001)
        XCTAssertEqual(window.totalDurationSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(window.validProcessSeconds, 10, accuracy: 0.001)
    }

    func testWindowPreservesPIDTimeAndCoverageAfterFractionalTrim() {
        var window = TimeWeightedEnergyWindow(windowSeconds: 30)
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 10,
            durationSeconds: 10,
            contributions: [contribution(pid: 1, start: 0, end: 10, energy: 1_000)],
            discoveredProcessSeconds: 20
        )))
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 35,
            durationSeconds: 25,
            contributions: [contribution(pid: 2, start: 10, end: 35, energy: 2_500)],
            discoveredProcessSeconds: 50
        )))

        XCTAssertEqual(window.totalDurationSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(window.validProcessSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(window.discoveredDurationSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(window.coverage, 0.5, accuracy: 0.001)
    }

    func testWindowRejectsInvalidNumericSamplesWithoutMutatingRetainedSamples() {
        var window = TimeWeightedEnergyWindow(windowSeconds: 30)
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 10,
            durationSeconds: 10,
            contributions: [contribution(pid: 1, start: 0, end: 10, energy: 1_000)],
            discoveredProcessSeconds: 10
        )))

        XCTAssertFalse(window.append(.init(
            endTimeSeconds: .nan,
            durationSeconds: 1,
            contributions: [],
            discoveredProcessSeconds: 0
        )))
        XCTAssertFalse(window.append(.init(
            endTimeSeconds: 11,
            durationSeconds: 1,
            contributions: [contribution(pid: 1, start: 10, end: 11, energy: .nan)],
            discoveredProcessSeconds: 1
        )))
        XCTAssertFalse(window.append(.init(
            endTimeSeconds: 11,
            durationSeconds: 1,
            contributions: [],
            discoveredProcessSeconds: .infinity
        )))

        XCTAssertEqual(window.totalEnergyMicrojoules, 1_000, accuracy: 0.001)
        XCTAssertEqual(window.totalDurationSeconds, 10, accuracy: 0.001)
    }

    func testWindowTreatsUnreadableIntervalsAsMissingPower() {
        var window = TimeWeightedEnergyWindow(windowSeconds: 30)
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 10,
            durationSeconds: 10,
            contributions: [],
            discoveredProcessSeconds: 10
        )))

        XCTAssertNil(window.powerMicrowatts)
    }

    func testWindowPreservesReadableZeroEnergyAsNumericZero() throws {
        var window = TimeWeightedEnergyWindow(windowSeconds: 30)
        XCTAssertTrue(window.append(.init(
            endTimeSeconds: 10,
            durationSeconds: 10,
            contributions: [contribution(pid: 1, start: 0, end: 10, energy: 0)],
            discoveredProcessSeconds: 10
        )))

        XCTAssertEqual(try XCTUnwrap(window.powerMicrowatts), 0, accuracy: 0.001)
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

private func contribution(
    pid: pid_t,
    start: TimeInterval,
    end: TimeInterval,
    energy: Double
) -> ProcessEnergyContribution {
    ProcessEnergyContribution(
        processIdentity: .init(
            processIdentifier: pid,
            processStartAbsoluteTime: UInt64(pid)
        ),
        ownerRootProcessIdentifier: 100,
        startTimeSeconds: start,
        endTimeSeconds: end,
        energyMicrojoules: energy
    )
}
