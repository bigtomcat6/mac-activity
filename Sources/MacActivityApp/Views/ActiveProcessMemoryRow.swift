import SwiftUI
import MacActivityCore

enum ActiveProcessMemoryRowTrailingContent: Equatable {
    case memory
    case quit
}

struct ActiveProcessMemoryRow: View {
    let app: ActiveAppMemoryEntry
    let maxBytes: UInt64
    let quit: () -> Void
    @State private var isHovered = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(
                        width: proxy.size.width * ActiveProcessMemoryLayout.progress(
                            bytes: app.residentMemoryBytes,
                            maxBytes: maxBytes
                        )
                    )

                HStack(spacing: 10) {
                    Image(systemName: "app")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)

                        Text(app.bundleIdentifier ?? "Process \(app.processIdentifier)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    trailingContent
                        .frame(width: ActiveProcessMemoryLayout.trailingActionWidth, alignment: .trailing)
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: ActiveProcessMemoryLayout.rowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .clipped()
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch Self.trailingContent(isHovered: isHovered) {
        case .memory:
            Text(app.formattedResidentMemory)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .quit:
            Button("Quit", action: quit)
                .disabled(!app.isTerminable)
        }
    }

    static func trailingContent(isHovered: Bool) -> ActiveProcessMemoryRowTrailingContent {
        isHovered ? .quit : .memory
    }
}
