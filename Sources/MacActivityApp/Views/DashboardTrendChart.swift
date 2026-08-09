import Charts
import AppKit
import Foundation
import SwiftUI
import MacActivityCore

struct DashboardTrendChart: View {
    @Environment(\.appearsActive) private var appearsActive
    let metric: DashboardMetric
    let color: Color
    let isCardHovered: Bool
    let showsYAxisLabels: Bool

    @State private var hoveredBucketIndex: Int?
    @State private var hoverLocation: CGPoint?
    @State private var displayedDomain: ClosedRange<Double>?

    var body: some View {
        GeometryReader { proxy in
            if let trend = metric.trend, trend.samples.count >= 2 {
                let display = DashboardTrendAverager.display(
                    samples: trend.samples,
                    plotWidth: DashboardTrendChartLayout.displayPlotWidth(for: proxy.size),
                    referenceDate: .now
                )
                if display.buckets.count >= 2 {
                    chartBody(trend: trend, display: display, size: proxy.size)
                } else {
                    collectingPlaceholder(size: proxy.size)
                }
            } else {
                collectingPlaceholder(size: proxy.size)
            }
        }
    }

    private func chartBody(
        trend: DashboardTrend,
        display: DashboardTrendDisplay,
        size: CGSize
    ) -> some View {
        let displayBuckets = display.buckets
        let displaySamples = display.samples
        let rawDomain = chartDomain(for: displaySamples, scale: trend.scale)
        let domain = displayedDomain ?? rawDomain
        let xDomain = xDomain(for: trend)
        let selectedBucket = isCardHovered
            ? (hoveredBucket(in: displayBuckets) ?? displayBuckets.last)
            : nil
        let selectedSample = selectedBucket?.sample
        let isHovering = selectedSample != nil
        let isCompactHoverLayout = DashboardCardLayout.usesCompactHoverLayout(for: size.height)
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
        let dataPlotFrame = DashboardTrendChartLayout.dataPlotFrame(for: metric.kind, plotFrame: plotFrame)
        let xAxisDates = DashboardTrendChartLayout.xAxisDates(for: displaySamples)
        let primaryLinePoints = DashboardTrendChartLayout.linePoints(
            for: display,
            kind: metric.kind,
            series: .primary
        )
        let secondaryLinePoints = DashboardTrendChartLayout.linePoints(
            for: display,
            kind: metric.kind,
            series: .secondary
        )
        let powerConnectedIntervals = DashboardTrendChartLayout.batteryPowerConnectedIntervals(
            for: trend.samples,
            xDomain: xDomain
        )
        let powerConnectedCapsules = DashboardTrendChartLayout.batteryPowerConnectedCapsules(
            for: powerConnectedIntervals,
            xDomain: xDomain,
            plotFrame: plotFrame
        )

        return ZStack(alignment: .topLeading) {
            if isHovering {
                axesOverlay(
                    plotFrame: dataPlotFrame,
                    containerSize: size,
                    xDomain: xDomain,
                    domain: domain,
                    xAxisDates: xAxisDates,
                    yAxisValues: yAxisValues,
                    showsYAxisLabels: showsYAxisLabels
                )
            }

            chartPlotView(
                hoverSamples: displaySamples,
                primaryLinePoints: primaryLinePoints,
                secondaryLinePoints: secondaryLinePoints,
                selectedSample: selectedSample,
                domain: domain,
                xDomain: xDomain,
                plotFrame: dataPlotFrame,
                isCompactHoverLayout: isCompactHoverLayout
            )

            if metric.kind == .battery {
                ForEach(powerConnectedCapsules) { capsule in
                    powerConnectedCapsuleView(
                        frame: capsule.frame,
                        iconFrame: capsule.iconFrame
                    )
                }
            }

            if let selectedSample {
                let annotationAnchor = hoverLocation ?? CGPoint(
                    x: DashboardTrendChartLayout.xPosition(
                        for: selectedSample.timestamp,
                        domain: xDomain,
                        plotFrame: dataPlotFrame
                    ),
                    y: DashboardTrendChartLayout.yPosition(
                        for: DashboardTrendChartLayout.selectionValue(
                            for: selectedSample,
                            kind: metric.kind
                        ),
                        domain: domain,
                        plotFrame: dataPlotFrame
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
                        plotFrame: dataPlotFrame,
                        annotationSize: annotationSize
                    )
                )
                .transition(.opacity)
            }
        }
        .animation(DashboardMotion.focusPaletteAnimation, value: appearsActive)
        .onAppear {
            updateDisplayedDomain(to: rawDomain, animated: false)
        }
        .onChange(of: metric.kind) { _ in
            updateDisplayedDomain(to: rawDomain, animated: false)
        }
        .onChange(of: displaySamples) { _ in
            updateDisplayedDomain(to: rawDomain, animated: true)
        }
        .animation(DashboardMotion.hoverAnimation, value: isHovering)
        .animation(
            DashboardTrendChartLayout.animatesSampleChanges(for: metric.kind)
                ? DashboardMotion.sampleAnimation
                : nil,
            value: displayBuckets
        )
        .animation(DashboardMotion.domainAnimation, value: displayedDomain)
    }

