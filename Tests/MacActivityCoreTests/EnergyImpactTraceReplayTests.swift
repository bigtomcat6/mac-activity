import Darwin
import Foundation
import XCTest
@testable import MacActivityCore

final class EnergyImpactTraceReplayTests: XCTestCase {
    private func require<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func replay(
        _ factory: () -> EnergyImpactTraceFixture
    ) async throws -> [[EnergyImpactEntry]] {
        let fixture = factory()
        let lease = try require(
            await fixture.sampler.beginSession(.init(generation: 1))
        )
        var publications: [[EnergyImpactEntry]] = []
        for _ in 0..<fixture.observationCount {
            guard let publication = await fixture.sampler.observe(
                lease: lease,
                apps: fixture.apps,
                limit: fixture.limit
            ) else {
                await fixture.sampler.endSession(lease)
                XCTFail("Expected every ordered trace observation to publish")
                return publications
            }
            publications.append(publication.entries)
        }
        await fixture.sampler.endSession(lease)
        return publications
    }

    func testBurstTracePreservesIntegratedSustainedEnergy() async throws {
        let powers = Array(repeating: 0.0, count: 20)
            + Array(repeating: 1_000.0, count: 10)
            + Array(repeating: 0.0, count: 30)
        let publications = try await replay {
            singleRootTraceFixture(powers: powers)
        }
        let integratedSustainedEnergy = publications.compactMap {
            $0.first?.sustainedPowerMicrowatts
        }.reduce(0, +)

        XCTAssertEqual(
            integratedSustainedEnergy,
            10_000,
            accuracy: 1_000
        )
    }

    func testFalseSpikeTraceSuppressesAtLeastSeventyPercentOfRawExcess() async throws {
        let powers = Array(repeating: 100.0, count: 20)
            + [1_000]
            + Array(repeating: 100.0, count: 10)
        let publications = try await replay {
            singleRootTraceFixture(powers: powers)
        }
        let atSpike = try require(publications[21].first?.currentPowerMicrowatts)
        let filteredExcess = atSpike - 100
        let rawExcess = 1_000.0 - 100

        XCTAssertLessThanOrEqual(filteredExcess, rawExcess * 0.3)
    }

    func testSeparatedPairRanksHigherSeriesAboveLowerSeriesAfterWarmup() async throws {
        let noise = [-8.0, 6, -4, 8, -6, 4]
        let seriesA = (0..<60).map { 100 + noise[$0 % noise.count] }
        let seriesB = (0..<60).map { 120 + noise[$0 % noise.count] }
        let publications = try await replay {
            multiRootTraceFixture(seriesByPID: [100: seriesA, 200: seriesB])
        }
        let rankedPublications = publications.dropFirst(15)
        let higherFirstCount = rankedPublications.filter {
            $0.first?.processIdentifier == 200
        }.count

        XCTAssertGreaterThan(
            Double(higherFirstCount) / Double(rankedPublications.count),
            0.95
        )
    }

    func testStableTopFiveHasAdjacentPublicationKendallTauAbovePointNine() async throws {
        let noise = [-4.0, 3, -2, 4, -3, 2]
        let bases = [140.0, 130, 120, 110, 100]
        let series = Dictionary(uniqueKeysWithValues: bases.enumerated().map {
            index, base in
            (
                pid_t(100 + index),
                (0..<60).map { base + noise[$0 % noise.count] }
            )
        })
        let publications = try await replay {
            multiRootTraceFixture(seriesByPID: series, limit: 5)
        }
        let orders = publications.dropFirst(15).map {
            $0.map(\.processIdentifier)
        }
        let taus = zip(orders, orders.dropFirst()).map(kendallTau)

        XCTAssertGreaterThan(
            taus.reduce(0, +) / Double(taus.count),
            0.9
        )
    }

