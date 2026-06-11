import SwiftUI
import MacActivityCore

enum DiskCleanupTrailingAction: Equatable {
    case button(title: String)
    case progressIndicator
}

struct DiskCleanupStatusView: View {
    @ObservedObject var model: ActiveCleanupModel

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(for: model.diskCleanupState))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(Self.subtitle(for: model.diskCleanupState))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: ActiveCleanReleaseLayout.diskCleanupStripHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        )
    }

    @ViewBuilder
    private var action: some View {
        switch model.diskCleanupState {
        case .scanning, .cleaning:
            ProgressView()
                .controlSize(.small)
                .frame(width: Self.actionWidth, alignment: .center)
        case .failed:
            Button(AppLocalization.string(.diskCleanupActionRetry)) {
                Task { await model.refreshDiskCleanup() }
            }
            .frame(minWidth: Self.actionWidth, alignment: .trailing)
        case .cleanable:
            Button(AppLocalization.string(.diskCleanupActionClean)) {
                model.requestDiskCleanupConfirmation()
            }
            .disabled(model.isCleaningDiskCleanup)
            .frame(minWidth: Self.actionWidth, alignment: .trailing)
        case .idle, .clean, .cleaned, .partial:
            EmptyView()
        }
    }

    static func title(for state: DiskCleanupState, bundle: Bundle? = nil) -> String {
        switch state {
        case .idle, .scanning:
            return AppLocalization.string(.diskCleanupTitleScanning, bundle: bundle)
        case .clean:
            return AppLocalization.string(.diskCleanupTitleClean, bundle: bundle)
        case .cleanable(let bytes, _, _):
            return AppLocalization.string(.diskCleanupTitleCleanable, formattedBytes(bytes), bundle: bundle)
        case .cleaning:
            return AppLocalization.string(.diskCleanupTitleCleaning, bundle: bundle)
        case .cleaned(let bytes, _):
            return AppLocalization.string(.diskCleanupTitleCleaned, formattedBytes(bytes), bundle: bundle)
        case .failed:
            return AppLocalization.string(.diskCleanupTitleFailed, bundle: bundle)
        case .partial(let bytes, _, _, _):
            return AppLocalization.string(.diskCleanupTitleCleaned, formattedBytes(bytes), bundle: bundle)
        }
    }

    static func subtitle(for state: DiskCleanupState, bundle: Bundle? = nil) -> String {
        switch state {
        case .idle, .scanning:
            return AppLocalization.string(.diskCleanupSubtitleScanning, bundle: bundle)
        case .clean:
            return AppLocalization.string(.diskCleanupSubtitleClean, bundle: bundle)
        case .cleanable(_, let itemCount, let categories):
            return AppLocalization.string(
                .diskCleanupSubtitleCleanable,
                itemCount,
                itemLabel(for: itemCount, bundle: bundle),
                categoryList(for: categories, bundle: bundle),
                bundle: bundle
            )
        case .cleaning:
            return AppLocalization.string(.diskCleanupSubtitleCleaning, bundle: bundle)
        case .cleaned(_, let itemCount):
            return AppLocalization.string(.diskCleanupSubtitleCleaned, itemCount, itemLabel(for: itemCount, bundle: bundle), bundle: bundle)
        case .failed(let message):
            return message
        case .partial(_, let deletedCount, let failedCount, let remainingBytes):
            if let remainingBytes {
                return AppLocalization.string(
                    .diskCleanupSubtitlePartialWithRemaining,
                    deletedCount,
                    itemLabel(for: deletedCount, bundle: bundle),
                    failedCount,
                    itemLabel(for: failedCount, bundle: bundle),
                    formattedBytes(remainingBytes),
                    bundle: bundle
                )
            }
            return AppLocalization.string(
                .diskCleanupSubtitlePartial,
                deletedCount,
                itemLabel(for: deletedCount, bundle: bundle),
                failedCount,
                itemLabel(for: failedCount, bundle: bundle),
                bundle: bundle
            )
        }
    }

    static func trailingAction(isCleaningDiskCleanup: Bool, bundle: Bundle? = nil) -> DiskCleanupTrailingAction {
        if isCleaningDiskCleanup {
            return .progressIndicator
        }

        return .button(title: AppLocalization.string(.diskCleanupActionClean, bundle: bundle))
    }

    static func showsProgressIndicator(for state: DiskCleanupState) -> Bool {
        switch state {
        case .scanning, .cleaning:
            return true
        case .idle, .clean, .cleanable, .cleaned, .failed, .partial:
            return false
        }
    }

    private static func formattedBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func itemLabel(for count: Int, bundle: Bundle? = nil) -> String {
        AppLocalization.string(count == 1 ? .diskCleanupItemSingular : .diskCleanupItemPlural, bundle: bundle)
    }

    private static func categoryList(for categories: [DiskCleanupCategoryKind], bundle: Bundle? = nil) -> String {
        categories
            .map { AppLocalization.diskCleanupCategoryTitle(for: $0, bundle: bundle) }
            .joined(separator: categoryListSeparator(for: bundle))
    }

    private static func categoryListSeparator(for bundle: Bundle?) -> String {
        if let bundle {
            let identifiers = bundle.preferredLocalizations + bundle.localizations + [bundle.bundleURL.lastPathComponent]
            if identifiers.contains(where: { $0.hasPrefix("zh") || $0.hasPrefix("zh-") }) {
                return "、"
            }
        }
        return ", "
    }

    private static let actionWidth: CGFloat = 72
}