    private func updateDisplayedDomain(to rawDomain: ClosedRange<Double>, animated: Bool) {
        let nextDomain = DashboardTrendChartLayout.smoothedDomain(
            previous: displayedDomain,
            next: rawDomain,
            kind: metric.kind
        )
        guard displayedDomain != nextDomain else { return }

        if animated {
            withAnimation(DashboardMotion.domainAnimation) {
                displayedDomain = nextDomain
            }
        } else {
            displayedDomain = nextDomain
        }
    }

    private func chartPlotView(
        hoverSamples: [DashboardTrendSample],
        primaryLinePoints: [DashboardTrendLinePoint],
        secondaryLinePoints: [DashboardTrendLinePoint],
        selectedSample: DashboardTrendSample?,
        domain: ClosedRange<Double>,
        xDomain: ClosedRange<Date>,
        plotFrame: CGRect,
        isCompactHoverLayout: Bool
    ) -> some View {
        Chart {
            ForEach(primaryLinePoints) { point in
                LineMark(
                    x: .value(AppLocalization.string(.chartDimensionTime), point.timestamp),
                    y: .value(AppLocalization.string(.chartDimensionPrimary), point.value),
                    series: .value(
                        AppLocalization.string(.chartDimensionSeries),
                        point.segmentID
                    )
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(primaryLineGradient)
            }

            if !secondaryLinePoints.isEmpty {
                ForEach(secondaryLinePoints) { point in
                    LineMark(
                        x: .value(AppLocalization.string(.chartDimensionTime), point.timestamp),
                        y: .value(AppLocalization.string(.chartDimensionSecondary), point.value),
                        series: .value(
                            AppLocalization.string(.chartDimensionSeries),
                            point.segmentID
                        )
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(secondaryLineColor)
                }
            }

            if let selectedSample {
                if let baselineValue = DashboardTrendChartLayout.hoverBaselineValue(for: metric.kind) {
                    RuleMark(y: .value(AppLocalization.string(.chartDimensionBaseline), baselineValue))
                        .foregroundStyle(Color.primary.opacity(0.28))
                        .lineStyle(StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [4, 3]))
                }

                RuleMark(x: .value(AppLocalization.string(.chartDimensionSelection), selectedSample.timestamp))
                    .foregroundStyle(hoverRuleColor)
                    .lineStyle(hoverRuleStyle)

                ForEach(
                    DashboardTrendChartLayout.hoverIndicatorPoints(
                        for: selectedSample,
                        kind: metric.kind
                    )
                ) { point in
                    PointMark(
                        x: .value(AppLocalization.string(.chartDimensionSelectionTime), point.timestamp),
                        y: .value(
                            AppLocalization.string(.chartDimensionSelectionValue),
                            point.value
                        )
                    )
                    .symbolSize(hoverIndicatorSymbolSize(isCompact: isCompactHoverLayout))
                    .foregroundStyle(hoverIndicatorColor(for: point.series))
                }
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
                        updateHoverSelection(
                            location: location,
                            samples: hoverSamples,
                            xDomain: xDomain,
                            yDomain: domain,
                            plotFrame: plotFrame
                        )
                    case .ended:
                        hoveredBucketIndex = nil
                        hoverLocation = nil
                    }
                }
        }
        .frame(width: plotFrame.width, height: plotFrame.height)
        .clipped()
        .offset(x: plotFrame.minX, y: plotFrame.minY)
    }

