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
    private static let maximumVisualGap: TimeInterval = 300

    private struct WeightedSample {
        let sample: DashboardTrendSample
        let secondaryWeight: Int

        var timestamp: Date { sample.timestamp }
    }

    private struct AveragedSegment {
        var displaySegment: DashboardTrendDisplaySegment
        let duration: TimeInterval
    }

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

    static func normalizedSamples(
        _ samples: [DashboardTrendSample]
    ) -> [DashboardTrendSample] {
        normalizedWeightedSamples(samples).map(\.sample)
    }

    private static func normalizedWeightedSamples(
        _ samples: [DashboardTrendSample]
    ) -> [WeightedSample] {
        let valid = samples.compactMap { sample -> WeightedSample? in
            let timestamp = sample.timestamp.timeIntervalSinceReferenceDate
            guard timestamp.isFinite, sample.primaryValue.isFinite else { return nil }
            let secondary = sample.secondaryValue.flatMap { $0.isFinite ? $0 : nil }
            return WeightedSample(
                sample: DashboardTrendSample(
                    timestamp: sample.timestamp,
                    primaryValue: sample.primaryValue,
                    secondaryValue: secondary,
                    sampleWeight: sample.sampleWeight
                ),
                secondaryWeight: secondary == nil ? 0 : sample.sampleWeight
            )
        }

        let grouped = Dictionary(grouping: valid, by: \.timestamp)
        return grouped.keys.sorted().compactMap { timestamp in
            guard let samples = grouped[timestamp] else { return nil }
            let ordered = samples.sorted { lhs, rhs in
                if lhs.sample.primaryValue != rhs.sample.primaryValue {
                    return lhs.sample.primaryValue < rhs.sample.primaryValue
                }
                if lhs.sample.secondaryValue != rhs.sample.secondaryValue {
                    switch (lhs.sample.secondaryValue, rhs.sample.secondaryValue) {
                    case (nil, .some):
                        return true
                    case (.some, nil):
                        return false
                    case let (.some(lhs), .some(rhs)):
                        return lhs < rhs
                    case (nil, nil):
                        break
                    }
                }
                return lhs.sample.sampleWeight < rhs.sample.sampleWeight
            }
            return WeightedSample(
                sample: averagedSample(ordered, timestamp: timestamp),
                secondaryWeight: ordered.reduce(0) { $0 + $1.secondaryWeight }
            )
        }
    }

    static func display(
        samples: [DashboardTrendSample],
        plotWidth: CGFloat,
        referenceDate: Date
    ) -> DashboardTrendDisplay {
        guard preferredBucketCount(for: plotWidth) > 0 else { return .empty }
        let normalized = normalizedWeightedSamples(samples)
        guard normalized.count >= 2 else { return .empty }

        let duration = bucketDuration(
            for: normalized.map(\.sample),
            plotWidth: plotWidth
        )
        let sourceSegments = continuousSegments(normalized)
        if normalized.count < 6 {
            return rawDisplay(for: sourceSegments)
        }

        var averagedSegments = sourceSegments.compactMap { samples -> AveragedSegment? in
            var segmentDuration = duration
            var segmentBuckets = buckets(
                for: samples,
                duration: segmentDuration,
                referenceDate: referenceDate
            )
            while samples.count >= 2, segmentBuckets.count < 2 {
                let halvedDuration = segmentDuration / 2
                guard halvedDuration != segmentDuration else { break }
                segmentDuration = halvedDuration
                segmentBuckets = buckets(
                    for: samples,
                    duration: segmentDuration,
                    referenceDate: referenceDate
                )
            }

            guard let firstBucket = segmentBuckets.first else { return nil }
            return AveragedSegment(
                displaySegment: DashboardTrendDisplaySegment(
                    id: firstBucket.startDate,
                    buckets: segmentBuckets
                ),
                duration: segmentDuration
            )
        }

        stabilizeCurrentBucket(
            in: &averagedSegments,
            referenceDate: referenceDate
        )
        return DashboardTrendDisplay(segments: averagedSegments.map(\.displaySegment))
    }

    private static func rawDisplay(
        for sourceSegments: [[WeightedSample]]
    ) -> DashboardTrendDisplay {
        DashboardTrendDisplay(
            segments: sourceSegments.compactMap { samples in
                guard let first = samples.first else { return nil }
                let buckets = samples.map { sample in
                    DashboardTrendDisplayBucket(
                        startDate: sample.timestamp,
                        endDate: sample.timestamp,
                        timestamp: sample.timestamp,
                        sample: sample.sample
                    )
                }
                return DashboardTrendDisplaySegment(id: first.timestamp, buckets: buckets)
            }
        )
    }

    private static func continuousSegments(
        _ samples: [WeightedSample]
    ) -> [[WeightedSample]] {
        guard let first = samples.first else { return [] }
        let intervals = zip(samples, samples.dropFirst())
            .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .filter { $0 > 0 }
            .sorted()
        let cadenceIntervals = intervals.count >= 2
            ? Array(intervals.dropLast())
            : []
        let gapThreshold: TimeInterval
        if cadenceIntervals.isEmpty {
            gapThreshold = maximumVisualGap
        } else {
            let midpoint = cadenceIntervals.count / 2
            let medianCadence = cadenceIntervals.count.isMultiple(of: 2)
                ? (cadenceIntervals[midpoint - 1] + cadenceIntervals[midpoint]) / 2
                : cadenceIntervals[midpoint]
            gapThreshold = min(medianCadence * 3, maximumVisualGap)
        }

        var segments = [[first]]
        for sample in samples.dropFirst() {
            let previous = segments[segments.index(before: segments.endIndex)].last!
            if sample.timestamp.timeIntervalSince(previous.timestamp) >= gapThreshold {
                segments.append([sample])
            } else {
                segments[segments.index(before: segments.endIndex)].append(sample)
            }
        }
        return segments
    }

    private static func buckets(
        for samples: [WeightedSample],
        duration: TimeInterval,
        referenceDate: Date
    ) -> [DashboardTrendDisplayBucket] {
        let grouped = Dictionary(grouping: samples) {
            alignedStart(for: $0.sample.timestamp, duration: duration)
        }
        let effectiveReferenceDate = max(referenceDate, samples.last!.timestamp)
        var result = grouped.keys.sorted().compactMap { startDate -> DashboardTrendDisplayBucket? in
            guard let groupedSamples = grouped[startDate] else { return nil }
            let intervalEnd = startDate.addingTimeInterval(duration)
            let endDate = min(intervalEnd, effectiveReferenceDate)
            let timestamp = startDate.addingTimeInterval(
                endDate.timeIntervalSince(startDate) / 2
            )
            return DashboardTrendDisplayBucket(
                startDate: startDate,
                endDate: endDate,
                timestamp: timestamp,
                sample: averagedSample(groupedSamples, timestamp: timestamp)
            )
        }

        if let firstTimestamp = samples.first?.timestamp, !result.isEmpty {
            result[0] = result[0].replacing(timestamp: firstTimestamp)
        }
        if let lastTimestamp = samples.last?.timestamp, !result.isEmpty {
            let lastIndex = result.index(before: result.endIndex)
            result[lastIndex] = result[lastIndex].replacing(timestamp: lastTimestamp)
        }
        return result
    }

    private static func stabilizeCurrentBucket(
        in segments: inout [AveragedSegment],
        referenceDate: Date
    ) {
        guard let segmentIndex = segments.indices.last,
              segments[segmentIndex].displaySegment.buckets.count >= 2 else {
            return
        }

        let duration = segments[segmentIndex].duration
        var buckets = segments[segmentIndex].displaySegment.buckets
        let currentIndex = buckets.index(before: buckets.endIndex)
        let previousIndex = buckets.index(before: currentIndex)
        let current = buckets[currentIndex]
        let intervalEnd = current.startDate.addingTimeInterval(duration)
        guard referenceDate >= current.startDate, referenceDate < intervalEnd else {
            return
        }

        let progress = min(
            max(referenceDate.timeIntervalSince(current.startDate) / duration, 0),
            1
        )
        let previous = buckets[previousIndex].sample
        let primary = previous.primaryValue
            + (current.sample.primaryValue - previous.primaryValue) * progress
        let secondary: Double?
        if let previousSecondary = previous.secondaryValue,
           let currentSecondary = current.sample.secondaryValue {
            secondary = previousSecondary + (currentSecondary - previousSecondary) * progress
        } else {
            secondary = current.sample.secondaryValue
        }
        let blended = DashboardTrendSample(
            timestamp: current.timestamp,
            primaryValue: primary,
            secondaryValue: secondary,
            sampleWeight: current.sample.sampleWeight
        )

        buckets[currentIndex] = DashboardTrendDisplayBucket(
            startDate: current.startDate,
            endDate: referenceDate,
            timestamp: current.timestamp,
            sample: blended
        )
        segments[segmentIndex].displaySegment = DashboardTrendDisplaySegment(
            id: segments[segmentIndex].displaySegment.id,
            buckets: buckets
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
        _ samples: [WeightedSample],
        timestamp: Date
    ) -> DashboardTrendSample {
        let primaryWeight = samples.reduce(0) { $0 + $1.sample.sampleWeight }
        let primary = samples.reduce(0) {
            $0 + $1.sample.primaryValue * Double($1.sample.sampleWeight)
        } / Double(primaryWeight)
        let secondarySamples = samples.compactMap { sample -> (Double, Int)? in
            guard let value = sample.sample.secondaryValue else { return nil }
            return (value, sample.secondaryWeight)
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
