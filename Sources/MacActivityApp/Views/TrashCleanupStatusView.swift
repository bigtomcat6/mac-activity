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
        case .cleanable:
            return "Trash Cleanup"
        case .cleaning:
            return "Cleaning Trash"
        case .cleaned:
            return "Trash Cleaned"
        case .failed:
            return "Trash Cleanup Failed"
        case .partial:
            return "Trash Cleanup Incomplete"
        }
    }

    static func subtitle(for state: TrashState) -> String {
        switch state {
        case .idle:
            return "Trash status is waiting to refresh."
        case .scanning:
            return "Checking the current user's Trash contents."
        case .clean:
            return "No removable Trash contents were found."
        case .cleanable(let bytes, let itemCount):
            return "\(itemCount) item\(itemCount == 1 ? "" : "s") using \(byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max)))))."
        case .cleaning:
            return "Deleting the current user's Trash contents."
        case .cleaned(let bytes, let itemCount):
            return "Deleted \(itemCount) item\(itemCount == 1 ? "" : "s") and freed \(byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max)))))."
        case .failed(let message):
            return message
        case .partial(let bytes, let deletedCount, let failedCount, let remainingBytes):
            let freed = byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
            if let remainingBytes {
                let remaining = byteFormatter.string(fromByteCount: Int64(min(remainingBytes, UInt64(Int64.max))))
                return "Deleted \(deletedCount), failed \(failedCount), freed \(freed), \(remaining) remaining."
            }
            return "Deleted \(deletedCount), failed \(failedCount), freed \(freed)."
        }
    }
}
