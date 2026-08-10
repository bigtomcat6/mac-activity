import XCTest
@testable import MacActivityCore

final class EnergyImpactPublicationStateTests: XCTestCase {
    func testAlreadyEstimatedRowsAreNotSmoothedAgain() throws {
        var state = EnergyImpactPublicationState()
        let first = state.publish(
            [publicationEntry(power: 100)],
            at: 3,
            limit: 20
        )
        let second = state.publish(
            [publicationEntry(power: 400)],
            at: 6,
            limit: 20
        )

        XCTAssertEqual(try XCTUnwrap(first.first?.currentPowerMicrowatts), 100)
        XCTAssertEqual(try XCTUnwrap(second.first?.currentPowerMicrowatts), 400)
    }

    func testAllCandidatesAdvanceBeforeTopTwentyTruncation() throws {
        var state = EnergyImpactPublicationState()
        let steady = (1...20).map {
            publicationEntry(pid: pid_t($0), power: 50)
        }
        _ = state.publish(
            steady + [publicationEntry(pid: 21, power: 0)],
            at: 3,
            limit: 20
        )
        _ = state.publish(
            steady + [publicationEntry(pid: 21, power: 100)],
            at: 6,
            limit: 20
        )

        let secondLead = state.publish(
            steady + [publicationEntry(pid: 21, power: 100)],
            at: 9,
            limit: 20
        )

        XCTAssertEqual(secondLead.count, 20)
        XCTAssertTrue(secondLead.contains { $0.processIdentifier == 21 })
        XCTAssertEqual(
            try XCTUnwrap(
                secondLead.first { $0.processIdentifier == 21 }?
                    .currentPowerMicrowatts
            ),
            100,
            accuracy: 0.000_001
        )
    }

    func testStaleEntryInterruptsRankConfirmation() {
        var state = EnergyImpactPublicationState()
        let orders = [
            state.publish(
                [publicationEntry(pid: 1, power: 100), publicationEntry(pid: 2, power: 90)],
                at: 3,
                limit: 20
            ),
            state.publish(
                [publicationEntry(pid: 1, power: 100), publicationEntry(pid: 2, power: 112)],
                at: 6,
                limit: 20
            ),
            state.publish(
                [
                    publicationEntry(pid: 1, power: 100),
                    publicationEntry(pid: 2, power: 112, status: .stale),
                ],
                at: 9,
                limit: 20
            ),
            state.publish(
                [publicationEntry(pid: 1, power: 100), publicationEntry(pid: 2, power: 112)],
                at: 12,
                limit: 20
            ),
            state.publish(
                [publicationEntry(pid: 1, power: 100), publicationEntry(pid: 2, power: 112)],
                at: 15,
                limit: 20
            ),
        ].map { $0.map(\.processIdentifier) }

        XCTAssertEqual(orders, [[1, 2], [1, 2], [1, 2], [1, 2], [2, 1]])
    }

    func testNonfinitePowerPublishesUnavailableWithoutRewritingRecovery() throws {
        var state = EnergyImpactPublicationState()
        _ = state.publish([publicationEntry(power: 100)], at: 3, limit: 20)

        let invalid = try XCTUnwrap(
            state.publish([publicationEntry(power: .nan)], at: 6, limit: 20).first
        )

        XCTAssertEqual(invalid.status, .unavailable)
        XCTAssertNil(invalid.currentPowerMicrowatts)
        XCTAssertNil(invalid.sustainedPowerMicrowatts)
        XCTAssertNil(invalid.rankingScore)

        let recovered = state.publish([publicationEntry(power: 0)], at: 9, limit: 20)
        XCTAssertEqual(
            try XCTUnwrap(recovered.first?.currentPowerMicrowatts),
            0,
            accuracy: 0.000_001
        )
    }

    func testStableEntryWithMissingNumericFieldsPublishesUnavailable() throws {
        var state = EnergyImpactPublicationState()

        let row = try XCTUnwrap(
            state.publish(
                [publicationEntry(power: nil, status: .stable)],
                at: 3,
                limit: 20
            ).first
        )

        XCTAssertEqual(row.status, .unavailable)
        XCTAssertNil(row.currentPowerMicrowatts)
        XCTAssertNil(row.sustainedPowerMicrowatts)
        XCTAssertNil(row.rankingScore)
    }

