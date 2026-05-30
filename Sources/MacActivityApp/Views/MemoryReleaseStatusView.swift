import SwiftUI

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

            if Self.showsProgressIndicator(for: model.memoryState) {
                ProgressView()
                    .controlSize(.small)
            }

            Button(AppLocalization.string(model.isReleasingMemory ? .memoryReleaseActionReleasing : .memoryReleaseActionRelease)) {
                Task { await model.releaseMemory() }
            }
            .disabled(model.isReleasingMemory)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: ActiveCleanReleaseLayout.memoryStripHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
    }

    static func title(for state: MemoryState, bundle: Bundle? = nil) -> String {
        switch state {
        case .idle:
            return AppLocalization.string(.memoryReleaseTitleIdle, bundle: bundle)
        case .usage(let percent):
            return AppLocalization.string(.memoryReleaseTitleUsage, Int(percent.rounded()), bundle: bundle)
        case .releasing:
            return AppLocalization.string(.memoryReleaseTitleReleasing, bundle: bundle)
        case .released(let bytes, _):
            return AppLocalization.string(.memoryReleaseTitleReleased, formattedBytes(bytes), bundle: bundle)
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
        case .released(_, let percentOfTotal):
            return AppLocalization.string(.memoryReleaseSubtitlePercentOfTotal, percentOfTotal, bundle: bundle)
        case .unavailable:
            return AppLocalization.string(.memoryReleaseSubtitleUnavailable, bundle: bundle)
        case .failed(let message):
            return message
        case .failedToReadMemory:
            return AppLocalization.string(.memoryReleaseSubtitleReadFailed, bundle: bundle)
        case .idle, .usage, .releasing:
            return AppLocalization.string(.memoryReleaseSubtitleDefault, bundle: bundle)
        }
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
}
