import SwiftUI
import MacActivityCore

struct DashboardView: View {
    @ObservedObject var dashboardModel: DashboardModel
    let openPreferences: () -> Void
    let quitApplication: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], 18)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                if dashboardModel.metrics.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(dashboardModel.metrics) { metric in
                            MetricCard(metric: metric)
                        }
                    }
                    .padding(18)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button("Preferences", action: openPreferences)
                Spacer(minLength: 12)
                Button("Quit", action: quitApplication)
            }
            .padding(14)
            .background(.bar)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Mac Activity")
                    .font(.headline)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("Live")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
    }

    private var summaryText: String {
        let visible = dashboardModel.metrics.prefix(3).map { metric in
            "\(metric.title) \(metric.value)"
        }
        return visible.isEmpty ? "Waiting for the first sample" : visible.joined(separator: " · ")
    }

    private var emptyState: some View {
        Text("Waiting for the first metric sample.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 260)
            .padding(18)
    }
}

private struct MetricCard: View {
    let metric: DashboardMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(metric.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(metric.value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            switch metric.style {
            case .progress:
                ProgressView(value: metric.progress ?? 0)
                    .tint(color)
                    .controlSize(.small)
            case .sparkline:
                NetworkSparkline(points: metric.trend, color: color)
                    .frame(height: 44)
            case .value:
                Rectangle()
                    .fill(color.opacity(0.14))
                    .frame(height: 4)
                    .clipShape(Capsule())
            }

            if let detail = metric.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: metric.style == .sparkline ? 118 : 96, alignment: .topLeading)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }

    private var color: Color {
        switch metric.kind {
        case .cpu:
            return .orange
        case .memory:
            return .blue
        case .network:
            return .teal
        case .battery:
            return .green
        case .temperature:
            return .red
        case .fan:
            return .indigo
        }
    }
}

private struct NetworkSparkline: View {
    let points: [NetworkTrendPoint]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            if points.count < 2 {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(color.opacity(0.35), lineWidth: 1)
                    .overlay {
                        Text("Collecting trend")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            } else {
                ZStack {
                    linePath(
                        in: proxy.size,
                        values: points.map(\.downloadBytesPerSecond),
                        maximum: maximumRate
                    )
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    linePath(
                        in: proxy.size,
                        values: points.map(\.uploadBytesPerSecond),
                        maximum: maximumRate
                    )
                    .stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private var maximumRate: Double {
        max(
            points.map(\.downloadBytesPerSecond).max() ?? 1,
            points.map(\.uploadBytesPerSecond).max() ?? 1,
            1
        )
    }

    private func linePath(in size: CGSize, values: [Double], maximum: Double) -> Path {
        var path = Path()
        guard values.count > 1 else {
            return path
        }

        for (index, value) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = CGFloat(min(max(value / maximum, 0), 1))
            let y = size.height - (size.height * normalized)
            let point = CGPoint(x: x, y: y)

            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
    }
}
