import SwiftUI
import MacActivityCore

struct TrashCleanupStatusView: View {
    @ObservedObject var model: ActiveCleanupModel

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(for: model.trashState))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(Self.subtitle(for: model.trashState))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            action
        }
        .padding(DashboardCardLayout.regularCardInsets)
        .frame(maxWidth: .infinity, minHeight: ActiveCleanReleaseLayout.trashSectionHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
    }

    @ViewBuilder
    private var action: some View {
        switch model.trashState {
        case .scanning, .cleaning:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Button(AppLocalization.string(.trashActionRetry)) {
                Task { await model.refreshTrash() }
            }
        case .cleanable:
            Button(AppLocalization.string(.trashActionClean)) {
                model.requestTrashCleanupConfirmation()
            }
            .disabled(model.isCleaningTrash)
        case .idle, .clean, .cleaned, .partial:
            EmptyView()
        }
    }

    static func title(for state: TrashState, bundle: Bundle? = nil) -> String {
        switch state {
        case .idle, .scanning:
            return AppLocalization.string(.trashTitleScanning, bundle: bundle)
        case .clean:
            return AppLocalization.string(.trashTitleClean, bundle: bundle)
        case .cleanable(let bytes, _):
            return AppLocalization.string(.trashTitleCleanable, formattedBytes(bytes), bundle: bundle)
        case .cleaning:
            return AppLocalization.string(.trashTitleCleaning, bundle: bundle)
        case .cleaned(let bytes, _):
            return AppLocalization.string(.trashTitleCleaned, formattedBytes(bytes), bundle: bundle)
        case .failed:
            return AppLocalization.string(.trashTitleFailed, bundle: bundle)
        case .partial(let bytes, _, _, _):
            return AppLocalization.string(.trashTitleCleaned, formattedBytes(bytes), bundle: bundle)
        }
    }

    static func subtitle(for state: TrashState, bundle: Bundle? = nil) -> String {
        switch state {
        case .idle, .scanning:
            return AppLocalization.string(.trashSubtitleScanning, bundle: bundle)
        case .clean:
            return AppLocalization.string(.trashSubtitleClean, bundle: bundle)
        case .cleanable(_, let itemCount):
            return AppLocalization.string(.trashSubtitleCleanable, itemCount, itemLabel(for: itemCount, bundle: bundle), bundle: bundle)
        case .cleaning:
            return AppLocalization.string(.trashSubtitleCleaning, bundle: bundle)
        case .cleaned(_, let itemCount):
            return AppLocalization.string(.trashSubtitleCleaned, itemCount, itemLabel(for: itemCount, bundle: bundle), bundle: bundle)
        case .failed(let reason):
            return failureSubtitle(for: reason, bundle: bundle)
        case .partial(_, let deletedCount, let failedCount, let remainingBytes):
            if let remainingBytes {
                return AppLocalization.string(
                    .trashSubtitlePartialWithRemaining,
                    deletedCount,
                    itemLabel(for: deletedCount, bundle: bundle),
                    failedCount,
                    itemLabel(for: failedCount, bundle: bundle),
                    formattedBytes(remainingBytes),
                    bundle: bundle
                )
            }
            return AppLocalization.string(
                .trashSubtitlePartial,
                deletedCount,
                itemLabel(for: deletedCount, bundle: bundle),
                failedCount,
                itemLabel(for: failedCount, bundle: bundle),
                bundle: bundle
            )
        }
    }

    private static func formattedBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func itemLabel(for count: Int, bundle: Bundle? = nil) -> String {
        AppLocalization.string(count == 1 ? .trashItemSingular : .trashItemPlural, bundle: bundle)
    }

    private static func failureSubtitle(for reason: TrashCleanupFailureReason, bundle: Bundle? = nil) -> String {
        switch reason {
        case .message(let message):
            return message
        case .unableToDeleteItems:
            return AppLocalization.string(.trashSubtitleFailedUnableToDeleteItems, bundle: bundle)
        }
    }
}
