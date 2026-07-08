import AppKit
import SwiftUI
import MacActivityCore

struct EnergyImpactView: View {
    @ObservedObject var model: EnergyImpactModel
    let refreshTrigger: Int
    let showsApplicationIdentifier: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.processListSpacing) {
            if model.entries.isEmpty {
                Text(AppLocalization.string(.energyImpactEmpty))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: ActiveProcessMemoryLayout.rowHeight,
                        alignment: .leading
                    )
                    .padding(.horizontal, 12)
            } else {
                VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.processListSpacing) {
                    ForEach(model.entries) { entry in
                        EnergyImpactRow(
                            entry: entry,
                            showsApplicationIdentifier: showsApplicationIdentifier
                        )
                    }
                }
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: ActiveProcessMemoryLayout.outerCornerRadius,
                        style: .continuous
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: refreshTrigger) {
            model.refresh()
        }
    }
}

struct EnergyImpactRow: View {
    @Environment(\.appearsActive) private var appearsActive
    let entry: EnergyImpactEntry
    let showsApplicationIdentifier: Bool
    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            let progressWidth = proxy.size.width * CGFloat(min(max(entry.impact / 100.0, 0), 1))

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(ActiveCleanupChrome.progressFillColor(appearsActive: appearsActive))
                    .frame(width: progressWidth)

                HStack(spacing: 10) {
                    icon

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)

                        if let identifier = Self.identifierText(
                            for: entry,
                            showsApplicationIdentifier: showsApplicationIdentifier
                        ) {
                            Text(identifier)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(Self.trailingText(for: entry))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: ActiveProcessMemoryLayout.trailingActionWidth, alignment: .trailing)
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: ActiveProcessMemoryLayout.rowHeight)
        .background(isHovered ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .onHover { isHovered = $0 }
        .clipped()
    }

    @ViewBuilder
    private var icon: some View {
        if let bundleURL = entry.bundleURL, FileManager.default.fileExists(atPath: bundleURL.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundleURL.path))
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .cornerRadius(4)
        } else {
            Image(systemName: "app")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
    }

    static func trailingText(for entry: EnergyImpactEntry, bundle: Bundle? = nil) -> String {
        guard entry.isReadable else {
            return AppLocalization.string(.energyImpactUnavailable, bundle: bundle)
        }
        return entry.formattedImpact
    }

    static func identifierText(
        for entry: EnergyImpactEntry,
        showsApplicationIdentifier: Bool,
        bundle: Bundle? = nil
    ) -> String? {
        guard showsApplicationIdentifier else { return nil }
        return entry.bundleIdentifier
            ?? AppLocalization.string(.processFallbackName, Int(entry.processIdentifier), bundle: bundle)
    }
}
