import Foundation
import SwiftUI
import MacActivityCore

struct DashboardTrendChart: View {
    let metric: DashboardMetric
    let color: Color

    @State private var hoveredSampleIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            if let trend = metric.trend, trend.samples.count >= 2 {
                let domain = chartDomain(for: trend)
                let isHovering = hoveredSampleIndex != nil
                let basePlotRect = DashboardTrendChartGeometry.basePlotRect(in: proxy.size)
                let plotRect = DashboardTrendChartGeometry.plotRect(
                    in: proxy.size,
                    isHovering: isHovering
                )
                let plotScale = CGSize(
                    width: plotRect.width / basePlotRect.width,
                    height: plotRect.height / basePlotRect.height
                )

                ZStack(alignment: .topLeading) {
                    plotArea(
                        in: basePlotRect.size,
                        trend: trend,
                        domain: domain
                    )
                    .frame(width: basePlotRect.width, height: basePlotRect.height)
                    .scaleEffect(x: plotScale.width, y: plotScale.height, anchor: .topTrailing)
                    .offset(x: basePlotRect.minX, y: basePlotRect.minY)

                    if let selectedSample = hoveredSample(in: trend) {
                        hoverOverlay(
                            in: proxy.size,
                            plotRect: plotRect,
                            trend: trend,
                            domain: domain,
                            selectedSample: selectedSample
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.16), value: isHovering)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        hoveredSampleIndex = DashboardTrendChartGeometry.selectedIndex(
                            for: location.x,
                            sampleCount: trend.samples.count,
                            plotRect: plotRect
                        )
                    case .ended:
                        hoveredSampleIndex = nil
                    }
                }
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

