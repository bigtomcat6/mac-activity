import Charts
import AppKit
import Foundation
import SwiftUI
import MacActivityCore

struct DashboardTrendChart: View {
    let metric: DashboardMetric
    let color: Color

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
                        Text("Collecting trend")
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
        let domain = chartDomain(for: trend)
        let xDomain = xDomain(for: trend)
        let isHovering = hoveredSample(in: trend) != nil
        let isCompactHoverLayout = DashboardCardLayout.usesCompactHoverLayout(for: size.height)
        let xAxisDates = DashboardTrendChartLayout.xAxisDates(for: trend.samples)
        let yAxisValues = DashboardTrendChartLayout.yAxisValues(for: domain)
        let yAxisLabelWidth = DashboardTrendChartLayout.yAxisLabelWidth(
            for: yAxisValues.map(axisLabel(for:))
        )
        let plotFrame = DashboardTrendChartLayout.plotFrame(
            in: size,
            isHovering: isHovering,
            yAxisLabelWidth: yAxisLabelWidth,
            xAxisLabelHeight: DashboardTrendChartLayout.xAxisLabelHeight
        )
        let showsAreaFill = DashboardTrendChartLayout.showsAreaFill(
            kind: metric.kind,
            samples: trend.samples,
            domain: domain
        )
        let sampleAnimation = DashboardTrendChartLayout.animatesSampleChanges(for: metric.kind)
        let primaryLinePoints = DashboardTrendChartLayout.linePoints(
            for: trend.samples,
            series: .primary
        )
        let secondaryLinePoints = DashboardTrendChartLayout.linePoints(
            for: trend.samples,
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
                    yAxisValues: yAxisValues
                )
            }

            Chart {
                if showsAreaFill {
                    ForEach(trend.samples, id: \.timestamp) { sample in
                        AreaMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Primary", sample.primaryValue)
                        )
                        .interpolationMethod(primaryInterpolationMethod)
                        .foregroundStyle(areaGradient)
                    }
                }

                ForEach(primaryLinePoints) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Primary", point.value),
                        series: .value("Series", point.series.rawValue)
                    )
                    .interpolationMethod(primaryInterpolationMethod)
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

                if let selectedSample = hoveredSample(in: trend) {
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
            .frame(width: plotFrame.width, height: plotFrame.height)
            .clipped()
            .offset(x: plotFrame.minX, y: plotFrame.minY)

            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .frame(width: plotFrame.width, height: plotFrame.height)
                .offset(x: plotFrame.minX, y: plotFrame.minY)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        guard !trend.samples.isEmpty else {
                            hoveredSampleIndex = nil
                            hoverLocation = nil
                            return
                        }

                        let localFrame = CGRect(origin: .zero, size: plotFrame.size)
                        let clampedLocalX = min(max(location.x, localFrame.minX), localFrame.maxX)
                        let clampedLocalY = min(max(location.y, localFrame.minY), localFrame.maxY)
                        let hoveredDate = DashboardTrendChartLayout.date(
                            atX: clampedLocalX,
                            plotFrame: localFrame,
                            domain: xDomain
                        )

                        hoveredSampleIndex = nearestSampleIndex(
                            to: hoveredDate,
                            samples: trend.samples
                        )
                        hoverLocation = CGPoint(
                            x: plotFrame.minX + clampedLocalX,
                            y: plotFrame.minY + clampedLocalY
                        )
                    case .ended:
                        hoveredSampleIndex = nil
                        hoverLocation = nil
                    }
                }

            if let selectedSample = hoveredSample(in: trend),
               let hoverLocation {
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
                        pointer: hoverLocation,
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
        yAxisValues: [Double]
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

    private var primaryInterpolationMethod: InterpolationMethod {
        switch metric.kind {
        case .fan:
            return .stepEnd
        case .network:
            return .linear
        case .cpu, .gpu, .memory, .vram, .battery, .temperature:
            return .monotone
        }
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

    private func nearestSampleIndex(
        to date: Date,
        samples: [DashboardTrendSample]
    ) -> Int {
        samples.enumerated().min { lhs, rhs in
            abs(lhs.element.timestamp.timeIntervalSince(date)) < abs(rhs.element.timestamp.timeIntervalSince(date))
        }?.offset ?? 0
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
        switch metric.kind {
        case .cpu, .gpu, .memory, .vram, .battery:
            return "\(Int(value.rounded()))%"
        case .temperature:
            return String(format: "%.1f C", value)
        case .fan:
            return "\(Int(value.rounded())) RPM"
        case .network:
            return formatRate(value)
        }
    }

    private func primaryReadout(for sample: DashboardTrendSample) -> String {
        switch metric.kind {
        case .cpu, .gpu, .memory, .vram, .battery:
            return "\(Int(sample.primaryValue.rounded()))%"
        case .temperature:
            return String(format: "%.1f C", sample.primaryValue)
        case .fan:
            return "\(Int(sample.primaryValue.rounded())) RPM"
        case .network:
            return "Down \(formatRate(sample.primaryValue))"
        }
    }

    private func secondaryReadout(for sample: DashboardTrendSample) -> String? {
        guard let secondaryValue = sample.secondaryValue, metric.kind == .network else {
            return nil
        }

        return "Up \(formatRate(secondaryValue))"
    }

    private func timestampLabel(for date: Date?) -> String {
        guard let date else {
            return "--:--"
        }

        return date.formatted(.dateTime.hour().minute())
    }

    private func formatRate(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .decimal
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return "\(formatter.string(fromByteCount: Int64(max(0, value))))/s"
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
        let leading = min(max(0, yAxisLabelWidth) + axisLabelPlotGap, maximumLeading)
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
        guard samples.count >= 2 else {
            return false
        }

        let values = samples.map(\.primaryValue)
        guard let minValue = values.min(),
              let maxValue = values.max() else {
            return false
        }

        let spread = maxValue - minValue
        let domainSpan = max(domain.upperBound - domain.lowerBound, 0.001)

        if spread <= 0.001 {
            return false
        }

        switch kind {
        case .battery, .temperature:
            return spread / domainSpan >= 0.1
        case .network:
            return false
        case .cpu, .gpu, .memory, .vram, .fan:
            return spread / domainSpan >= 0.06
        }
    }

    static func animatesSampleChanges(for kind: MetricKind) -> Bool {
        kind != .network
    }
}
