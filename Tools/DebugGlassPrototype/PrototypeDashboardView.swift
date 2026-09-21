import SwiftUI

enum PrototypeRange: String, CaseIterable, Identifiable {
    case hour = "1h"
    case sixHours = "6h"
    case day = "24h"

    var id: String { rawValue }
}

struct PrototypeColorValue: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

enum PrototypePalette {
    static let clearPrimaryOpacity: Double = 1
    static let clearSecondaryOpacity: Double = 0.95
    static let clearTertiaryOpacity: Double = 0.90
    static let clearChartAccent = PrototypeColorValue(red: 0.50, green: 0.78, blue: 1.0, alpha: 1)

    static func usesClearReadability(for foreground: PrototypeForegroundStyle) -> Bool {
        foreground == .clearLight
    }

    static func primary(for foreground: PrototypeForegroundStyle) -> Color {
        usesClearReadability(for: foreground)
            ? Color.white.opacity(clearPrimaryOpacity)
            : Color.primary
    }

    static func secondary(for foreground: PrototypeForegroundStyle) -> Color {
        usesClearReadability(for: foreground)
            ? Color.white.opacity(clearSecondaryOpacity)
            : Color.secondary
    }

    static func tertiary(for foreground: PrototypeForegroundStyle) -> AnyShapeStyle {
        usesClearReadability(for: foreground)
            ? AnyShapeStyle(Color.white.opacity(clearTertiaryOpacity))
            : AnyShapeStyle(HierarchicalShapeStyle.tertiary)
    }

    static func chartAccent(for foreground: PrototypeForegroundStyle) -> Color {
        usesClearReadability(for: foreground) ? clearChartAccent.color : Color.accentColor
    }
}

@available(macOS 26.0, *)
struct PrototypeDashboardView: View {
    let resolution: PrototypeResolution
    let onQuit: () -> Void

    @State private var load: Double = 0.42
    @State private var range: PrototypeRange = .hour
    @State private var refreshCount = 0

    private static let syntheticSamples: [CGFloat] = [
        0.28, 0.42, 0.35, 0.58, 0.47, 0.66, 0.52, 0.74, 0.61, 0.70, 0.55, 0.68,
    ]

    private var appearance: PrototypeAppearanceConfig { resolution.appearance }
    private var foreground: PrototypeForegroundStyle { appearance.foreground }

    var body: some View {
        paletteAdjusted {
            GlassEffectContainer(spacing: 0) {
                VStack(spacing: 8) {
                    headerModule
                    cpuModule
                    memoryModule
                    controlsModule
                    footerModule
                }
                .padding(10)
                .frame(width: PrototypeLayout.contentWidth)
            }
            .frame(width: PrototypeLayout.contentWidth)
        }
    }

    @ViewBuilder
    private func paletteAdjusted<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if PrototypePalette.usesClearReadability(for: foreground) {
            content()
                .environment(\.colorScheme, .dark)
                .foregroundStyle(PrototypePalette.primary(for: foreground))
        } else {
            content()
        }
    }

    private var headerModule: some View {
        module {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacActivity")
                        .font(.headline)
                    Text("Synthetic dashboard · prototype host")
                        .font(.caption)
                        .foregroundStyle(PrototypePalette.secondary(for: foreground))
                    Text(modeDescription)
                        .font(.caption2)
                        .foregroundStyle(PrototypePalette.tertiary(for: foreground))
                }
                Spacer(minLength: 8)
                Text("PROTOTYPE")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
            }
        }
    }

    private var cpuModule: some View {
        module {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU")
                        .font(.caption)
                        .foregroundStyle(PrototypePalette.secondary(for: foreground))
                    Text("\(Int(load * 100))%")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                PrototypeSparkline(samples: Self.syntheticSamples)
                    .stroke(
                        PrototypePalette.chartAccent(for: foreground),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 180, height: 44)
            }
        }
    }

    private var memoryModule: some View {
        module {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Memory")
                        .font(.caption)
                        .foregroundStyle(PrototypePalette.secondary(for: foreground))
                    Spacer()
                    Text("8.4 / 16 GB")
                        .font(.callout.monospacedDigit())
                }
                ProgressView(value: 0.53)
                    .progressViewStyle(.linear)
                Text("Synthetic value — no real sampling")
                    .font(.caption2)
                    .foregroundStyle(PrototypePalette.tertiary(for: foreground))
            }
        }
    }

    private var controlsModule: some View {
        module {
            VStack(alignment: .leading, spacing: 10) {
                Slider(value: $load, in: 0...1) {
                    Text("Synthetic load")
                }
                Picker("Range", selection: $range) {
                    ForEach(PrototypeRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Menu {
                        ForEach(PrototypeRange.allCases) { range in
                            Button(range.rawValue) {
                                self.range = range
                            }
                        }
                    } label: {
                        Label("Native menu", systemImage: "ellipsis.circle")
                    }
                    .fixedSize()
                    Spacer()
                    Text("Real NSMenu popup for menu-tracking dismissal")
                        .font(.caption2)
                        .foregroundStyle(PrototypePalette.tertiary(for: foreground))
                }
                HStack(spacing: 10) {
                    Button("Refresh synthetic data") {
                        refreshCount += 1
                        load = min(1, max(0, load + 0.05))
                    }
                    Spacer()
                    Text("refreshes: \(refreshCount)")
                        .font(.caption2)
                        .foregroundStyle(PrototypePalette.tertiary(for: foreground))
                        .monospacedDigit()
                }
            }
        }
    }

    private var footerModule: some View {
        module {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Synthetic prototype — no audio, cleanup, or providers")
                        .font(.caption2)
                        .foregroundStyle(PrototypePalette.secondary(for: foreground))
                    if let disclosure = readabilityDisclosure {
                        Text(disclosure)
                            .font(.caption2)
                            .foregroundStyle(PrototypePalette.tertiary(for: foreground))
                    }
                }
                Spacer(minLength: 8)
                Button("Quit Prototype", action: onQuit)
            }
        }
    }

    private var modeDescription: String {
        guard resolution.effectiveMode != resolution.requestedMode else {
            return resolution.requestedMode.displayName
        }
        return "\(resolution.requestedMode.displayName) → \(resolution.effectiveMode.displayName)"
    }

    private var readabilityDisclosure: String? {
        if resolution.effectiveMode != resolution.requestedMode {
            return "Reduce Transparency: standard popover host, system material"
        }
        guard appearance.usesClearReadability else { return nil }
        let percent = Int((appearance.moduleBackingOpacity * 100).rounded())
        return "Module dimming: \(percent)% flat (non-blurring)"
    }

    private func moduleGlass() -> Glass {
        switch appearance.glassKind {
        case .regular:
            return .regular
        case .clear:
            return .clear
        }
    }

    private func module<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return content()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color.black.opacity(appearance.moduleBackingOpacity)))
            .glassEffect(moduleGlass(), in: shape)
            .overlay(
                shape.strokeBorder(
                    PrototypePalette.primary(for: foreground).opacity(appearance.strokeOpacity),
                    lineWidth: 0.5
                )
            )
    }
}

struct PrototypeSparkline: Shape {
    let samples: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1, rect.width > 0, rect.height > 0 else { return path }

        let stepX = rect.width / CGFloat(samples.count - 1)
        for (index, sample) in samples.enumerated() {
            let clamped = min(max(sample, 0), 1)
            let point = CGPoint(
                x: rect.minX + stepX * CGFloat(index),
                y: rect.maxY - rect.height * clamped
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}
