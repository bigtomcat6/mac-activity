import Darwin
import Foundation
import XCTest
@testable import MacActivityCore

final class EnergyImpactTraceReplayTests: XCTestCase {
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
