import XCTest
import MacActivityCore
@testable import MacActivityApp

final class DashboardTrendAveragerTests: XCTestCase {
    func testPreferredBucketCountUsesSixPointDensityAndHardLimits() {
        XCTAssertEqual(DashboardTrendAverager.preferredBucketCount(for: 0), 0)
        XCTAssertEqual(DashboardTrendAverager.preferredBucketCount(for: 100), 24)
        XCTAssertEqual(DashboardTrendAverager.preferredBucketCount(for: 280), 46)
        XCTAssertEqual(DashboardTrendAverager.preferredBucketCount(for: 600), 64)
    }

    func testDisplayReturnsEmptyForInvalidPlotWidth() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            sample(base, 0, primary: 10),
            sample(base, 1, primary: 20),
        ]

        XCTAssertEqual(
            DashboardTrendAverager.display(
                samples: samples,
                plotWidth: .nan,
                referenceDate: base.addingTimeInterval(1)
            ),
            .empty
        )
    }

    func testDisplayUsesSampleWeightForPrimaryAndSecondaryAverages() throws {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            sample(base, 0, primary: 10, secondary: 100, weight: 3),
            sample(base, 1, primary: 40, secondary: 400),
            sample(base, 2, primary: 20),
            sample(base, 10, primary: 50, secondary: 500),
            sample(base, 11, primary: 70, secondary: 700),
            sample(base, 12, primary: 90, secondary: 900),
        ]

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(12)
        )
        let first = try XCTUnwrap(display.buckets.first)

        XCTAssertEqual(DashboardTrendAverager.bucketDuration(for: samples, plotWidth: 280), 5)
        XCTAssertEqual(first.sample.primaryValue, 18, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(first.sample.secondaryValue), 175, accuracy: 0.001)
        XCTAssertEqual(first.sample.sampleWeight, 5)
        XCTAssertEqual(display.samples.first?.timestamp, samples.first?.timestamp)
        XCTAssertEqual(display.samples.last?.timestamp, samples.last?.timestamp)
    }

    func testDisplayAveragesIsolatedSpikeInsteadOfPreservingIt() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = (0..<90).map { index in
            sample(
                base,
                TimeInterval(index),
                primary: index == 44 ? 100 : 10
            )
        }

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(89)
        )

        XCTAssertLessThan(display.samples.map(\.primaryValue).max() ?? 100, 100)
        XCTAssertFalse(display.samples.contains { $0.primaryValue == 100 })
    }

    func testDisplayNeverExceedsMaximumBucketCountAcrossAlignedBoundaries() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = (0...192).map { index in
            sample(
                base,
                0.1 + Double(index) / 3,
                primary: Double(index)
            )
        }

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 600,
            referenceDate: samples.last!.timestamp
        )

        XCTAssertLessThanOrEqual(
            display.buckets.count,
            DashboardTrendAverager.maximumDisplayBucketCount
        )
    }

    func testSingleAlignedBucketSplitsIntoAveragedSourceEndpoints() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = (1...6).map { index in
            sample(
                base,
                Double(index) / 10,
                primary: Double(index * 10)
            )
        }

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(1)
        )

        XCTAssertEqual(display.samples.map(\.timestamp), [
            samples.first!.timestamp,
            samples.last!.timestamp,
        ])
        XCTAssertEqual(display.samples.map(\.primaryValue), [25, 55])
        XCTAssertEqual(display.buckets.map(\.id), [
            base,
            base.addingTimeInterval(0.5),
        ])
        XCTAssertFalse(display.samples.contains { sample in
            sample.primaryValue == samples.first!.primaryValue
                || sample.primaryValue == samples.last!.primaryValue
        })
    }

    func testAppendingInsideAlignedBucketKeepsOlderBucketIDsStable() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let initial = (0..<89).map {
            sample(base, TimeInterval($0), primary: Double($0 % 10))
        }
        let appended = initial + [sample(base, 89, primary: 5)]

        let firstDisplay = DashboardTrendAverager.display(
            samples: initial,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(88)
        )
        let secondDisplay = DashboardTrendAverager.display(
            samples: appended,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(89)
        )

        XCTAssertEqual(
            Array(firstDisplay.buckets.dropLast().map(\.id)),
            Array(secondDisplay.buckets.prefix(firstDisplay.buckets.count - 1).map(\.id))
        )
    }

    func testNormalizationMergesDuplicateTimestampsAndDropsInvalidValues() throws {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let normalized = DashboardTrendAverager.normalizedSamples([
            sample(base, 0, primary: 10, secondary: 100, weight: 3),
            sample(base, 0, primary: 30, secondary: .infinity),
            sample(base, 1, primary: .nan),
            sample(base, 2, primary: 20, secondary: 200),
        ])

        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized[0].primaryValue, 15, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(normalized[0].secondaryValue), 100, accuracy: 0.001)
        XCTAssertEqual(normalized[0].sampleWeight, 4)
    }

    func testNormalizationMergesThreeDuplicatesWithIndependentOrderInvariantWeights() throws {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let first = sample(base, 0, primary: 10, secondary: 100, weight: 1)
        let invalidSecondary = sample(base, 0, primary: 20, secondary: .infinity, weight: 100)
        let last = sample(base, 0, primary: 30, secondary: 300, weight: 3)
        let orderings = [
            [first, invalidSecondary, last],
            [first, last, invalidSecondary],
            [invalidSecondary, first, last],
            [invalidSecondary, last, first],
            [last, first, invalidSecondary],
            [last, invalidSecondary, first],
        ]

        let normalized = orderings.map(DashboardTrendAverager.normalizedSamples)
        let expected = try XCTUnwrap(normalized.first?.first)

        XCTAssertTrue(normalized.allSatisfy { $0.count == 1 })
        XCTAssertTrue(normalized.allSatisfy { $0.first == expected })
        XCTAssertEqual(expected.primaryValue, 2_100.0 / 104.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(expected.secondaryValue), 250, accuracy: 0.001)
        XCTAssertEqual(expected.sampleWeight, 104)
    }

    func testDenseDisplayKeepsInvalidDuplicateSecondaryWeightOutOfBucketAverage() throws {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            sample(base, 0, primary: 10, secondary: 100, weight: 1),
            sample(base, 0, primary: 20, secondary: .infinity, weight: 100),
            sample(base, 0, primary: 30, secondary: 300, weight: 3),
            sample(base, 1, primary: 40, secondary: 500, weight: 1),
            sample(base, 2, primary: 50),
            sample(base, 10, primary: 60),
            sample(base, 11, primary: 70),
            sample(base, 12, primary: 80),
        ]

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(12)
        )
        let firstBucket = try XCTUnwrap(display.buckets.first)

        XCTAssertEqual(try XCTUnwrap(firstBucket.sample.secondaryValue), 300, accuracy: 0.001)
    }

    func testCurrentBucketBlendsFromPreviousAverageByElapsedProgress() throws {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            sample(base, 0, primary: 10),
            sample(base, 1, primary: 10),
            sample(base, 2, primary: 10),
            sample(base, 10, primary: 100),
            sample(base, 10.5, primary: 100),
            sample(base, 11, primary: 100),
        ]

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(11)
        )
        let latest = try XCTUnwrap(display.buckets.last)

        XCTAssertEqual(latest.startDate, base.addingTimeInterval(10))
        XCTAssertEqual(latest.endDate, base.addingTimeInterval(11))
        XCTAssertEqual(latest.sample.primaryValue, 28, accuracy: 0.001)
    }

    func testMaterialSamplingGapCreatesSeparateDisplaySegments() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            sample(base, 0, primary: 10),
            sample(base, 1, primary: 11),
            sample(base, 2, primary: 12),
            sample(base, 300, primary: 20),
            sample(base, 301, primary: 21),
            sample(base, 302, primary: 22),
        ]

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(302)
        )

        XCTAssertEqual(display.segments.count, 2)
        XCTAssertEqual(display.segments.map { $0.buckets.count }, [1, 1])
    }

    func testDisplayIsDeterministicForInjectedReferenceDate() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = (0..<90).map {
            sample(base, TimeInterval($0), primary: Double($0 % 7))
        }
        let referenceDate = base.addingTimeInterval(89)

        XCTAssertEqual(
            DashboardTrendAverager.display(
                samples: samples,
                plotWidth: 280,
                referenceDate: referenceDate
            ),
            DashboardTrendAverager.display(
                samples: samples,
                plotWidth: 280,
                referenceDate: referenceDate
            )
        )
    }

    func testSparseHistoryUsesValidSamplesUntilAveragesAreMeaningful() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            sample(base, 0, primary: 10),
            sample(base, 1, primary: 20),
            sample(base, 2, primary: 30),
        ]

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(2)
        )

        XCTAssertEqual(display.samples.map(\.primaryValue), [10, 20, 30])
        XCTAssertEqual(display.samples.map(\.timestamp), samples.map(\.timestamp))
    }

    func testSparseHistoryPreservesMaterialSamplingGaps() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            sample(base, 0, primary: 10),
            sample(base, 1, primary: 20),
            sample(base, 300, primary: 30),
            sample(base, 301, primary: 40),
        ]

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(301)
        )

        XCTAssertEqual(display.segments.count, 2)
        XCTAssertEqual(display.segments.map { $0.buckets.count }, [2, 2])
    }

    func testThreeSampleSparseHistoryPreservesMaterialSamplingGap() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            sample(base, 0, primary: 10),
            sample(base, 1, primary: 20),
            sample(base, 300, primary: 30),
        ]

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(300)
        )

        XCTAssertEqual(display.segments.count, 2)
        XCTAssertEqual(display.segments.map { $0.buckets.count }, [2, 1])
    }

    func testTwoSampleSparseHistoryPreservesMaterialSamplingGap() {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let samples = [
            sample(base, 0, primary: 10),
            sample(base, 300, primary: 20),
        ]

        let display = DashboardTrendAverager.display(
            samples: samples,
            plotWidth: 280,
            referenceDate: base.addingTimeInterval(300)
        )

        XCTAssertEqual(display.segments.count, 2)
        XCTAssertEqual(display.segments.map { $0.buckets.count }, [1, 1])
    }

    private func sample(
        _ base: Date,
        _ offset: TimeInterval,
        primary: Double,
        secondary: Double? = nil,
        weight: Int = 1
    ) -> DashboardTrendSample {
        DashboardTrendSample(
            timestamp: base.addingTimeInterval(offset),
            primaryValue: primary,
            secondaryValue: secondary,
            sampleWeight: weight
        )
    }
}
