import CoreGraphics
import Foundation
import MacActivityCore

struct DashboardTrendDisplayBucket: Equatable, Identifiable, Sendable {
    let startDate: Date
    let endDate: Date
    let timestamp: Date
    let sample: DashboardTrendSample

    var id: Date { startDate }

    func replacing(timestamp: Date, sample: DashboardTrendSample? = nil) -> Self {
        let value = sample ?? self.sample
        return Self(
            startDate: startDate,
            endDate: endDate,
            timestamp: timestamp,
            sample: DashboardTrendSample(
                timestamp: timestamp,
                primaryValue: value.primaryValue,
                secondaryValue: value.secondaryValue,
                sampleWeight: value.sampleWeight
            )
        )
    }
}

struct DashboardTrendDisplaySegment: Equatable, Identifiable, Sendable {
    let id: Date
    let buckets: [DashboardTrendDisplayBucket]
}

struct DashboardTrendDisplay: Equatable, Sendable {
    let segments: [DashboardTrendDisplaySegment]

    static let empty = Self(segments: [])

    var buckets: [DashboardTrendDisplayBucket] {
        segments.flatMap(\.buckets)
    }

    var samples: [DashboardTrendSample] {
        buckets.map(\.sample)
    }
}

struct DashboardTrendAverager {
    static let minimumDisplayBucketCount = 24
    static let maximumDisplayBucketCount = 64
    static let pointsPerBucket: CGFloat = 6

    private static let stableDurations: [TimeInterval] = [
        1, 2, 3, 5, 10, 15, 20, 30, 45,
        60, 120, 300, 600, 900, 1_800, 2_700, 3_600,
        7_200, 14_400, 21_600, 43_200, 86_400,
    ]

    static func preferredBucketCount(for plotWidth: CGFloat) -> Int {
        guard plotWidth.isFinite, plotWidth > 0 else { return 0 }
        let widthCount = Int(plotWidth / pointsPerBucket)
        return min(
            max(widthCount, minimumDisplayBucketCount),
            maximumDisplayBucketCount
        )
    }

    static func bucketDuration(
        for samples: [DashboardTrendSample],
        plotWidth: CGFloat
    ) -> TimeInterval {
        guard let first = samples.min(by: { $0.timestamp < $1.timestamp }),
              let last = samples.max(by: { $0.timestamp < $1.timestamp }) else {
            return 1
        }

        let sourceSpan = last.timestamp.timeIntervalSince(first.timestamp)
        let span = max(sourceSpan, 1)
        let preferredCount = preferredBucketCount(for: plotWidth)
        guard preferredCount > 0 else { return span }

        let sourceCountLimit = max(2, samples.count / 3)
        let targetCount = min(preferredCount, sourceCountLimit)
        let preferredDuration = span / Double(targetCount)
        // An aligned span can occupy one more bucket than its interval count.
        let minimumDuration = span / Double(maximumDisplayBucketCount - 1)
        let candidates = stableDurations.filter { $0 >= minimumDuration }

        var duration = candidates.min {
            abs(log($0 / preferredDuration)) < abs(log($1 / preferredDuration))
        } ?? ceil(minimumDuration)
        // Averaged displays need real buckets at both visible source endpoints.
        while samples.count >= 6, sourceSpan > 0, duration > sourceSpan {
            duration /= 2
        }
        return duration
    }

    static func display(
        samples: [DashboardTrendSample],
        plotWidth: CGFloat,
        referenceDate: Date
    ) -> DashboardTrendDisplay {
        guard preferredBucketCount(for: plotWidth) > 0 else { return .empty }
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= 2 else { return .empty }

        if ordered.count < 6 {
            return rawDisplay(for: ordered)
        }

        let duration = bucketDuration(for: ordered, plotWidth: plotWidth)
        let grouped = Dictionary(grouping: ordered) {
            alignedStart(for: $0.timestamp, duration: duration)
        }
        let effectiveReferenceDate = max(referenceDate, ordered.last!.timestamp)
        var buckets = grouped.keys.sorted().compactMap { startDate -> DashboardTrendDisplayBucket? in
            guard let groupedSamples = grouped[startDate] else { return nil }
            let intervalEnd = startDate.addingTimeInterval(duration)
            let endDate = min(intervalEnd, effectiveReferenceDate)
            let timestamp = startDate.addingTimeInterval(
                endDate.timeIntervalSince(startDate) / 2
            )
            let sample = averagedSample(groupedSamples, timestamp: timestamp)

            return DashboardTrendDisplayBucket(
                startDate: startDate,
                endDate: endDate,
                timestamp: timestamp,
                sample: sample
            )
        }

        if let firstTimestamp = ordered.first?.timestamp, !buckets.isEmpty {
            buckets[0] = buckets[0].replacing(timestamp: firstTimestamp)
        }
        if let lastTimestamp = ordered.last?.timestamp, !buckets.isEmpty {
            let lastIndex = buckets.index(before: buckets.endIndex)
            buckets[lastIndex] = buckets[lastIndex].replacing(timestamp: lastTimestamp)
        }

        guard let firstBucket = buckets.first else { return .empty }
        return DashboardTrendDisplay(
            segments: [
                DashboardTrendDisplaySegment(
                    id: firstBucket.startDate,
                    buckets: buckets
                )
            ]
        )
    }

    private static func rawDisplay(
        for samples: [DashboardTrendSample]
    ) -> DashboardTrendDisplay {
        guard let first = samples.first else { return .empty }
        let buckets = samples.map { sample in
            DashboardTrendDisplayBucket(
                startDate: sample.timestamp,
                endDate: sample.timestamp,
                timestamp: sample.timestamp,
                sample: sample
            )
        }
        return DashboardTrendDisplay(
            segments: [DashboardTrendDisplaySegment(id: first.timestamp, buckets: buckets)]
        )
    }

    private static func alignedStart(
        for date: Date,
        duration: TimeInterval
    ) -> Date {
        let interval = date.timeIntervalSinceReferenceDate
        let aligned = (interval / duration).rounded(.down) * duration
        return Date(timeIntervalSinceReferenceDate: aligned)
    }

    private static func averagedSample(
        _ samples: [DashboardTrendSample],
        timestamp: Date
    ) -> DashboardTrendSample {
        let primaryWeight = samples.reduce(0) { $0 + $1.sampleWeight }
        let primary = samples.reduce(0) {
            $0 + $1.primaryValue * Double($1.sampleWeight)
        } / Double(primaryWeight)
        let secondarySamples = samples.compactMap { sample -> (Double, Int)? in
            guard let value = sample.secondaryValue else { return nil }
            return (value, sample.sampleWeight)
        }
        let secondaryWeight = secondarySamples.reduce(0) { $0 + $1.1 }
        let secondary = secondaryWeight > 0
            ? secondarySamples.reduce(0) { $0 + $1.0 * Double($1.1) }
                / Double(secondaryWeight)
            : nil

        return DashboardTrendSample(
            timestamp: timestamp,
            primaryValue: primary,
            secondaryValue: secondary,
            sampleWeight: primaryWeight
        )
    }
}