    private func updateHoverSelection(
        location: CGPoint,
        samples: [DashboardTrendSample],
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
        plotFrame: CGRect
    ) {
        guard let selection = DashboardTrendChartLayout.hoverSelection(
            localX: location.x,
            samples: samples,
            kind: metric.kind,
            xDomain: xDomain,
            yDomain: yDomain,
            plotFrame: plotFrame
        ) else {
            hoveredBucketIndex = nil
            hoverLocation = nil
            return
        }

        hoveredBucketIndex = selection.sampleIndex
        hoverLocation = selection.location
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

    private var primaryLineGradient: LinearGradient {
        DashboardOverviewChrome.chartPrimaryLineGradient(
            baseColor: color,
            appearsActive: appearsActive
        )
    }

    private var secondaryLineColor: Color {
        let baseColor: Color = metric.kind == .network ? .red : color
        return metric.kind == .network
            ? DashboardOverviewChrome.chartSecondaryStrokeColor(
                baseColor: baseColor,
                appearsActive: appearsActive
            )
            : (
                appearsActive
                ? baseColor.opacity(0.45)
                : DashboardOverviewChrome.inactiveChartSecondaryStroke
            )
    }

    private var selectionPointColor: Color {
        let baseColor: Color = metric.kind == .network ? .red : color
        return DashboardOverviewChrome.chartSelectionPointColor(
            baseColor: baseColor,
            appearsActive: appearsActive
        )
    }

    private var powerConnectedRegionColor: Color {
        Color(red: 0.78, green: 0.88, blue: 0.76)
            .opacity(appearsActive ? 0.78 : 0.64)
    }

    private var powerConnectedIconColor: Color {
        Color(red: 0.08, green: 0.36, blue: 0.16)
    }

    private var hoverRuleColor: Color {
        metric.kind == .network ? Color.primary.opacity(0.34) : Color.primary.opacity(0.18)
    }

    private var showsPowerConnectedRegion: Bool {
        metric.kind == .battery && metric.detailRole == .batteryConnectedToPower
    }

    private func collectingPlaceholder(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    DashboardOverviewChrome.chartEmptyStrokeColor(
                        baseColor: color,
                        appearsActive: appearsActive
                    ),
                    lineWidth: 1
                )
                .overlay {
                    Text(AppLocalization.string(.dashboardTrendCollecting))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            if showsPowerConnectedRegion,
               let frame = DashboardTrendChartLayout.batteryPowerConnectedPlaceholderCapsuleFrame(in: size) {
                powerConnectedCapsuleView(
                    frame: frame,
                    iconFrame: DashboardTrendChartLayout.batteryPowerConnectedIconFrame(in: frame)
                )
            }
        }
    }

    private func powerConnectedCapsuleView(
        frame: CGRect,
        iconFrame: CGRect?
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Capsule(style: .continuous)
                .fill(powerConnectedRegionColor)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)

