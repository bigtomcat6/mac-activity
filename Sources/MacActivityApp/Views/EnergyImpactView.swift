import AppKit
import SwiftUI
import MacActivityCore

struct EnergyImpactView: View {
    @ObservedObject var model: EnergyImpactModel
    let refreshTrigger: Int
    let showsApplicationIdentifier: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.processListSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string(.energyImpactTitle))
                    .font(.headline)
                Text(AppLocalization.string(.energyImpactSubtitleCurrent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(AppLocalization.string(.energyImpactAppColumn))
                    Spacer()
                    Text(AppLocalization.string(.energyImpactCurrentColumn))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)

            if model.entries.isEmpty {
                Text(Self.emptyMessage(isRefreshing: model.isRefreshing))
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
                    ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                        EnergyImpactRow(
                            entry: entry,
                            rank: index + 1,
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
            await model.refreshWhileVisible()
        }
    }

    static func emptyMessage(isRefreshing: Bool, bundle: Bundle? = nil) -> String {
        if isRefreshing {
            return AppLocalization.string(.dashboardWaitingFirstSample, bundle: bundle)
        }
        return AppLocalization.string(.energyImpactEmpty, bundle: bundle)
    }
}

struct EnergyImpactRow: View {
    let entry: EnergyImpactEntry
    let rank: Int
    let showsApplicationIdentifier: Bool

    private var accessibilityLabel: String {
        EnergyImpactPresentation.accessibilityLabel(entry: entry, rank: rank)
    }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .accessibilityHidden(true)

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
                .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: ActiveProcessMemoryLayout.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var icon: some View {
        switch Self.iconSource(for: entry) {
        case .bundle(let bundleURL):
            Image(nsImage: ActiveProcessIconCache.shared.icon(for: bundleURL))
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .cornerRadius(4)
        case .fallbackSystemSymbol:
            Image(systemName: "app")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
    }

    static func iconSource(
        for entry: EnergyImpactEntry,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> ActiveProcessIconSource {
        guard let bundleURL = entry.bundleURL, fileExists(bundleURL) else {
            return .fallbackSystemSymbol
        }
        return .bundle(bundleURL)
    }

    static func trailingText(for entry: EnergyImpactEntry, bundle: Bundle? = nil) -> String {
        EnergyImpactPresentation.powerText(
            microwatts: entry.displayPowerMicrowatts,
            status: entry.status,
            bundle: bundle
        )
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
