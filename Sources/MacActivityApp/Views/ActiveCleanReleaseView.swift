import SwiftUI

struct ActiveCleanReleaseView: View {
    @ObservedObject var model: ActiveCleanupModel
    @State private var confirmingQuitProcessIdentifier: pid_t?

    var body: some View {
        VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.sectionSpacing) {
            MemoryReleaseStatusView(model: model)
                .accessibilityIdentifier("actives-clean-release-memory")
                .contentShape(Rectangle())
                .onTapGesture {
                    confirmingQuitProcessIdentifier = nil
                }

            ActiveProcessMemoryList(
                model: model,
                confirmingQuitProcessIdentifier: $confirmingQuitProcessIdentifier
            )
                .accessibilityIdentifier("actives-clean-release-processes")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task {
            await model.refreshVisibleCleanReleaseSections()
        }
    }
}