            if let iconFrame {
                Image(systemName: DashboardTrendChartLayout.batteryPowerConnectedIconSystemName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: iconFrame.height, weight: .semibold))
                    .foregroundStyle(powerConnectedIconColor)
                    .frame(width: iconFrame.width, height: iconFrame.height)
                    .position(x: iconFrame.midX, y: iconFrame.midY)
            }
        }
        .allowsHitTesting(false)
    }

    private var hoverRuleStyle: StrokeStyle {
        StrokeStyle(
            lineWidth: metric.kind == .network ? 1.25 : 1,
            lineCap: .round
        )
    }

    private func hoverIndicatorColor(for series: DashboardTrendLineSeries) -> Color {
        guard appearsActive else {
            return series == .primary
                ? DashboardOverviewChrome.inactiveChartPrimaryStroke
                : DashboardOverviewChrome.inactiveChartSecondaryStroke
        }

        guard metric.kind == .network else {
            return selectionPointColor
        }

        switch series {
        case .primary:
            return color.opacity(0.98)
        case .secondary:
            return .red.opacity(0.98)
        }
    }

    private func hoverIndicatorSymbolSize(isCompact: Bool) -> CGFloat {
        if metric.kind == .network {
            return isCompact ? 44 : 60
        }

        return isCompact ? 28 : 40
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

    private func hoveredBucket(
        in buckets: [DashboardTrendDisplayBucket]
    ) -> DashboardTrendDisplayBucket? {
        guard let hoveredBucketIndex,
              buckets.indices.contains(hoveredBucketIndex) else {
            return nil
        }

        return buckets[hoveredBucketIndex]
    }

    private func chartDomain(
        for samples: [DashboardTrendSample],
        scale: DashboardTrendScale
    ) -> ClosedRange<Double> {
        DashboardTrendChartLayout.valueDomain(
            for: samples,
            kind: metric.kind,
            scale: scale
        )
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
        AppLocalization.chartAxisLabel(for: metric.kind, value: value)
    }

    private func primaryReadout(for sample: DashboardTrendSample) -> String {
        AppLocalization.chartPrimaryReadout(for: metric.kind, sample: sample)
    }

    private func secondaryReadout(for sample: DashboardTrendSample) -> String? {
        AppLocalization.chartSecondaryReadout(for: metric.kind, sample: sample)
    }

    private func timestampLabel(for date: Date?) -> String {
        guard let date else {
            return "--:--"
        }

        return AppLocalization.formattedTime(date)
    }

}

enum DashboardTrendLineSeries: String, Equatable, Sendable {
    case primary
    case secondary
}

struct DashboardTrendLinePoint: Equatable, Identifiable, Sendable {
    let id: String
    let segmentID: String
    let timestamp: Date
    let value: Double
    let series: DashboardTrendLineSeries
}

struct DashboardTrendHoverSelection: Equatable {
    let sampleIndex: Int
    let location: CGPoint
}

struct DashboardTrendHoverIndicatorPoint: Equatable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let value: Double
    let series: DashboardTrendLineSeries
}

struct DashboardBatteryPowerConnectedInterval: Equatable, Identifiable, Sendable {
    let startDate: Date
    let endDate: Date

    var id: String {
        "\(startDate.timeIntervalSinceReferenceDate)-\(endDate.timeIntervalSinceReferenceDate)"
    }
}

struct DashboardBatteryPowerConnectedCapsule: Equatable, Identifiable {
    let interval: DashboardBatteryPowerConnectedInterval
    let frame: CGRect
    let iconFrame: CGRect?

    var id: String { interval.id }
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
    private static let domainContractionStep = 0.35
    static let batteryPowerConnectedCapsuleHeight: CGFloat = 8
    static let batteryPowerConnectedCapsuleTopInset: CGFloat = 3
    static let batteryPowerConnectedIconSystemName = "bolt.fill"
    private static let batteryPowerConnectedCapsuleMinimumWidth: CGFloat = 4
    private static let batteryPowerConnectedLaneBottomGap: CGFloat = 3
    private static let batteryPowerConnectedIconSize: CGFloat = 8
    private static let batteryPowerConnectedIconMinimumCapsuleWidth: CGFloat = 22

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
        let annotationX: CGFloat

        if preferredRightX <= plotFrame.maxX - boundaryPadding {
            annotationX = preferredRightX
        } else {
            annotationX = max(
                plotFrame.minX + halfWidth + boundaryPadding,
                pointer.x - horizontalSpacing - halfWidth
            )
        }

        let annotationY = min(
            max(pointer.y, plotFrame.minY + halfHeight + boundaryPadding),
            plotFrame.maxY - halfHeight - boundaryPadding
        )

