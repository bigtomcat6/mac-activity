import SwiftUI

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
            Button("Retry") {
                Task { await model.refreshTrash() }
            }
        case .cleanable:
            Button("Clean") {
                model.requestTrashCleanupConfirmation()
            }
            .disabled(model.isCleaningTrash)
        case .idle, .clean, .cleaned, .partial:
            EmptyView()
        }
    }

    static func title(for state: TrashState) -> String {
        switch state {
        case .idle, .scanning:
            return "Scanning Trash"
        case .clean:
            return "Trash Is Clean"
        case .cleanable(let bytes, _):
            return "\(formattedBytes(bytes)) in Trash"
        case .cleaning:
            return "Cleaning Trash"
        case .cleaned(let bytes, _):
            return "Cleaned \(formattedBytes(bytes))"
        case .failed:
            return "Trash Cleanup Failed"
        case .partial(let bytes, _, _, _):
            return "Cleaned \(formattedBytes(bytes))"
        }
    }

    static func subtitle(for state: TrashState) -> String {
        switch state {
        case .idle, .scanning:
            return "Checking the current user's Trash."
        case .clean:
            return "No cleanable Trash items found."
        case .cleanable(_, let itemCount):
            return "\(itemCount) \(itemLabel(for: itemCount)) can be removed after confirmation."
        case .cleaning:
            return "Deleting confirmed Trash contents."
        case .cleaned(_, let itemCount):
            return "Removed \(itemCount) \(itemLabel(for: itemCount))."
        case .failed(let message):
            return message
        case .partial(_, let deletedCount, let failedCount, let remainingBytes):
            var message = "Removed \(deletedCount) \(itemLabel(for: deletedCount)); \(failedCount) \(itemLabel(for: failedCount)) could not be deleted."
            if let remainingBytes {
                message += " \(formattedBytes(remainingBytes)) remains."
            }
            return message
        }
    }

    private static func formattedBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func itemLabel(for count: Int) -> String {
        count == 1 ? "item" : "items"
    }
}