    func testInvalidStaleNumericsAreStrippedWithoutChangingStaleStatus() throws {
        var state = EnergyImpactPublicationState()

        let row = try XCTUnwrap(
            state.publish(
                [publicationEntry(power: .nan, status: .stale)],
                at: 3,
                limit: 20
            ).first
        )

        XCTAssertEqual(row.status, .stale)
        XCTAssertNil(row.currentPowerMicrowatts)
        XCTAssertNil(row.sustainedPowerMicrowatts)
        XCTAssertNil(row.rankingScore)
    }

    func testNonfiniteClockPreservesCollectingStaleAndUnavailableButInvalidatesStableAndPartial() throws {
        var state = EnergyImpactPublicationState()

        let rows = state.publish(
            [
                publicationEntry(pid: 1, power: nil, status: .collecting),
                publicationEntry(pid: 2, power: 100, status: .stale),
                publicationEntry(pid: 3, power: nil, status: .unavailable),
                publicationEntry(pid: 4, power: 100, status: .stable),
                publicationEntry(pid: 5, power: 100, status: .partial),
            ],
            at: .nan,
            limit: 20
        )
        let byPID = Dictionary(uniqueKeysWithValues: rows.map {
            ($0.processIdentifier, $0)
        })

        XCTAssertEqual(try XCTUnwrap(byPID[1]).status, .collecting)
        XCTAssertEqual(try XCTUnwrap(byPID[2]).status, .stale)
        XCTAssertEqual(try XCTUnwrap(byPID[2]).currentPowerMicrowatts, 100)
        XCTAssertEqual(try XCTUnwrap(byPID[3]).status, .unavailable)
        XCTAssertEqual(try XCTUnwrap(byPID[4]).status, .unavailable)
        XCTAssertNil(try XCTUnwrap(byPID[4]).currentPowerMicrowatts)
        XCTAssertEqual(try XCTUnwrap(byPID[5]).status, .unavailable)
        XCTAssertNil(try XCTUnwrap(byPID[5]).currentPowerMicrowatts)
    }

    func testDuplicateGenerationMakesOnlyTheLaterDuplicateUnavailable() throws {
        var state = EnergyImpactPublicationState()

        let rows = state.publish(
            [
                publicationEntry(pid: 101, power: 10, startTime: 10),
                publicationEntry(pid: 101, power: 20, startTime: 10),
            ],
            at: 3,
            limit: 20
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.filter { $0.status == .stable }.count, 1)
        let retained = try XCTUnwrap(rows.first { $0.status == .stable })
        XCTAssertEqual(retained.currentPowerMicrowatts, 10)
        let unavailable = try XCTUnwrap(rows.first { $0.status == .unavailable })
        XCTAssertNil(unavailable.currentPowerMicrowatts)
        XCTAssertNil(unavailable.sustainedPowerMicrowatts)
        XCTAssertNil(unavailable.rankingScore)
    }

    func testLongGapResetsPriorRankOrder() {
        var state = EnergyImpactPublicationState()
        _ = state.publish(
            [publicationEntry(pid: 1, power: 100), publicationEntry(pid: 2, power: 90)],
            at: 3,
            limit: 20
        )
        _ = state.publish(
            [publicationEntry(pid: 1, power: 100), publicationEntry(pid: 2, power: 112)],
            at: 6,
            limit: 20
        )
        let afterGap = state.publish(
            [publicationEntry(pid: 1, power: 100), publicationEntry(pid: 2, power: 112)],
            at: 17,
            limit: 20
        )

        XCTAssertEqual(afterGap.map(\.processIdentifier), [2, 1])
    }

