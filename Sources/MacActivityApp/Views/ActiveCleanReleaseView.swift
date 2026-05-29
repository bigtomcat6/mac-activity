import SwiftUI

struct ActiveCleanReleaseView: View {
    @ObservedObject var model: ActiveCleanupModel

    var body: some View {
        VStack(spacing: ActiveCleanReleaseLayout.sectionSpacing) {
            TrashCleanupStatusView(model: model)
                .accessibilityIdentifier("actives-clean-release-trash")

            MemoryReleaseStatusView(model: model)
                .accessibilityIdentifier("actives-clean-release-memory")

            ActiveProcessMemoryList(model: model)
                .accessibilityIdentifier("actives-clean-release-processes")
        }
        .confirmationDialog(
            "Empty Trash?",
            isPresented: $model.isTrashConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                Task { await model.confirmTrashCleanup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the current user's Trash contents.")
        }
        .task {
            await model.refresh()
        }
    }
}
