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