    func testIrregularCumulativeEnergyReconstructsConstantPower() async throws {
        let intervalCycle = [0.5, 1.0, 1.7]
        var intervals: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        var index = 0
        while elapsed + intervalCycle[index % intervalCycle.count] <= 60 {
            let interval = intervalCycle[index % intervalCycle.count]
            intervals.append(interval)
            elapsed += interval
            index += 1
        }
        let publications = try await replay {
            singleRootTraceFixture(
                powers: Array(repeating: 100, count: intervals.count),
                intervals: intervals
            )
        }
        let reconstructed = zip(publications.dropFirst(), intervals).reduce(0.0) {
            partial, item in
            partial + (item.0.first?.currentPowerMicrowatts ?? 0) * item.1
        }

        XCTAssertEqual(reconstructed, 6_000, accuracy: 300)
    }

    func testLongGapTraceDropsOldEstimatorAndRankState() async throws {
        let times = (0...10).map { TimeInterval($0) } + [25]
        let readings = times.map { time in
            ProcessEnergyReadResult.success(traceReading(
                energyNanojoules: UInt64(time * 100_000),
                start: 10
            ))
        }
        let publications = try await replay {
            customTraceFixture(
                times: times,
                results: [100: readings],
                snapshotsByObservation: Array(
                    repeating: [],
                    count: times.count
                ),
                apps: [traceApp(pid: 100)]
            )
        }
        let afterGap = try require(publications.last?.first)

        XCTAssertEqual(afterGap.status, .collecting)
        XCTAssertNil(afterGap.currentPowerMicrowatts)
        XCTAssertNil(afterGap.sustainedPowerMicrowatts)
        XCTAssertNil(afterGap.rankingScore)
        XCTAssertEqual(afterGap.observedWindowSeconds, 0)
    }

