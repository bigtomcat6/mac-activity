import Charts
import AppKit
import Foundation
import SwiftUI
import MacActivityCore

struct DashboardTrendChart: View {
    let metric: DashboardMetric
    let color: Color
    let isCardHovered: Bool
    let showsYAxisLabels: Bool

    @State private var hoveredSampleIndex: Int?
    @State private var hoverLocation: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            if let trend = metric.trend, trend.samples.count >= 2 {
                chartBody(trend: trend, size: proxy.size)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(color.opacity(0.35), lineWidth: 1)
                    .overlay {
                        Text(AppLocalization.string(.dashboardTrendCollecting))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private func chartBody(
        trend: DashboardTrend,
        size: CGSize
    ) -> some View {
        let displaySamples = DashboardTrendChartLayout.displaySamples(
            for: trend.samples,
            kind: metric.kind,
            containerSize: size
        )
        let domain = chartDomain(for: trend)
        let xDomain = xDomain(for: trend)
        let selectedSample = isCardHovered ? (hoveredSample(in: trend) ?? trend.samples.last) : nil
        let isHovering = selectedSample != nil
        let isCompactHoverLayout = DashboardCardLayout.usesCompactHoverLayout(for: size.height)
        let xAxisDates = DashboardTrendChartLayout.xAxisDates(for: displaySamples)
        let yAxisValues = DashboardTrendChartLayout.yAxisValues(for: domain)
        let yAxisLabelWidth = DashboardTrendChartLayout.yAxisLabelWidth(
            for: yAxisValues.map(axisLabel(for:)),
            showsLabels: showsYAxisLabels
        )
        let plotFrame = DashboardTrendChartLayout.plotFrame(
            in: size,
            isHovering: isHovering,
            yAxisLabelWidth: yAxisLabelWidth,
            xAxisLabelHeight: DashboardTrendChartLayout.xAxisLabelHeight
        )
        let showsAreaFill = DashboardTrendChartLayout.showsAreaFill(
            kind: metric.kind,
            samples: displaySamples,
            domain: domain
        )
        let sampleAnimation = DashboardTrendChartLayout.animatesSampleChanges(for: metric.kind)
        let usesDisplaySampling = displaySamples.count < trend.samples.count
        let primaryLinePoints = DashboardTrendChartLayout.linePoints(
            for: displaySamples,
            series: .primary
        )
        let secondaryLinePoints = DashboardTrendChartLayout.linePoints(
            for: displaySamples,
            series: .secondary
        )

        return ZStack(alignment: .topLeading) {
            if isHovering {
                axesOverlay(
                    plotFrame: plotFrame,
                    containerSize: size,
                    xDomain: xDomain,
                    domain: domain,
                    xAxisDates: xAxisDates,
                    yAxisValues: yAxisValues,
                    showsYAxisLabels: showsYAxisLabels
                )
            }

            Chart {
                if showsAreaFill {
                    ForEach(displaySamples, id: \.timestamp) { sample in
                        AreaMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Primary", sample.primaryValue)
                        )
                        .interpolationMethod(primaryInterpolationMethod(usesDisplaySampling: usesDisplaySampling))
                        .foregroundStyle(areaGradient)
                    }
                }

                ForEach(primaryLinePoints) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Primary", point.value),
                        series: .value("Series", point.series.rawValue)
                    )
                    .interpolationMethod(primaryInterpolationMethod(usesDisplaySampling: usesDisplaySampling))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(primaryLineGradient)
                }

                if !secondaryLinePoints.isEmpty {
                    ForEach(secondaryLinePoints) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Secondary", point.value),
                            series: .value("Series", point.series.rawValue)
                        )
                        .interpolationMethod(secondaryInterpolationMethod)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(color.opacity(0.45))
                    }
                }

                if let selectedSample {
                    RuleMark(x: .value("Selection", selectedSample.timestamp))
                        .foregroundStyle(Color.primary.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1))