    @ViewBuilder
    private func plotArea(
        in size: CGSize,
        trend: DashboardTrend,
        domain: ClosedRange<Double>
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if metric.kind != .network {
                fillPath(
                    in: size,
                    samples: trend.samples,
                    domain: domain
                )
                .fill(color.opacity(0.14))
            }

            linePath(
                in: size,
                samples: trend.samples,
                value: { $0.primaryValue },
                domain: domain
            )
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if trend.samples.contains(where: { $0.secondaryValue != nil }) {
                linePath(
                    in: size,
                    samples: trend.samples,
                    value: { $0.secondaryValue },
                    domain: domain
                )
                .stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func hoverOverlay(
        in size: CGSize,
        plotRect: CGRect,
        trend: DashboardTrend,
        domain: ClosedRange<Double>,
        selectedSample: DashboardTrendSample
    ) -> some View {
        let selectedX = plotRect.minX + xPosition(
            for: selectedSample,
            in: trend.samples,
            width: plotRect.width
        )
        let selectedY = plotRect.minY + yPosition(
            for: selectedSample.primaryValue,
            domain: domain,
            height: plotRect.height
        )
        let axisLabelWidth = max(42, plotRect.minX - 8)

        return ZStack(alignment: .topLeading) {
            ForEach(axisEntries(for: plotRect, domain: domain)) { entry in
                Path { path in
                    path.move(to: CGPoint(x: plotRect.minX, y: entry.y))
                    path.addLine(to: CGPoint(x: plotRect.maxX, y: entry.y))
                }
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)

                Text(entry.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(width: axisLabelWidth, alignment: .trailing)
                    .position(x: axisLabelWidth / 2, y: entry.y)
            }

            Path { path in
                path.move(to: CGPoint(x: selectedX, y: plotRect.minY))
                path.addLine(to: CGPoint(x: selectedX, y: plotRect.maxY))
            }
            .stroke(Color.primary.opacity(0.14), lineWidth: 1)

            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .position(x: selectedX, y: selectedY)

            VStack(spacing: 2) {
                Text(primaryReadout(for: selectedSample))
                    .font(.headline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let secondaryText = secondaryReadout(for: selectedSample) {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Text(timestampLabel(for: selectedSample.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: plotRect.width)
            .position(x: plotRect.midX, y: max(18, plotRect.minY / 2 + 4))

            HStack {
                Text(timestampLabel(for: trend.samples.first?.timestamp))
                Spacer()
                Text(timestampLabel(for: trend.samples[trend.samples.count / 2].timestamp))
                Spacer()
                Text(timestampLabel(for: trend.samples.last?.timestamp))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(width: plotRect.width)
            .position(x: plotRect.midX, y: min(size.height - 8, plotRect.maxY + 14))
        }
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

    private func linePath(
        in size: CGSize,
        samples: [DashboardTrendSample],
        value: (DashboardTrendSample) -> Double?,
        domain: ClosedRange<Double>
    ) -> Path {
        var path = Path()
        var started = false

        for (index, sample) in samples.enumerated() {
            guard let pointValue = value(sample) else {
                continue
            }

            let point = CGPoint(
                x: xPosition(for: index, sampleCount: samples.count, width: size.width),
                y: yPosition(for: pointValue, domain: domain, height: size.height)
            )

            if started {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                started = true
            }
        }

        return path
    }

    private func fillPath(
        in size: CGSize,
        samples: [DashboardTrendSample],
        domain: ClosedRange<Double>
    ) -> Path {
        var path = linePath(
            in: size,
            samples: samples,
            value: { $0.primaryValue },
            domain: domain
        )

        guard samples.count >= 2 else {
            return path
        }

        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }

    private func xPosition(for sample: DashboardTrendSample, in samples: [DashboardTrendSample], width: CGFloat) -> CGFloat {
        guard let index = samples.firstIndex(of: sample) else {
            return 0
        }

        return xPosition(for: index, sampleCount: samples.count, width: width)
    }

    private func xPosition(for index: Int, sampleCount: Int, width: CGFloat) -> CGFloat {
        guard sampleCount > 1 else {
            return 0
        }

        return width * CGFloat(index) / CGFloat(sampleCount - 1)
    }

    private func yPosition(for value: Double, domain: ClosedRange<Double>, height: CGFloat) -> CGFloat {
        guard domain.upperBound > domain.lowerBound else {
            return height / 2
        }

        let normalized = (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
        return height - CGFloat(min(max(normalized, 0), 1)) * height
    }

    private func axisEntries(for plotRect: CGRect, domain: ClosedRange<Double>) -> [AxisEntry] {
        let midpoint = domain.lowerBound + (domain.upperBound - domain.lowerBound) / 2
        return [
            AxisEntry(id: 0, label: axisLabel(for: domain.upperBound), y: plotRect.minY),
            AxisEntry(id: 1, label: axisLabel(for: midpoint), y: plotRect.midY),
            AxisEntry(id: 2, label: axisLabel(for: domain.lowerBound), y: plotRect.maxY),
        ]
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

struct DashboardTrendChartGeometry {
    private static let baseInsets = ChartInsets(top: 4, leading: 0, bottom: 4, trailing: 8)
    private static let hoverReservedSpace = HoverReservedSpace(leading: 58, bottom: 24)

    static func basePlotRect(in size: CGSize) -> CGRect {
        let width = max(1, size.width - baseInsets.leading - baseInsets.trailing)
        let height = max(1, size.height - baseInsets.top - baseInsets.bottom)

        return CGRect(
            x: baseInsets.leading,
            y: baseInsets.top,
            width: width,
            height: height
        )
    }

    static func plotRect(in size: CGSize, isHovering: Bool) -> CGRect {
        let basePlotRect = basePlotRect(in: size)
        guard isHovering else {
            return basePlotRect
        }

        let width = max(1, basePlotRect.width - hoverReservedSpace.leading)
        let height = max(1, basePlotRect.height - hoverReservedSpace.bottom)

        return CGRect(
            x: basePlotRect.maxX - width,
            y: basePlotRect.minY,
            width: width,
            height: height
        )
    }

    static func selectedIndex(for locationX: CGFloat, sampleCount: Int, plotRect: CGRect) -> Int {
        guard sampleCount > 1, plotRect.width > 0 else {
            return 0
        }

        let normalized = min(max((locationX - plotRect.minX) / plotRect.width, 0), 1)
        return min(max(Int(round(normalized * CGFloat(sampleCount - 1))), 0), sampleCount - 1)
    }
}

private struct ChartInsets {
    let top: CGFloat
    let leading: CGFloat
    let bottom: CGFloat
    let trailing: CGFloat
}

private struct HoverReservedSpace {
    let leading: CGFloat
    let bottom: CGFloat
}

private struct AxisEntry: Identifiable {
    let id: Int
    let label: String
    let y: CGFloat
}