    func testPIDGenerationReplacementSeedsEveryEstimatorIndependently() async throws {
        let times = (0...21).map { TimeInterval($0) }
        let old = (0...19).map { second in
            ProcessEnergyReadResult.success(traceReading(
                energyNanojoules: UInt64(second * 100_000),
                start: 10
            ))
        }
        let readings = old + [
            .success(traceReading(energyNanojoules: 0, start: 20)),
            .success(traceReading(energyNanojoules: 5_000, start: 20)),
        ]
        let publications = try await replay {
            customTraceFixture(
                times: times,
                results: [101: readings],
                snapshotsByObservation: Array(repeating: [], count: times.count),
                apps: [traceApp(pid: 101)]
            )
        }
        let replacement = try require(publications[20].first)
        let seeded = try require(publications[21].first)

        XCTAssertEqual(replacement.identity.rootProcessStartAbsoluteTime, 20)
        XCTAssertNil(replacement.currentPowerMicrowatts)
        XCTAssertNil(replacement.sustainedPowerMicrowatts)
        XCTAssertEqual(replacement.coverage.validProcessSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(replacement.coverage.discoveredProcessSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(replacement.observedWindowSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(seeded.identity.rootProcessStartAbsoluteTime, 20)
        XCTAssertEqual(try require(seeded.currentPowerMicrowatts), 5, accuracy: 0.001)
        XCTAssertEqual(try require(seeded.sustainedPowerMicrowatts), 5, accuracy: 0.001)
        XCTAssertEqual(seeded.observedWindowSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(seeded.status, .collecting)
    }

    func testOwnerChangeTraceAttributesTransitionContributionToNeitherRoot() async throws {
        let failures = Array(
            repeating: ProcessEnergyReadResult.failure(.permissionDenied),
            count: 2
        )
        let publications = try await replay {
            customTraceFixture(
                times: [0, 1],
                results: [
                    100: failures,
                    200: failures,
                    300: [
                        .success(traceReading(energyNanojoules: 0, start: 30)),
                        .success(traceReading(energyNanojoules: 100_000, start: 30)),
                    ],
                ],
                snapshotsByObservation: [
                    [.init(processIdentifier: 300, parentProcessIdentifier: 100)],
                    [.init(processIdentifier: 300, parentProcessIdentifier: 200)],
                ],
                apps: [traceApp(pid: 100), traceApp(pid: 200)],
                limit: 2
            )
        }

        XCTAssertTrue(publications[1].allSatisfy {
            $0.currentPowerMicrowatts == nil
                && $0.sustainedPowerMicrowatts == nil
                && $0.rankingScore == nil
        })
    }

    func testPartialTreeTraceReportsFiftyPercentPIDTimeWithoutFalseZero() async throws {
        let times = (0...16).map { TimeInterval($0) }
        let rootReadings = times.map { time in
            ProcessEnergyReadResult.success(traceReading(
                energyNanojoules: UInt64(time * 100_000),
                start: 10
            ))
        }
        let helperFailures = Array(
            repeating: ProcessEnergyReadResult.failure(.permissionDenied),
            count: times.count
        )
        let snapshots = Array(
            repeating: [
                ProcessParentSnapshot(
                    processIdentifier: 101,
                    parentProcessIdentifier: 100
                ),
            ],
            count: times.count
        )
        let publications = try await replay {
            customTraceFixture(
                times: times,
                results: [100: rootReadings, 101: helperFailures],
                snapshotsByObservation: snapshots,
                apps: [traceApp(pid: 100)]
            )
        }
        let row = try require(publications.last?.first)

        XCTAssertEqual(row.status, .partial)
        XCTAssertEqual(row.coverage.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(try require(row.currentPowerMicrowatts), 100, accuracy: 0.001)
    }

    func testRecoveredHelperTraceUsesFullGapEnergyAndPIDTimeOnce() async throws {
        let times = (0...10).map { TimeInterval($0) }
        let rootReadings = times.map { time in
            ProcessEnergyReadResult.success(traceReading(
                energyNanojoules: UInt64(time * 100_000),
                start: 10
            ))
        }
        let helperReadings: [ProcessEnergyReadResult] = [
            .success(traceReading(energyNanojoules: 0, start: 11)),
            .success(traceReading(energyNanojoules: 200_000, start: 11)),
            .success(traceReading(energyNanojoules: 400_000, start: 11)),
            .success(traceReading(energyNanojoules: 600_000, start: 11)),
        ] + [
            .success(traceReading(energyNanojoules: 2_000_000, start: 11)),
        ]
        let helperPresent = [
                ProcessParentSnapshot(
                    processIdentifier: 101,
                    parentProcessIdentifier: 100
                ),
            ]
        let snapshots = Array(repeating: helperPresent, count: 4)
            + Array(repeating: [], count: 6)
            + [helperPresent]
        let publications = try await replay {
            customTraceFixture(
                times: times,
                results: [100: rootReadings, 101: helperReadings],
                snapshotsByObservation: snapshots,
                apps: [traceApp(pid: 100)]
            )
        }
        let recovered = try require(publications.last?.first)

        XCTAssertEqual(
            try require(recovered.sustainedPowerMicrowatts),
            300,
            accuracy: 0.001
        )
        XCTAssertEqual(recovered.coverage.validProcessSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(recovered.coverage.discoveredProcessSeconds, 14, accuracy: 0.001)
        XCTAssertEqual(recovered.coverage.fraction, 1, accuracy: 0.001)
    }

    func testAllPIDRecoveryTraceNeverDividesRecoveredEnergyByOnlyFinalInterval() async throws {
        let times = (0...6).map { TimeInterval($0) }
        let results: [ProcessEnergyReadResult] = [
            .success(traceReading(energyNanojoules: 0, start: 10)),
        ] + Array(
            repeating: .failure(.permissionDenied),
            count: 5
        ) + [
            .success(traceReading(energyNanojoules: 6_000, start: 10)),
        ]
        let publications = try await replay {
            customTraceFixture(
                times: times,
                results: [100: results],
                snapshotsByObservation: Array(repeating: [], count: times.count),
                apps: [traceApp(pid: 100)]
            )
        }
        let recovered = try require(publications.last?.first)

        XCTAssertEqual(
            try require(recovered.sustainedPowerMicrowatts),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(recovered.observedWindowSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(recovered.coverage.fraction, 1, accuracy: 0.001)
        XCTAssertNotEqual(recovered.sustainedPowerMicrowatts, 6)
    }

    func testAlternatingQuantizationNoiseLowersCVByAtLeastHalf() throws {
        let raw = Array(repeating: [70.0, 130.0], count: 20).flatMap { $0 }
        var ema = TimeAwareEnergyEMA(halfLifeSeconds: 4)
        let filtered = try raw.map { try XCTUnwrap(ema.update(value: $0, elapsedSeconds: 3)) }
        let rawCV = coefficientOfVariation(Array(raw.dropFirst(5)))
        let filteredCV = coefficientOfVariation(Array(filtered.dropFirst(5)))

        print(
            "energy-trace raw-cv=\(rawCV) filtered-cv=\(filteredCV) "
                + "reduction=\(1 - filteredCV / rawCV)"
        )
        XCTAssertLessThanOrEqual(filteredCV, rawCV * 0.5)
    }

    func testCrossingNearTieDoesNotThrashButTwentyFivePercentLeadMovesImmediately() {
        var ranker = StableEnergyImpactRanker()
        var swaps = 0
        var previous: [pid_t] = []
        for index in 0..<20 {
            let a = traceEntry(pid: 1, score: index.isMultiple(of: 2) ? 100 : 109)
            let b = traceEntry(pid: 2, score: index.isMultiple(of: 2) ? 109 : 100)
            let order = ranker.rank([a, b], atPublicationBoundary: true).map(\.processIdentifier)
            if previous.isEmpty == false, previous != order { swaps += 1 }
            previous = order
        }
        XCTAssertEqual(swaps, 0)

        var immediateRanker = StableEnergyImpactRanker()
        _ = immediateRanker.rank(
            [traceEntry(pid: 1, score: 100), traceEntry(pid: 2, score: 90)],
            atPublicationBoundary: true
        )
        let decisive = traceEntry(pid: 2, score: 130)
        let baseline = traceEntry(pid: 1, score: 100)
        let decisiveFirst = immediateRanker.rank(
            [baseline, decisive],
            atPublicationBoundary: true
        ).first?.processIdentifier

        print("energy-trace near-tie-swaps=\(swaps) decisive-first-pid=\(decisiveFirst ?? -1)")
        XCTAssertEqual(decisiveFirst, 2)
    }
}

private struct EnergyImpactTraceFixture {
    let sampler: EnergyImpactSampler
    let apps: [EnergyImpactAppSnapshot]
    let observationCount: Int
    let limit: Int
}

private func singleRootTraceFixture(
    powers: [Double],
    intervals: [TimeInterval]? = nil
) -> EnergyImpactTraceFixture {
    multiRootTraceFixture(
        seriesByPID: [100: powers],
        intervals: intervals,
        limit: 1
    )
}

private func multiRootTraceFixture(
    seriesByPID: [pid_t: [Double]],
    intervals suppliedIntervals: [TimeInterval]? = nil,
    limit: Int = 20
) -> EnergyImpactTraceFixture {
    let sampleCount = seriesByPID.values.first?.count ?? 0
    precondition(seriesByPID.values.allSatisfy { $0.count == sampleCount })
    let intervals = suppliedIntervals
        ?? Array(repeating: 1, count: sampleCount)
    precondition(intervals.count == sampleCount)
    var times: [TimeInterval] = [0]
    for interval in intervals {
        times.append(times.last! + interval)
    }
    let results = Dictionary(uniqueKeysWithValues: seriesByPID.map {
        processIdentifier, powers in
        var cumulativeNanojoules: UInt64 = 0
        var readings: [ProcessEnergyReadResult] = [
            .success(traceReading(
                energyNanojoules: 0,
                start: UInt64(processIdentifier)
            )),
        ]
        for (power, interval) in zip(powers, intervals) {
            cumulativeNanojoules += UInt64(
                (power * interval * 1_000).rounded()
            )
            readings.append(.success(traceReading(
                energyNanojoules: cumulativeNanojoules,
                start: UInt64(processIdentifier)
            )))
        }
        return (processIdentifier, readings)
    })
    let apps = seriesByPID.keys.sorted().map(traceApp)
    return customTraceFixture(
        times: times,
        results: results,
        snapshotsByObservation: Array(repeating: [], count: times.count),
        apps: apps,
        limit: limit
    )
}

private func customTraceFixture(
    times: [TimeInterval],
    results: [pid_t: [ProcessEnergyReadResult]],
    snapshotsByObservation: [[ProcessParentSnapshot]],
    apps: [EnergyImpactAppSnapshot],
    limit: Int = 20
) -> EnergyImpactTraceFixture {
    EnergyImpactTraceFixture(
        sampler: EnergyImpactSampler(
            reader: EnergyImpactTraceReader(results: results),
            processSnapshotReader: EnergyImpactTraceSnapshotReader(
                snapshotsByObservation: snapshotsByObservation
            ),
            clock: EnergyImpactTraceClock(times: times)
        ),
        apps: apps,
        observationCount: times.count,
        limit: limit
    )
}

private func traceReading(
    energyNanojoules: UInt64,
    start: UInt64
) -> ProcessEnergyReading {
    ProcessEnergyReading(
        energyNanojoules: energyNanojoules,
        processStartAbsoluteTime: start
    )
}

private func traceApp(pid: pid_t) -> EnergyImpactAppSnapshot {
    EnergyImpactAppSnapshot(
        processIdentifier: pid,
        name: "App \(pid)",
        bundleIdentifier: nil,
        bundleURL: nil
    )
}

private func kendallTau(_ lhs: [pid_t], _ rhs: [pid_t]) -> Double {
    guard lhs.count == rhs.count, lhs.count > 1 else { return 1 }
    let rightIndex = Dictionary(uniqueKeysWithValues: rhs.enumerated().map {
        ($0.element, $0.offset)
    })
    var concordant = 0
    var discordant = 0
    for leftIndex in lhs.indices {
        for otherIndex in lhs.indices where otherIndex > leftIndex {
            guard let first = rightIndex[lhs[leftIndex]],
                  let second = rightIndex[lhs[otherIndex]] else {
                continue
            }
            if first < second {
                concordant += 1
            } else {
                discordant += 1
            }
        }
    }
    return Double(concordant - discordant)
        / Double(concordant + discordant)
}

private final class EnergyImpactTraceClock: EnergyImpactClock, @unchecked Sendable {
    private let lock = NSLock()
    private var times: [TimeInterval]

    init(times: [TimeInterval]) {
        self.times = times
    }

    func nowSeconds() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        precondition(times.isEmpty == false, "Trace clock exhausted")
        return times.removeFirst()
    }
}

private final class EnergyImpactTraceReader: ProcessEnergyReadingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [pid_t: [ProcessEnergyReadResult]]

    init(results: [pid_t: [ProcessEnergyReadResult]]) {
        self.results = results
    }

    func reading(for processIdentifier: pid_t) -> ProcessEnergyReadResult {
        lock.lock()
        defer { lock.unlock() }
        guard var processResults = results[processIdentifier],
              processResults.isEmpty == false else {
            return .failure(.other(0))
        }
        let result = processResults.removeFirst()
        results[processIdentifier] = processResults
        return result
    }
}

private final class EnergyImpactTraceSnapshotReader: ProcessParentSnapshotReading, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotsByObservation: [[ProcessParentSnapshot]]

    init(snapshotsByObservation: [[ProcessParentSnapshot]]) {
        self.snapshotsByObservation = snapshotsByObservation
    }

    func snapshots() -> [ProcessParentSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        precondition(
            snapshotsByObservation.isEmpty == false,
            "Trace ownership snapshots exhausted"
        )
        return snapshotsByObservation.removeFirst()
    }
}

private func coefficientOfVariation(_ values: [Double]) -> Double {
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    return sqrt(variance) / mean
}

private func traceEntry(pid: pid_t, score: Double) -> EnergyImpactEntry {
    EnergyImpactEntry(
        identity: .init(
            rootProcessIdentifier: pid,
            rootProcessStartAbsoluteTime: UInt64(pid)
        ),
        name: "App \(pid)",
        bundleIdentifier: nil,
        bundleURL: nil,
        currentPowerMicrowatts: score,
        sustainedPowerMicrowatts: nil,
        rankingScore: score,
        trend: .steady,
        coverage: .init(
            discoveredProcessCount: 1,
            readableProcessCount: 1,
            validProcessSeconds: 3,
            discoveredProcessSeconds: 3
        ),
        status: .stable
    )
}
