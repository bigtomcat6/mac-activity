import SwiftUI
import MacActivityCore

struct ActiveProcessMemoryList: View {
    @ObservedObject var model: ActiveCleanupModel

    var body: some View {
        VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.processListSpacing) {
            if model.apps.isEmpty {
                Text("No foreground apps are reporting memory usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: ActiveProcessMemoryLayout.rowHeight, alignment: .leading)
                    .padding(.horizontal, 12)
            } else {
                let maxBytes = model.apps.map(\.residentMemoryBytes).max() ?? 0

                ForEach(Array(model.apps.enumerated()), id: \.element.id) { index, app in
                    ActiveProcessMemoryRow(app: app, maxBytes: maxBytes) {
                        model.quit(app)
                    }

                    if index < model.apps.count - 1 {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }

            if let message = processActionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var processActionMessage: String? {
        switch model.processActionState {
        case .idle:
            return nil
        case .requested(let name):
            return "Quit requested for \(name)."
        case .notFound(let name):
            return "\(name) is no longer running."
        case .notTerminable(let name):
            return "\(name) cannot be quit from here."
        }
    }
}