    func testPIDReuseStartsReplacementGenerationFromItsOwnRawValue() throws {
        var state = EnergyImpactPublicationState()
        _ = state.publish(
            [publicationEntry(power: 0, startTime: 10)],
            at: 3,
            limit: 20
        )
        _ = state.publish(
            [publicationEntry(power: 100, startTime: 10)],
            at: 6,
            limit: 20
        )

        let replacement = state.publish(
            [publicationEntry(power: 5, startTime: 20)],
            at: 9,
            limit: 20
        )

        XCTAssertEqual(try XCTUnwrap(replacement.first?.identity.rootProcessStartAbsoluteTime), 20)
        XCTAssertEqual(try XCTUnwrap(replacement.first?.currentPowerMicrowatts), 5)
    }

    func testMissingGenerationPublishesOnlyCollectingCurrentIntervalData() throws {
        var state = EnergyImpactPublicationState()
        _ = state.publish(
            [publicationEntry(power: 0, startTime: nil)],
            at: 3,
            limit: 20
        )
        _ = state.publish(
            [publicationEntry(power: 100, startTime: nil)],
            at: 6,
            limit: 20
        )

        let third = state.publish(
            [publicationEntry(power: 0, startTime: nil)],
            at: 9,
            limit: 20
        )

        XCTAssertEqual(try XCTUnwrap(third.first?.status), .collecting)
        XCTAssertEqual(try XCTUnwrap(third.first?.currentPowerMicrowatts), 0)
        XCTAssertNil(try XCTUnwrap(third.first).sustainedPowerMicrowatts)
        XCTAssertNil(try XCTUnwrap(third.first).rankingScore)
    }

    func testMissingGenerationIsUnrankedAndObservedWindowIsForwarded() throws {
        var state = EnergyImpactPublicationState()
        let rows = state.publish(
            [
                publicationEntry(
                    pid: 1,
                    power: 1,
                    observedWindowSeconds: 15
                ),
                publicationEntry(
                    pid: 2,
                    power: 1_000,
                    startTime: nil,
                    observedWindowSeconds: 3
                ),
            ],
            at: 3,
            limit: 20
        )

        XCTAssertEqual(rows.map(\.processIdentifier), [1, 2])
        let missingGeneration = try XCTUnwrap(rows.last)
        XCTAssertEqual(missingGeneration.status, .collecting)
        XCTAssertEqual(missingGeneration.currentPowerMicrowatts, 1_000)
        XCTAssertNil(missingGeneration.sustainedPowerMicrowatts)
        XCTAssertNil(missingGeneration.rankingScore)
        XCTAssertEqual(missingGeneration.observedWindowSeconds, 3)
    }

    func testUnavailableSanitizerRetainsObservedWindowContext() throws {
        var state = EnergyImpactPublicationState()
        let row = try XCTUnwrap(state.publish(
            [publicationEntry(
                power: .nan,
                observedWindowSeconds: 12
            )],
            at: 3,
            limit: 20
        ).first)

        XCTAssertEqual(row.status, .unavailable)
        XCTAssertNil(row.currentPowerMicrowatts)
        XCTAssertNil(row.sustainedPowerMicrowatts)
        XCTAssertNil(row.rankingScore)
        XCTAssertEqual(row.observedWindowSeconds, 12)
    }
}

private func publicationEntry(
    pid: pid_t = 101,
    power: Double?,
    startTime: UInt64? = 1,
    status: EnergyImpactStatus = .stable,
    observedWindowSeconds: TimeInterval = 0
) -> EnergyImpactEntry {
    EnergyImpactEntry(
        identity: EnergyImpactAppIdentity(
            rootProcessIdentifier: pid,
            rootProcessStartAbsoluteTime: startTime
        ),
        name: "App \(pid)",
        bundleIdentifier: "com.example.app-\(pid)",
        bundleURL: nil,
        currentPowerMicrowatts: power,
        sustainedPowerMicrowatts: power,
        rankingScore: power,
        trend: .steady,
        coverage: EnergyImpactCoverage(
            discoveredProcessCount: 1,
            readableProcessCount: 1,
            validProcessSeconds: status == .stable || status == .partial ? 3 : 0,
            discoveredProcessSeconds: 3
        ),
        status: status,
        observedWindowSeconds: observedWindowSeconds
    )
}
