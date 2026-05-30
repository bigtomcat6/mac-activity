import SwiftUI
import MacActivityCore

struct ActiveProcessMemoryList: View {
    @ObservedObject var model: ActiveCleanupModel
    @Binding var confirmingQuitProcessIdentifier: pid_t?

    init(
        model: ActiveCleanupModel,
        confirmingQuitProcessIdentifier: Binding<pid_t?> = .constant(nil)
    ) {
        self.model = model
        self._confirmingQuitProcessIdentifier = confirmingQuitProcessIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.processListSpacing) {
            if model.apps.isEmpty {
                Text("No foreground apps are reporting memory usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: ActiveProcessMemoryLayout.rowHeight, alignment: .leading)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        confirmingQuitProcessIdentifier = nil
                    }
            } else {
                let maxBytes = model.apps.map(\.residentMemoryBytes).max() ?? 0

                ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                    ActiveProcessMemoryRow(
                        app: app,
                        maxBytes: maxBytes,
                        confirmingQuitProcessIdentifier: $confirmingQuitProcessIdentifier
                    ) {
                        model.quit(app)
                    }

                    if index < model.apps.count - 1 {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }

            if let message = Self.processActionMessage(for: model.processActionState) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        confirmingQuitProcessIdentifier = nil
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static func processActionMessage(for state: ProcessActionState) -> String? {
        switch state {
        case .idle:
            return nil
        case .requested(let name):
            return "Requested \(name) to quit."
        case .notFound(let name):
            return "\(name) is no longer running."
        case .notTerminable(let name):
            return "\(name) could not be quit safely."
        }
    }
}
