import SwiftUI

enum MemoryReleaseTrailingAction: Equatable {
    case button(title: String)
    case progressIndicator
}

struct MemoryReleaseStatusView: View {
    @ObservedObject var model: ActiveCleanupModel

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(for: model.memoryState))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(Self.subtitle(for: model.memoryState))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            switch Self.trailingAction(isReleasingMemory: model.isReleasingMemory) {
            case .button(let title):
                Button(title) {
                    Task { await model.releaseMemory() }
                }
                .frame(minWidth: Self.releaseActionWidth, alignment: .trailing)
            case .progressIndicator:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: Self.releaseActionWidth, alignment: .center)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: ActiveCleanReleaseLayout.memoryStripHeight, alignment: .leading)
        .activeCleanupCardChrome()
    }

    static func title(for state: MemoryState, bundle: Bundle? = nil) -> String {
        switch state {
        case .idle:
            return AppLocalization.string(.memoryReleaseTitleIdle, bundle: bundle)
        case .usage(_, let releasableBytes):
            return AppLocalization.string(.memoryReleaseTitleReclaimable, formattedBytes(releasableBytes), bundle: bundle)
        case .releasing:
            return AppLocalization.string(.memoryReleaseTitleReleasing, bundle: bundle)
        case .released(let bytes, _):
            return AppLocalization.string(.memoryReleaseTitleReleased, formattedBytes(bytes), bundle: bundle)
        case .noSignificantRelease:
            return AppLocalization.string(.memoryReleaseTitleNoSignificantRelease, bundle: bundle)
        case .cooldown:
            return AppLocalization.string(.memoryReleaseTitleCooldown, bundle: bundle)
        case .unavailable:
            return AppLocalization.string(.memoryReleaseTitleUnavailable, bundle: bundle)
        case .failed:
            return AppLocalization.string(.memoryReleaseTitleFailed, bundle: bundle)
        case .failedToReadMemory:
            return AppLocalization.string(.memoryReleaseTitleReadFailed, bundle: bundle)
        }
    }

    static func subtitle(for state: MemoryState, bundle: Bundle? = nil) -> String {
        switch state {
        case .usage(let percent, _):
            return AppLocalization.string(.memoryReleaseSubtitleUsage, Int(percent.rounded()), bundle: bundle)
        case .released(_, let percentOfTotal):
            return AppLocalization.string(.memoryReleaseSubtitlePercentOfTotal, percentOfTotal, bundle: bundle)
        case .noSignificantRelease:
            return AppLocalization.string(.memoryReleaseSubtitleNoSignificantRelease, bundle: bundle)
        case .cooldown(let remainingSeconds):
            return AppLocalization.string(.memoryReleaseSubtitleCooldown, remainingSeconds, bundle: bundle)
        case .unavailable:
            return AppLocalization.string(.memoryReleaseSubtitleUnavailable, bundle: bundle)
        case .failed(let message):
            return message
        case .failedToReadMemory:
            return AppLocalization.string(.memoryReleaseSubtitleReadFailed, bundle: bundle)
        case .idle, .releasing:
            return AppLocalization.string(.memoryReleaseSubtitleDefault, bundle: bundle)
        }
    }

    static func trailingAction(isReleasingMemory: Bool, bundle: Bundle? = nil) -> MemoryReleaseTrailingAction {
        if isReleasingMemory {
            return .progressIndicator
        }

        return .button(title: AppLocalization.string(.memoryReleaseActionRelease, bundle: bundle))
    }

    static func showsProgressIndicator(for state: MemoryState) -> Bool {
        if case .releasing = state {
            return true
        }
        return false
    }

    private static func formattedBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static let releaseActionWidth: CGFloat = 72
}
