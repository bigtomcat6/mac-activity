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

            Button(model.isReleasingMemory ? "Releasing" : "Release") {
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

    static func title(for state: MemoryState) -> String {
        switch state {
        case .idle:
            return "Memory"
        case .usage(let percent):
            return "Memory \(Int(percent.rounded()))%"
        case .releasing:
            return "Releasing Memory"
        case .released(let bytes, _):
            return "Released \(formattedBytes(bytes))"
        case .unavailable:
            return "Memory Release Not Available"
        case .failed:
            return "Memory Release Failed"
        case .failedToReadMemory:
            return "Memory Reading Failed"
        }
    }

    static func subtitle(for state: MemoryState) -> String {
        switch state {
        case .released(_, let percentOfTotal):
            return String(format: "%.1f%% of total memory", percentOfTotal)
        case .unavailable:
            return "No supported memory release method is available on this Mac."
        case .failed(let message):
            return message
        case .failedToReadMemory:
            return "Unable to compare before and after memory readings."
        case .idle, .usage, .releasing:
            return "Release reclaimable system memory."
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
