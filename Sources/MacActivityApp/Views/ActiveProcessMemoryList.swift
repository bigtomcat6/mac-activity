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
                Text(AppLocalization.string(.processEmpty))
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
        .activeCleanupCardChrome()
    }

    static func processActionMessage(for state: ProcessActionState, bundle: Bundle? = nil) -> String? {
        switch state {
        case .idle:
            return nil
        case .requested(let name):
            return AppLocalization.string(.processActionRequested, name, bundle: bundle)
        case .notFound(let name):
            return AppLocalization.string(.processActionNotFound, name, bundle: bundle)
        case .notTerminable(let name):
            return AppLocalization.string(.processActionNotTerminable, name, bundle: bundle)
        }
    }
}
