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

                ZStack(alignment: .topLeading) {
                    if metric.kind != .network {
                        fillPath(
                            in: proxy.size,
                            samples: trend.samples,
                            domain: domain
                        )
                        .fill(color.opacity(0.14))
                    }

                    linePath(
                        in: proxy.size,
                        samples: trend.samples,
                        value: { $0.primaryValue },
                        domain: domain
                    )
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    if trend.samples.contains(where: { $0.secondaryValue != nil }) {
                        linePath(
                            in: proxy.size,
                            samples: trend.samples,
                            value: { $0.secondaryValue },
                            domain: domain
                        )
                        .stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }

                    if let selectedSample = hoveredSample(in: trend) {
                        hoverOverlay(
                            in: proxy.size,
                            trend: trend,
                            domain: domain,
                            selectedSample: selectedSample
                        )
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        hoveredSampleIndex = selectedIndex(
                            for: location.x,
                            sampleCount: trend.samples.count,
                            width: proxy.size.width
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

    private func hoverOverlay(
        in size: CGSize,
        trend: DashboardTrend,
        domain: ClosedRange<Double>,
        selectedSample: DashboardTrendSample
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(axisEntries(for: size, domain: domain), id: \.label) { entry in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: entry.y))
                    path.addLine(to: CGPoint(x: size.width, y: entry.y))
                }
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)

                Text(entry.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .position(x: 24, y: max(10, min(entry.y - 8, size.height - 10)))
            }

            Path { path in
                let x = xPosition(for: selectedSample, in: trend.samples, width: size.width)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            .stroke(Color.primary.opacity(0.14), lineWidth: 1)

            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .position(
                    x: xPosition(for: selectedSample, in: trend.samples, width: size.width),
                    y: yPosition(for: selectedSample.primaryValue, domain: domain, height: size.height)
                )

            VStack(spacing: 2) {
                Text(primaryReadout(for: selectedSample))
                    .font(.headline.monospacedDigit().weight(.semibold))

                if let secondaryText = secondaryReadout(for: selectedSample) {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(timestampLabel(for: selectedSample.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            HStack {
                Text(timestampLabel(for: trend.samples.first?.timestamp))
                Spacer()
                Text(timestampLabel(for: trend.samples[trend.samples.count / 2].timestamp))
                Spacer()
                Text(timestampLabel(for: trend.samples.last?.timestamp))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxHeight: .infinity, alignment: .bottom)
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

    private func selectedIndex(for locationX: CGFloat, sampleCount: Int, width: CGFloat) -> Int {
        guard sampleCount > 1, width > 0 else {
            return 0
        }

        let normalized = min(max(locationX / width, 0), 1)
        return min(max(Int(round(normalized * CGFloat(sampleCount - 1))), 0), sampleCount - 1)
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

    private func axisEntries(for size: CGSize, domain: ClosedRange<Double>) -> [AxisEntry] {
        let midpoint = domain.lowerBound + (domain.upperBound - domain.lowerBound) / 2
        return [
            AxisEntry(label: axisLabel(for: domain.upperBound), y: 14),
            AxisEntry(label: axisLabel(for: midpoint), y: size.height / 2),
            AxisEntry(label: axisLabel(for: domain.lowerBound), y: max(18, size.height - 22)),
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

private struct AxisEntry {
    let label: String
    let y: CGFloat
}