        return CGPoint(x: annotationX, y: annotationY)
    }

    static func xAxisDates(for samples: [DashboardTrendSample]) -> [Date] {
        guard let first = samples.first?.timestamp,
              let last = samples.last?.timestamp else {
            return []
        }

        return uniqueDates(from: [first, last])
    }

    static func yAxisValues(for domain: ClosedRange<Double>) -> [Double] {
        let midpoint = domain.lowerBound + (domain.upperBound - domain.lowerBound) / 2
        return [domain.lowerBound, midpoint, domain.upperBound]
    }

    static func batteryPowerConnectedIntervals(
        for samples: [DashboardTrendSample],
        xDomain: ClosedRange<Date>
    ) -> [DashboardBatteryPowerConnectedInterval] {
        let orderedSamples = samples
            .filter { xDomain.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        var intervals: [DashboardBatteryPowerConnectedInterval] = []
        var connectedStart: Date?

        for (index, sample) in orderedSamples.enumerated() {
            if sample.batteryIsConnectedToPower == true {
                connectedStart = connectedStart ?? (index == 0 ? xDomain.lowerBound : sample.timestamp)
            } else if let startDate = connectedStart {
                appendPowerConnectedInterval(startDate: startDate, endDate: sample.timestamp, to: &intervals)
                connectedStart = nil
            }
        }

        if let startDate = connectedStart {
            appendPowerConnectedInterval(startDate: startDate, endDate: xDomain.upperBound, to: &intervals)
        }

        return intervals
    }

    static func batteryPowerConnectedCapsules(
        for intervals: [DashboardBatteryPowerConnectedInterval],
        xDomain: ClosedRange<Date>,
        plotFrame: CGRect
    ) -> [DashboardBatteryPowerConnectedCapsule] {
        intervals.compactMap { interval in
            let startX = xPosition(for: interval.startDate, domain: xDomain, plotFrame: plotFrame)
            let endX = xPosition(for: interval.endDate, domain: xDomain, plotFrame: plotFrame)
            let rawWidth = endX - startX
            guard rawWidth > 0, plotFrame.width > 0 else { return nil }

            let width = min(plotFrame.width, max(batteryPowerConnectedCapsuleMinimumWidth, rawWidth))
            let minX = min(max(startX, plotFrame.minX), plotFrame.maxX - width)
            let frame = CGRect(
                x: minX,
                y: plotFrame.minY + batteryPowerConnectedCapsuleTopInset,
                width: width,
                height: batteryPowerConnectedCapsuleHeight
            )
            return DashboardBatteryPowerConnectedCapsule(
                interval: interval,
                frame: frame,
                iconFrame: batteryPowerConnectedIconFrame(in: frame)
            )
        }
    }

    static func batteryPowerConnectedIconFrame(in capsuleFrame: CGRect) -> CGRect? {
        guard capsuleFrame.width >= batteryPowerConnectedIconMinimumCapsuleWidth else {
            return nil
        }

        return CGRect(
            x: capsuleFrame.midX - batteryPowerConnectedIconSize / 2,
            y: capsuleFrame.midY - batteryPowerConnectedIconSize / 2,
            width: batteryPowerConnectedIconSize,
            height: batteryPowerConnectedIconSize
        )
    }

    static func dataPlotFrame(for kind: MetricKind, plotFrame: CGRect) -> CGRect {
        guard kind == .battery else {
            return plotFrame
        }

        let reservedTop = batteryPowerConnectedCapsuleTopInset
            + batteryPowerConnectedCapsuleHeight
            + batteryPowerConnectedLaneBottomGap
        guard plotFrame.height > reservedTop else {
            return plotFrame
        }

        return CGRect(
            x: plotFrame.minX,
            y: plotFrame.minY + reservedTop,
            width: plotFrame.width,
            height: plotFrame.height - reservedTop
        )
    }

    static func batteryPowerConnectedPlaceholderCapsuleFrame(in containerSize: CGSize) -> CGRect? {
        let plotFrame = plotFrame(
            in: containerSize,
            isHovering: false,
            yAxisLabelWidth: 0,
            xAxisLabelHeight: 0
        )
        guard plotFrame.width > 0 else {
            return nil
        }

        return CGRect(
            x: plotFrame.minX,
            y: plotFrame.minY + batteryPowerConnectedCapsuleTopInset,
            width: plotFrame.width,
            height: batteryPowerConnectedCapsuleHeight
        )
    }

    private static func appendPowerConnectedInterval(
        startDate: Date,
        endDate: Date,
        to intervals: inout [DashboardBatteryPowerConnectedInterval]
    ) {
        guard endDate > startDate else { return }
        intervals.append(DashboardBatteryPowerConnectedInterval(startDate: startDate, endDate: endDate))
    }

    static func linePoints(
        for display: DashboardTrendDisplay,
        kind: MetricKind,
        series: DashboardTrendLineSeries
    ) -> [DashboardTrendLinePoint] {
        display.segments.flatMap { segment -> [DashboardTrendLinePoint] in
            var runIndex = 0
            var isInsideRun = false

            return segment.buckets.compactMap { bucket in
                let rawValue: Double?
                switch series {
                case .primary:
                    rawValue = bucket.sample.primaryValue
                case .secondary:
                    rawValue = bucket.sample.secondaryValue
                }

                guard let rawValue else {
                    if isInsideRun {
                        runIndex += 1
                        isInsideRun = false
                    }
                    return nil
                }
                isInsideRun = true
                let value = plottedValue(rawValue, kind: kind, series: series)
                let segmentBits = segment.id.timeIntervalSinceReferenceDate.bitPattern
                let bucketBits = bucket.id.timeIntervalSinceReferenceDate.bitPattern

                return DashboardTrendLinePoint(
                    id: "\(series.rawValue)-\(bucketBits)",
                    segmentID: "\(series.rawValue)-\(segmentBits)-\(runIndex)",
                    timestamp: bucket.timestamp,
                    value: value,
                    series: series
                )
            }
        }
    }

    static func valueDomain(
        for samples: [DashboardTrendSample],
        kind: MetricKind,
        scale: DashboardTrendScale
    ) -> ClosedRange<Double> {
        switch scale {
        case .fixed(let lowerBound, let upperBound):
            return lowerBound...upperBound
        case .automatic:
            let primaryValues = samples.map {
                plottedValue($0.primaryValue, kind: kind, series: .primary)
            }
            let secondaryValues = samples.compactMap { sample in
                sample.secondaryValue.map {
                    plottedValue($0, kind: kind, series: .secondary)
                }
            }
            let values = primaryValues + secondaryValues

            if kind == .network {
                let maximumMagnitude = max(values.map(abs).max() ?? 0, 1)
                let paddedMagnitude = maximumMagnitude * 1.12
                return -paddedMagnitude...paddedMagnitude
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

    static func smoothedDomain(
        previous: ClosedRange<Double>?,
        next: ClosedRange<Double>,
        kind: MetricKind
    ) -> ClosedRange<Double> {
        guard let previous, smoothsDomainChanges(for: kind) else {
            return next
        }

        if kind == .network {
            return smoothedSymmetricDomain(previous: previous, next: next)
        }

        let lowerBound = smoothedLowerBound(previous: previous.lowerBound, next: next.lowerBound)
        let upperBound = smoothedUpperBound(previous: previous.upperBound, next: next.upperBound)
        guard lowerBound < upperBound else {
            return next
        }

        return lowerBound...upperBound
    }

    private static func smoothsDomainChanges(for kind: MetricKind) -> Bool {
        switch kind {
        case .network, .temperature, .fan:
            return true
        case .cpu, .gpu, .disk, .swap, .memory, .vram, .battery:
            return false
        }
    }

    private static func smoothedSymmetricDomain(
        previous: ClosedRange<Double>,
        next: ClosedRange<Double>
    ) -> ClosedRange<Double> {
        let previousMagnitude = max(max(abs(previous.lowerBound), abs(previous.upperBound)), 1)
        let nextMagnitude = max(max(abs(next.lowerBound), abs(next.upperBound)), 1)
        let magnitude: Double
        if nextMagnitude >= previousMagnitude {
            magnitude = nextMagnitude
        } else {
            magnitude = previousMagnitude + (nextMagnitude - previousMagnitude) * domainContractionStep
        }

        return -magnitude...magnitude
    }

    private static func smoothedLowerBound(previous: Double, next: Double) -> Double {
        if next < previous {
            return next
        }

        return previous + (next - previous) * domainContractionStep
    }

    private static func smoothedUpperBound(previous: Double, next: Double) -> Double {
        if next > previous {
            return next
        }

        return previous + (next - previous) * domainContractionStep
    }

    static func selectionValue(
        for sample: DashboardTrendSample,
        kind: MetricKind
    ) -> Double {
        if kind == .network, let uploadValue = sample.secondaryValue {
            return plottedValue(uploadValue, kind: kind, series: .secondary)
        }

        return plottedValue(sample.primaryValue, kind: kind, series: .primary)
    }

    static func hoverBaselineValue(for kind: MetricKind) -> Double? {
        kind == .network ? 0 : nil
    }

    static func hoverIndicatorPoints(
        for sample: DashboardTrendSample,
        kind: MetricKind
    ) -> [DashboardTrendHoverIndicatorPoint] {
        if kind == .network {
            return [
                hoverIndicatorPoint(for: sample, kind: kind, series: .primary, value: sample.primaryValue),
                sample.secondaryValue.map {
                    hoverIndicatorPoint(for: sample, kind: kind, series: .secondary, value: $0)
                }
            ].compactMap { $0 }
        }

        return [
            hoverIndicatorPoint(for: sample, kind: kind, series: .primary, value: sample.primaryValue)
        ]
    }

    private static func hoverIndicatorPoint(
        for sample: DashboardTrendSample,
        kind: MetricKind,
        series: DashboardTrendLineSeries,
        value: Double
    ) -> DashboardTrendHoverIndicatorPoint {
        let plotted = plottedValue(value, kind: kind, series: series)
        return DashboardTrendHoverIndicatorPoint(
            id: "hover-\(series.rawValue)-\(sample.timestamp.timeIntervalSinceReferenceDate.bitPattern)-\(plotted.bitPattern)",
            timestamp: sample.timestamp,
            value: plotted,
            series: series
        )
    }

    private static func plottedValue(
        _ value: Double,
        kind: MetricKind,
        series: DashboardTrendLineSeries
    ) -> Double {
        guard kind == .network else {
            return value
        }

        switch series {
        case .primary:
            return -abs(value)
        case .secondary:
            return abs(value)
        }
    }

    static func displayPlotWidth(for containerSize: CGSize) -> CGFloat {
        plotFrame(
            in: containerSize,
            isHovering: false
        ).width
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
        atX positionX: CGFloat,
        plotFrame: CGRect,
        domain: ClosedRange<Date>
    ) -> Date {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0, plotFrame.width > 0 else {
            return domain.lowerBound
        }

        let clampedX = min(max(positionX, plotFrame.minX), plotFrame.maxX)
        let progress = (clampedX - plotFrame.minX) / plotFrame.width
        return domain.lowerBound.addingTimeInterval(span * progress)
    }

    static func hoverSelection(
        localX: CGFloat,
        samples: [DashboardTrendSample],
        kind: MetricKind = .cpu,
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
                    for: selectionValue(
                        for: selectedSample,
                        kind: kind
                    ),
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
        if count <= 1 {
            return .trailing
        }

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

        if count <= 1 {
            return plotFrame.maxX - halfWidth
        }

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

    private static func uniqueDates(from dates: [Date]) -> [Date] {
        var unique: [Date] = []

        for date in dates where !unique.contains(date) {
            unique.append(date)
        }

        return unique
    }

    static func animatesSampleChanges(for kind: MetricKind) -> Bool {
        true
    }
}
