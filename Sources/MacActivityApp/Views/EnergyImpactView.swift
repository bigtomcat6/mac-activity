import AppKit
import SwiftUI
import MacActivityCore

struct EnergyImpactRefreshTaskID: Equatable {
    let trigger: Int
    let scope: EnergyImpactAppScope
}

struct EnergyImpactView: View {
    @ObservedObject var model: EnergyImpactModel
    let refreshTrigger: Int
    var scope: EnergyImpactAppScope = .regularOnly
    let showsApplicationIdentifier: Bool

    @State private var showsInfoPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.processListSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(AppLocalization.string(.energyImpactTitle))
                        .font(.headline)
                    Spacer()
                    Button {
                        showsInfoPopover.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(AppLocalization.string(.energyImpactInfo))
                    .popover(isPresented: $showsInfoPopover) {
                        Text(AppLocalization.string(.energyImpactExplanation))
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 260, alignment: .leading)
                            .padding(12)
                    }
                }
                Text(AppLocalization.string(.energyImpactSubtitleSustained))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let coverageText = Self.coverageText(model: model) {
                    Text(coverageText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(AppLocalization.string(.energyImpactAppColumn))
                    Spacer()
                    Text(AppLocalization.string(.energyImpactSustainedColumn))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)

            if model.entries.isEmpty {
                Text(Self.emptyMessage(isRefreshing: model.isRefreshing, scope: scope))
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
        .task(id: EnergyImpactRefreshTaskID(trigger: refreshTrigger, scope: scope)) {
            await model.refreshWhileVisible(scope: scope)
        }
    }

    static func emptyMessage(
        isRefreshing: Bool,
        scope: EnergyImpactAppScope = .regularOnly,
        bundle: Bundle? = nil
    ) -> String {
        if isRefreshing {
            return AppLocalization.string(.dashboardWaitingFirstSample, bundle: bundle)
        }
        switch scope {
        case .regularOnly:
            return AppLocalization.string(.energyImpactEmpty, bundle: bundle)
        case .regularAndAccessory:
            return AppLocalization.string(.energyImpactEmptyExpanded, bundle: bundle)
        }
    }

    @MainActor
    static func coverageText(model: EnergyImpactModel, bundle: Bundle? = nil) -> String? {
        guard model.hasReceivedObservation else { return nil }
        let readable = model.entries.reduce(0) { $0 + $1.coverage.readableProcessCount }
        let discovered = model.entries.reduce(0) { $0 + $1.coverage.discoveredProcessCount }
        return "\(EnergyImpactPresentation.coverageText(readable: readable, discovered: discovered, bundle: bundle)) · \(AppLocalization.string(.energyImpactCheckedNow, bundle: bundle))"
    }
}

struct EnergyImpactRow: View {
    let entry: EnergyImpactEntry
    let rank: Int
    let showsApplicationIdentifier: Bool

    private var presentation: EnergyImpactRowPresentation {
        EnergyImpactPresentation.row(entry: entry, rank: rank)
    }

    var body: some View {
        HStack(spacing: 10) {
            icon
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let accessoryBadgeText = presentation.accessoryBadgeText {
                        Text(accessoryBadgeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
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

            HStack(spacing: 4) {
                Text(presentation.primaryValue)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let statusText = presentation.statusText {
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let trendSymbol = presentation.trendSymbol {
                    Image(systemName: trendSymbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: ActiveProcessMemoryLayout.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
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
