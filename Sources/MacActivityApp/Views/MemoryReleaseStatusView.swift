import SwiftUI

struct MemoryReleaseStatusView: View {
    @ObservedObject var model: ActiveCleanupModel

    static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter
    }()

    static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
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
            return "Memory Release"
        case .usage:
            return "Memory Usage"
        case .releasing:
            return "Releasing Memory"
        case .released:
            return "Memory Released"
        case .unavailable:
            return "Memory Release Unavailable"
        case .failed:
            return "Memory Release Failed"
        case .failedToReadMemory:
            return "Memory Read Failed"
        }
    }

    static func subtitle(for state: MemoryState) -> String {
        switch state {
        case .idle:
            return "Memory status is waiting to refresh."
        case .usage(let percent):
            return "\(formattedPercent(percent)) used."
        case .releasing(let previousPercent):
            guard let previousPercent else {
                return "Running memory release."
            }
            return "Running memory release from \(formattedPercent(previousPercent)) used."
        case .released(let bytes, let percentOfTotal):
            let released = byteFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
            return "Released \(released), \(formattedPercent(percentOfTotal)) of total memory."
        case .unavailable:
            return "Memory release is not available on this Mac."
        case .failed(let message):
            return message
        case .failedToReadMemory:
            return "Could not read memory usage before or after release."
        }
    }

    static func showsProgressIndicator(for state: MemoryState) -> Bool {
        if case .releasing = state {
            return true
        }
        return false
    }

    private static func formattedPercent(_ percent: Double) -> String {
        let value = percentFormatter.string(from: NSNumber(value: percent)) ?? "\(Int(percent))"
        return "\(value)%"
    }
}