                    PointMark(
                        x: .value("Selection Time", selectedSample.timestamp),
                        y: .value("Selection Value", selectedSample.primaryValue)
                    )
                    .symbolSize(isCompactHoverLayout ? 28 : 40)
                    .foregroundStyle(color)
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: xDomain)
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plotArea in
                plotArea.background(Color.clear)
            }
            .chartOverlay { _ in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            guard let selection = DashboardTrendChartLayout.hoverSelection(
                                localX: location.x,
                                samples: trend.samples,
                                xDomain: xDomain,
                                yDomain: domain,
                                plotFrame: plotFrame
                            ) else {
                                hoveredSampleIndex = nil
                                hoverLocation = nil
                                return
                            }

                            hoveredSampleIndex = selection.sampleIndex
                            hoverLocation = selection.location
                        case .ended:
                            hoveredSampleIndex = nil
                            hoverLocation = nil
                        }
                    }
            }
            .frame(width: plotFrame.width, height: plotFrame.height)
            .clipped()
            .offset(x: plotFrame.minX, y: plotFrame.minY)

            if let selectedSample {
                let annotationAnchor = hoverLocation ?? CGPoint(
                    x: DashboardTrendChartLayout.xPosition(
                        for: selectedSample.timestamp,
                        domain: xDomain,
                        plotFrame: plotFrame
                    ),
                    y: DashboardTrendChartLayout.yPosition(
                        for: selectedSample.primaryValue,
                        domain: domain,
                        plotFrame: plotFrame
                    )
                )
                let annotationSize = annotationSize(
                    for: selectedSample,
                    isCompact: isCompactHoverLayout
                )

                annotationView(
                    sample: selectedSample,
                    isCompact: isCompactHoverLayout
                )
                .frame(width: annotationSize.width, height: annotationSize.height, alignment: .leading)
                .position(
                    DashboardTrendChartLayout.annotationPosition(
                        pointer: annotationAnchor,
                        plotFrame: plotFrame,
                        annotationSize: annotationSize
                    )
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .animation(sampleAnimation ? .smooth(duration: 0.24) : nil, value: trend.samples)
    }

    @ViewBuilder
    private func axesOverlay(
        plotFrame: CGRect,
        containerSize: CGSize,
        xDomain: ClosedRange<Date>,
        domain: ClosedRange<Double>,
        xAxisDates: [Date],
        yAxisValues: [Double],
        showsYAxisLabels: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(yAxisValues, id: \.self) { value in
                let gridY = DashboardTrendChartLayout.yPosition(
                    for: value,
                    domain: domain,
                    plotFrame: plotFrame
                )
                let labelY = DashboardTrendChartLayout.yAxisLabelPosition(
                    for: value,
                    domain: domain,
                    plotFrame: plotFrame,
                    containerHeight: containerSize.height
                )

                Path { path in
                    path.move(to: CGPoint(x: plotFrame.minX, y: gridY))
                    path.addLine(to: CGPoint(x: plotFrame.maxX, y: gridY))
                }
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)

                if showsYAxisLabels {
                    Text(axisLabel(for: value))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .frame(
                            width: DashboardTrendChartLayout.yAxisLabelWidth(for: plotFrame),
                            alignment: .trailing
                        )
                        .position(
                            x: DashboardTrendChartLayout.yAxisLabelCenterX(for: plotFrame),
                            y: labelY
                        )
                }
            }

            ForEach(Array(xAxisDates.enumerated()), id: \.offset) { entry in
                let index = entry.offset
                let date = entry.element
                let gridX = DashboardTrendChartLayout.xPosition(
                    for: date,
                    domain: xDomain,
                    plotFrame: plotFrame
                )

                Path { path in
                    path.move(to: CGPoint(x: gridX, y: plotFrame.minY))
                    path.addLine(to: CGPoint(x: gridX, y: plotFrame.maxY))
                }
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)

                Text(timestampLabel(for: date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(
                        width: DashboardTrendChartLayout.xAxisLabelWidth,
                        alignment: DashboardTrendChartLayout.xAxisLabelAlignment(
                            for: index,
                            count: xAxisDates.count
                        )
                    )
                    .position(
                        x: DashboardTrendChartLayout.xAxisLabelCenterX(
                            for: gridX,
                            plotFrame: plotFrame,
                            index: index,
                            count: xAxisDates.count
                        ),
                        y: DashboardTrendChartLayout.xAxisLabelY(
                            for: plotFrame,
                            containerHeight: containerSize.height
                        )
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private var areaGradient: LinearGradient {
        LinearGradient(
            colors: [
                color.opacity(0.16),
                color.opacity(0.02),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var primaryLineGradient: LinearGradient {
        LinearGradient(
            colors: [
                color.opacity(0.92),
                color.opacity(0.62)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func primaryInterpolationMethod(usesDisplaySampling: Bool) -> InterpolationMethod {
        if metric.kind == .fan {
            return .stepEnd
        }

        if metric.kind == .network {
            return .linear
        }

        return usesDisplaySampling ? .linear : .monotone
    }

    private var secondaryInterpolationMethod: InterpolationMethod {
        .linear
    }

    private func annotationView(
        sample: DashboardTrendSample,
        isCompact: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 1 : 2) {
            Text(primaryReadout(for: sample))
                .font(
                    isCompact
                    ? .caption.monospacedDigit().weight(.semibold)
                    : .subheadline.monospacedDigit().weight(.semibold)
                )
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let secondaryText = secondaryReadout(for: sample) {
                Text(secondaryText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(timestampLabel(for: sample.timestamp))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, isCompact ? 4 : 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func annotationSize(
        for sample: DashboardTrendSample,
        isCompact: Bool
    ) -> CGSize {
        if secondaryReadout(for: sample) != nil {
            return isCompact ? CGSize(width: 118, height: 44) : CGSize(width: 132, height: 54)
        }

        return isCompact ? CGSize(width: 88, height: 34) : CGSize(width: 104, height: 44)
    }

    private func hoveredSample(in trend: DashboardTrend) -> DashboardTrendSample? {
        guard let hoveredSampleIndex,
              trend.samples.indices.contains(hoveredSampleIndex) else {
            return nil
        }

        return trend.samples[hoveredSampleIndex]
    }

    private func chartDomain(for trend: DashboardTrend) -> ClosedRange<Double> {
        switch trend.scale {
        case .fixed(let lowerBound, let upperBound):
            return lowerBound...upperBound
        case .automatic:
            let values = trend.samples.flatMap { sample in
                [sample.primaryValue, sample.secondaryValue].compactMap { $0 }
            }
            let lowerBound = values.min() ?? 0
            let upperBound = values.max() ?? 1

            if upperBound - lowerBound < 0.001 {
                return (lowerBound - 1)...(upperBound + 1)
            }

            let padding = (upperBound - lowerBound) * 0.12
            return (lowerBound - padding)...(upperBound + padding)
        }
    }

    private func xDomain(for trend: DashboardTrend) -> ClosedRange<Date> {
        guard let first = trend.samples.first?.timestamp,
              let last = trend.samples.last?.timestamp else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }

        if first == last {
            return first.addingTimeInterval(-60)...last.addingTimeInterval(60)
        }

        return first...last
    }

    private func axisLabel(for value: Double) -> String {
        DashboardTrendReadoutFormatter.axisLabel(for: metric.kind, value: value)
    }

    private func primaryReadout(for sample: DashboardTrendSample) -> String {
        DashboardTrendReadoutFormatter.primaryReadout(for: metric.kind, sample: sample)
    }

    private func secondaryReadout(for sample: DashboardTrendSample) -> String? {
        DashboardTrendReadoutFormatter.secondaryReadout(for: metric.kind, sample: sample)
    }

    private func timestampLabel(for date: Date?) -> String {
        guard let date else {
            return "--:--"
        }

        return date.formatted(.dateTime.hour().minute())
    }

}

enum DashboardTrendLineSeries: String, Equatable, Sendable {
    case primary
    case secondary
}

struct DashboardTrendLinePoint: Equatable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let value: Double
    let series: DashboardTrendLineSeries
}

struct DashboardTrendHoverSelection: Equatable {
    let sampleIndex: Int
    let location: CGPoint
}

struct DashboardTrendChartLayout {
    static let restInsets = EdgeInsets(top: 2, leading: 2, bottom: 1, trailing: 2)
    static let xAxisLabelWidth: CGFloat = 52
    static let yAxisLabelHalfHeight: CGFloat = 7
    static let xAxisLabelHalfHeight: CGFloat = 7
    static let xAxisLabelHeight: CGFloat = xAxisLabelHalfHeight * 2
    static let axisLabelPlotGap: CGFloat = 6
    static let xAxisLabelPlotGap: CGFloat = 4
    private static let maximumHoverLeadingWidthRatio: CGFloat = 0.36
    private static let maximumHoverBottomHeightRatio: CGFloat = 0.45
    private static let minimumDisplaySampleBudget = 60
    private static let maximumDisplaySampleBudget = 240
    private static let recentDetailBudgetCap = 120
    private static let flatPrimaryTolerance = 0.001
    private static let flatSecondaryTolerance = 0.001

    static func annotationPosition(
        pointer: CGPoint,
        plotFrame: CGRect,
        annotationSize: CGSize
    ) -> CGPoint {
        let horizontalSpacing: CGFloat = 10
        let boundaryPadding: CGFloat = 4
        let halfWidth = annotationSize.width / 2
        let halfHeight = annotationSize.height / 2

        let preferredRightX = pointer.x + horizontalSpacing + halfWidth
        let x: CGFloat

        if preferredRightX <= plotFrame.maxX - boundaryPadding {
            x = preferredRightX
        } else {
            x = max(
                plotFrame.minX + halfWidth + boundaryPadding,
                pointer.x - horizontalSpacing - halfWidth
            )
        }

        let y = min(
            max(pointer.y, plotFrame.minY + halfHeight + boundaryPadding),
            plotFrame.maxY - halfHeight - boundaryPadding
        )

        return CGPoint(x: x, y: y)
    }

    static func xAxisDates(for samples: [DashboardTrendSample]) -> [Date] {
        guard let first = samples.first?.timestamp,
              let last = samples.last?.timestamp else {
            return []
        }

        let middle = samples[samples.count / 2].timestamp
        var dates: [Date] = []

        for date in [first, middle, last] where !dates.contains(date) {
            dates.append(date)
        }

        return dates
    }

    static func yAxisValues(for domain: ClosedRange<Double>) -> [Double] {
        let midpoint = domain.lowerBound + (domain.upperBound - domain.lowerBound) / 2
        return [domain.lowerBound, midpoint, domain.upperBound]
    }

    static func linePoints(
        for samples: [DashboardTrendSample],
        series: DashboardTrendLineSeries
    ) -> [DashboardTrendLinePoint] {
        samples.compactMap { sample in
            let value: Double?

            switch series {
            case .primary:
                value = sample.primaryValue
            case .secondary:
                value = sample.secondaryValue
            }

            guard let value else {
                return nil
            }

            return DashboardTrendLinePoint(
                id: "\(series.rawValue)-\(sample.timestamp.timeIntervalSinceReferenceDate.bitPattern)-\(value.bitPattern)",
                timestamp: sample.timestamp,
                value: value,
                series: series
            )
        }
    }

    static func displayPlotWidth(for containerSize: CGSize) -> CGFloat {
        plotFrame(
            in: containerSize,
            isHovering: false
        ).width
    }

    static func displaySampleBudget(for containerSize: CGSize) -> Int {
        let width = displayPlotWidth(for: containerSize)
        let scaledBudget = Int((width * 0.75).rounded())
        return min(max(scaledBudget, minimumDisplaySampleBudget), maximumDisplaySampleBudget)
    }

    static func displaySamples(
        for samples: [DashboardTrendSample],
        kind: MetricKind,
        containerSize: CGSize
    ) -> [DashboardTrendSample] {
        guard kind != .network else {
            return samples
        }

        let budget = displaySampleBudget(for: containerSize)
        guard samples.count > budget, samples.count >= 3 else {
            return samples
        }

        let recentDetailCount = min(
            samples.count,
            min(
                recentDetailBudgetCap,
                max(24, Int(Double(budget) * 0.6))
            )
        )
        let olderCount = max(0, samples.count - recentDetailCount)
        let recentSamples = Array(samples.suffix(recentDetailCount))
        let overviewBudget = max(1, budget - recentSamples.count)
        let overviewSamples = sampledOverviewSamples(
            Array(samples.prefix(olderCount)),
            budget: overviewBudget
        )
        var displaySamples = deduplicatedChronologicalSamples(overviewSamples + recentSamples)

        if displaySamples.first?.timestamp != samples.first?.timestamp, let firstSample = samples.first {
            displaySamples.insert(firstSample, at: 0)
        }

        if displaySamples.last?.timestamp != samples.last?.timestamp, let lastSample = samples.last {
            displaySamples.append(lastSample)
        }

        return deduplicatedChronologicalSamples(displaySamples)
    }

    private static func sampledOverviewSamples(
        _ samples: [DashboardTrendSample],
        budget: Int
    ) -> [DashboardTrendSample] {
        guard budget > 0, !samples.isEmpty else {
            return []
        }

        guard samples.count > budget else {
            return samples
        }

        let bucketCount = max(1, budget / 3)
        let representatives = (0..<bucketCount).flatMap { bucketIndex -> [DashboardTrendSample] in
            let startIndex = bucketIndex * samples.count / bucketCount
            let endIndex = min(samples.count, (bucketIndex + 1) * samples.count / bucketCount)
            guard startIndex < endIndex else {
                return []
            }

            return sampledOverviewBucket(samples[startIndex..<endIndex])
        }

        return representatives
    }

    private static func sampledOverviewBucket(
        _ samples: ArraySlice<DashboardTrendSample>
    ) -> [DashboardTrendSample] {
        let bucket = Array(samples)
        guard !bucket.isEmpty else {
            return []
        }

        guard bucket.count > 2 else {
            return bucket
        }

        if isFlat(bucket) {
            return [bucket.last!]
        }

        let minIndex = bucket.indices.min {
            bucket[$0].primaryValue < bucket[$1].primaryValue
        } ?? bucket.startIndex
        let maxIndex = bucket.indices.max {
            bucket[$0].primaryValue < bucket[$1].primaryValue
        } ?? bucket.startIndex
        let candidateIndexes = Set([minIndex, maxIndex, bucket.index(before: bucket.endIndex)])

        return candidateIndexes
            .sorted()
            .map { bucket[$0] }
    }

    private static func deduplicatedChronologicalSamples(
        _ samples: [DashboardTrendSample]
    ) -> [DashboardTrendSample] {
        guard samples.count > 2 else {
            return samples
        }

        var result: [DashboardTrendSample] = []
        result.reserveCapacity(samples.count)

        for index in samples.indices {
            let current = samples[index]
            if index == samples.startIndex || index == samples.index(before: samples.endIndex) {
                result.append(current)
                continue
            }

            let previous = samples[samples.index(before: index)]
            let next = samples[samples.index(after: index)]
            let matchesPrevious = equivalentValue(previous, current)
            let matchesNext = equivalentValue(current, next)

            if matchesPrevious && matchesNext {
                continue
            }

            result.append(current)
        }

        if result.first?.timestamp != samples.first?.timestamp, let firstSample = samples.first {
            result.insert(firstSample, at: 0)
        }

        if result.last?.timestamp != samples.last?.timestamp, let lastSample = samples.last {
            result.append(lastSample)
        }

        return result
    }

    private static func isFlat(_ samples: [DashboardTrendSample]) -> Bool {
        let primaryValues = samples.map(\.primaryValue)
        let primaryRange = (primaryValues.max() ?? 0) - (primaryValues.min() ?? 0)
        let secondaryValues = samples.compactMap(\.secondaryValue)
        let secondaryRange: Double
        if secondaryValues.isEmpty {
            secondaryRange = 0
        } else {
            secondaryRange = (secondaryValues.max() ?? 0) - (secondaryValues.min() ?? 0)
        }

        return primaryRange < flatPrimaryTolerance && secondaryRange < flatSecondaryTolerance
    }

    private static func equivalentValue(
        _ lhs: DashboardTrendSample,
        _ rhs: DashboardTrendSample
    ) -> Bool {
        abs(lhs.primaryValue - rhs.primaryValue) < flatPrimaryTolerance
        && equivalentSecondaryValue(lhs.secondaryValue, rhs.secondaryValue)
    }

    private static func equivalentSecondaryValue(
        _ lhs: Double?,
        _ rhs: Double?
    ) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(left), .some(right)):
            return abs(left - right) < flatSecondaryTolerance
        default:
            return false
        }
    }

    static func plotFrame(
        in containerSize: CGSize,
        isHovering: Bool
    ) -> CGRect {
        plotFrame(
            in: containerSize,
            isHovering: isHovering,
            yAxisLabelWidth: 36,
            xAxisLabelHeight: xAxisLabelHeight
        )
    }

    static func plotFrame(
        in containerSize: CGSize,
        isHovering: Bool,
        yAxisLabelWidth: CGFloat,
        xAxisLabelHeight: CGFloat
    ) -> CGRect {
        let insets = isHovering
        ? hoverInsets(
            in: containerSize,
            yAxisLabelWidth: yAxisLabelWidth,
            xAxisLabelHeight: xAxisLabelHeight
        )
        : restInsets
        let width = max(0, containerSize.width - insets.leading - insets.trailing)
        let height = max(0, containerSize.height - insets.top - insets.bottom)

        return CGRect(
            x: insets.leading,
            y: insets.top,
            width: width,
            height: height
        )
    }

    private static func hoverInsets(
        in containerSize: CGSize,
        yAxisLabelWidth: CGFloat,
        xAxisLabelHeight: CGFloat
    ) -> EdgeInsets {
        let maximumLeading = max(axisLabelPlotGap, containerSize.width * maximumHoverLeadingWidthRatio)
        let maximumBottom = max(xAxisLabelPlotGap, containerSize.height * maximumHoverBottomHeightRatio)
        let leading: CGFloat
        if yAxisLabelWidth > 0 {
            leading = min(yAxisLabelWidth + axisLabelPlotGap, maximumLeading)
        } else {
            leading = restInsets.leading
        }
        let bottom = min(max(0, xAxisLabelHeight) + xAxisLabelPlotGap, maximumBottom)

        return EdgeInsets(
            top: restInsets.top,
            leading: leading,
            bottom: bottom,
            trailing: restInsets.trailing
        )
    }

    static func xPosition(
        for date: Date,
        domain: ClosedRange<Date>,
        plotFrame: CGRect
    ) -> CGFloat {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0, plotFrame.width > 0 else {
            return plotFrame.midX
        }

        let offset = date.timeIntervalSince(domain.lowerBound)
        let progress = min(max(offset / span, 0), 1)
        return plotFrame.minX + CGFloat(progress) * plotFrame.width
    }

    static func date(
        atX x: CGFloat,
        plotFrame: CGRect,
        domain: ClosedRange<Date>
    ) -> Date {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0, plotFrame.width > 0 else {
            return domain.lowerBound
        }

        let clampedX = min(max(x, plotFrame.minX), plotFrame.maxX)
        let progress = (clampedX - plotFrame.minX) / plotFrame.width
        return domain.lowerBound.addingTimeInterval(span * progress)
    }

    static func hoverSelection(
        localX: CGFloat,
        samples: [DashboardTrendSample],
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
        plotFrame: CGRect
    ) -> DashboardTrendHoverSelection? {
        guard !samples.isEmpty else {
            return nil
        }

        let clampedLocalX = min(max(localX, 0), plotFrame.width)
        let hoveredDate = date(
            atX: plotFrame.minX + clampedLocalX,
            plotFrame: plotFrame,
            domain: xDomain
        )
        let selectedIndex = nearestSampleIndex(to: hoveredDate, samples: samples)
        guard samples.indices.contains(selectedIndex) else {
            return nil
        }

        let selectedSample = samples[selectedIndex]
        return DashboardTrendHoverSelection(
            sampleIndex: selectedIndex,
            location: CGPoint(
                x: xPosition(
                    for: selectedSample.timestamp,
                    domain: xDomain,
                    plotFrame: plotFrame
                ),
                y: yPosition(
                    for: selectedSample.primaryValue,
                    domain: yDomain,
                    plotFrame: plotFrame
                )
            )
        )
    }

    private static func nearestSampleIndex(
        to date: Date,
        samples: [DashboardTrendSample]
    ) -> Int {
        samples.enumerated().min { lhs, rhs in
            abs(lhs.element.timestamp.timeIntervalSince(date)) < abs(rhs.element.timestamp.timeIntervalSince(date))
        }?.offset ?? 0
    }

    static func yPosition(
        for value: Double,
        domain: ClosedRange<Double>,
        plotFrame: CGRect
    ) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, plotFrame.height > 0 else {
            return plotFrame.midY
        }

        let progress = min(max((value - domain.lowerBound) / span, 0), 1)
        return plotFrame.maxY - CGFloat(progress) * plotFrame.height
    }

    static func yAxisLabelWidth(for plotFrame: CGRect) -> CGFloat {
        max(0, plotFrame.minX - axisLabelPlotGap)
    }

    static func yAxisLabelWidth(for labels: [String]) -> CGFloat {
        guard !labels.isEmpty else {
            return 0
        }

        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        let measuredWidth = labels.reduce(CGFloat.zero) { width, label in
            let labelWidth = (label as NSString).size(withAttributes: [.font: font]).width
            return max(width, ceil(labelWidth))
        }

        return measuredWidth
    }

    static func yAxisLabelWidth(
        for labels: [String],
        showsLabels: Bool
    ) -> CGFloat {
        showsLabels ? yAxisLabelWidth(for: labels) : 0
    }

    static func yAxisLabelCenterX(for plotFrame: CGRect) -> CGFloat {
        yAxisLabelWidth(for: plotFrame) / 2
    }

    static func yAxisLabelPosition(
        for value: Double,
        domain: ClosedRange<Double>,
        plotFrame: CGRect,
        containerHeight: CGFloat
    ) -> CGFloat {
        let rawY = yPosition(for: value, domain: domain, plotFrame: plotFrame)
        return min(
            max(rawY, yAxisLabelHalfHeight),
            containerHeight - yAxisLabelHalfHeight
        )
    }

    static func xAxisLabelAlignment(
        for index: Int,
        count: Int
    ) -> Alignment {
        switch index {
        case 0:
            return .leading
        case count - 1:
            return .trailing
        default:
            return .center
        }
    }

    static func xAxisLabelCenterX(
        for axisX: CGFloat,
        plotFrame: CGRect,
        index: Int,
        count: Int
    ) -> CGFloat {
        let halfWidth = xAxisLabelWidth / 2

        switch index {
        case 0:
            return plotFrame.minX + halfWidth
        case count - 1:
            return plotFrame.maxX - halfWidth
        default:
            return axisX
        }
    }

    static func xAxisLabelY(
        for plotFrame: CGRect,
        containerHeight: CGFloat
    ) -> CGFloat {
        containerHeight - xAxisLabelHalfHeight
    }

    static func showsAreaFill(
        kind: MetricKind,
        samples: [DashboardTrendSample],
        domain: ClosedRange<Double>
    ) -> Bool {
        samples.count >= 2 && kind != .network
    }

    static func animatesSampleChanges(for kind: MetricKind) -> Bool {
        kind != .network
    }
}

enum DashboardTrendReadoutFormatter {
    static func axisLabel(for kind: MetricKind, value: Double) -> String {
        switch kind {
        case .cpu, .gpu, .memory, .vram, .battery:
            return "\(Int(value.rounded()))%"
        case .temperature:
            return String(format: "%.1f C", value)
        case .fan:
            return "\(Int(value.rounded())) RPM"
        case .network:
            return DashboardMetricTextFormatter.formatRate(value)
        }
    }

    static func primaryReadout(for kind: MetricKind, sample: DashboardTrendSample) -> String {
        switch kind {
        case .cpu, .gpu, .memory, .vram, .battery:
            return "\(Int(sample.primaryValue.rounded()))%"
        case .temperature:
            return String(format: "%.1f C", sample.primaryValue)
        case .fan:
            return "\(Int(sample.primaryValue.rounded())) RPM"
        case .network:
            return "↑ \(DashboardMetricTextFormatter.formatRate(sample.secondaryValue ?? 0))"
        }
    }

    static func secondaryReadout(for kind: MetricKind, sample: DashboardTrendSample) -> String? {
        guard kind == .network else {
            return nil
        }

        return "↓ \(DashboardMetricTextFormatter.formatRate(sample.primaryValue))"
    }
}
