import XCTest
@testable import MacActivityCore

@MainActor
final class MetricsStoreHistoryTests: XCTestCase {
    func testBucketAveragedSamplesUseChronologicalMeans() {
        let base = Date(timeIntervalSince1970: 0)
        let samples = [
            MetricHistorySample(timestamp: base.addingTimeInterval(0), primaryValue: 0, secondaryValue: 0),
            MetricHistorySample(timestamp: base.addingTimeInterval(10), primaryValue: 10, secondaryValue: 2),
            MetricHistorySample(timestamp: base.addingTimeInterval(20), primaryValue: 20, secondaryValue: 4),
            MetricHistorySample(timestamp: base.addingTimeInterval(30), primaryValue: 30, secondaryValue: 6),
            MetricHistorySample(timestamp: base.addingTimeInterval(40), primaryValue: 40, secondaryValue: 8),
            MetricHistorySample(timestamp: base.addingTimeInterval(50), primaryValue: 50, secondaryValue: 10),
        ]

        let aggregated = MetricsHistory.bucketAveragedSamples(samples, targetCount: 3)

        XCTAssertEqual(aggregated.map(\.timestamp), [
            base.addingTimeInterval(10),
            base.addingTimeInterval(30),
            base.addingTimeInterval(50),
        ])
        XCTAssertEqual(aggregated.map(\.primaryValue), [5, 25, 45])
        XCTAssertEqual(aggregated.map { $0.secondaryValue ?? -1 }, [1, 5, 9])
        XCTAssertEqual(aggregated.map(\.sampleCount), [2, 2, 2])
    }

    func testBucketAveragedSamplesPreserveWeightedMeans() {
        let base = Date(timeIntervalSince1970: 0)
        let samples = [
            MetricHistorySample(
                timestamp: base.addingTimeInterval(10),
                primaryValue: 10,
                secondaryValue: 2,
                sampleCount: 3
            ),
            MetricHistorySample(
                timestamp: base.addingTimeInterval(20),
                primaryValue: 40,
                secondaryValue: 8,
                sampleCount: 1
            ),
        ]

        let aggregated = MetricsHistory.bucketAveragedSamples(samples, targetCount: 1)

        XCTAssertEqual(aggregated.map(\.primaryValue), [17.5])
        XCTAssertEqual(aggregated.map { $0.secondaryValue ?? -1 }, [3.5])
        XCTAssertEqual(aggregated.map(\.sampleCount), [4])
    }

    func testHistoryRetainsOneDayForMostMetricsAndThirtyMinutesForNetwork() {
        let store = MetricsStore()
        let start = Date(timeIntervalSince1970: 0)

        for hour in 0...25 {
            store.apply(
                [
                    .cpu(CPUReading(usagePercent: Double(hour))),
                    .temperature(TemperatureReading(celsius: 40 + Double(hour) * 0.5)),
                    .fan(FanReading(rpm: 1_800 + hour * 10)),
                    .network(
                        NetworkReading(
                            downloadBytesPerSecond: Double(hour * 1_000),
                            uploadBytesPerSecond: Double(hour * 500)
                        )
                    ),
                ],
                timestamp: start.addingTimeInterval(Double(hour) * 3_600)
            )
        }

        XCTAssertEqual(store.history.samples(for: .cpu).count, 25)
        XCTAssertEqual(store.history.samples(for: .cpu).first?.timestamp, start.addingTimeInterval(3_600))
        XCTAssertEqual(store.history.samples(for: .cpu).last?.primaryValue, 25)
        XCTAssertEqual(store.history.samples(for: .temperature).last?.primaryValue, 52.5)
        XCTAssertEqual(store.history.samples(for: .fan).last?.primaryValue, 2_050)
        XCTAssertEqual(store.history.samples(for: .network).count, 1)
        XCTAssertEqual(store.history.samples(for: .network).last?.primaryValue, 25_000)
        XCTAssertEqual(store.history.samples(for: .network).last?.secondaryValue, 12_500)
    }

    func testHistoryAggregatesOlderDenseSeriesWhileKeepingRecentRawSamples() {
        let store = MetricsStore()

        for second in 0..<5_000 {
            store.apply(
                [
                    .cpu(CPUReading(usagePercent: Double(second))),
                ],
                timestamp: Date(timeIntervalSince1970: Double(second))
            )
        }

        let samples = store.history.samples(for: .cpu)
        let aggregatedPrefix = Array(samples.dropLast(300))
        let recentSuffix = Array(samples.suffix(300))

        XCTAssertEqual(samples.count, 1_440)
        XCTAssertEqual(aggregatedPrefix.count, 1_140)
        XCTAssertEqual(recentSuffix.first?.timestamp, Date(timeIntervalSince1970: 4_700))
        XCTAssertEqual(recentSuffix.first?.primaryValue, 4_700)
        XCTAssertEqual(recentSuffix.last?.timestamp, Date(timeIntervalSince1970: 4_999))
        XCTAssertEqual(recentSuffix.last?.primaryValue, 4_999)
        XCTAssertTrue(aggregatedPrefix.contains { $0.sampleCount > 1 })
        XCTAssertTrue(recentSuffix.allSatisfy { $0.sampleCount == 1 })
        XCTAssertEqual(samples.reduce(0) { $0 + $1.sampleCount }, 5_000)
    }

    func testHistoryTracksEachMetricIndependently() {
        let store = MetricsStore()

        store.apply(
            [
                .cpu(CPUReading(usagePercent: 20)),
                .temperature(TemperatureReading(celsius: 48)),
            ],
            timestamp: Date(timeIntervalSince1970: 10)
        )
        store.apply(
            [
                .cpu(CPUReading(usagePercent: 35)),
            ],
            timestamp: Date(timeIntervalSince1970: 11)
        )

        XCTAssertEqual(
            store.history.samples(for: .cpu).map(\.primaryValue),
            [20, 35]
        )
        XCTAssertEqual(
            store.history.samples(for: .temperature).map(\.primaryValue),
            [48]
        )
    }
}
