import SwiftUI

struct ActiveCleanReleaseView: View {
    @ObservedObject var model: ActiveCleanupModel
    let refreshTrigger: Int
    @State private var confirmingQuitProcessIdentifier: pid_t?

    init(model: ActiveCleanupModel, refreshTrigger: Int = 0) {
        self.model = model
        self.refreshTrigger = refreshTrigger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.sectionSpacing) {
            DiskCleanupStatusView(model: model)
                .accessibilityIdentifier("actives-clean-release-disk-cleanup")
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
        .task(id: refreshTrigger) {
            await model.refreshVisibleCleanReleaseSections()
        }
        .task(id: model.quittingProcessIdentifiers) {
            await model.refreshQuittingProcessesUntilResolved()
        }
        .confirmationDialog(
            AppLocalization.string(.diskCleanupConfirmationTitle),
            isPresented: $model.isDiskCleanupConfirmationPresented
        ) {
            Button(AppLocalization.string(.diskCleanupConfirmationConfirm), role: .destructive) {
                Task { await model.confirmDiskCleanup() }
            }
            Button(AppLocalization.string(.diskCleanupConfirmationCancel), role: .cancel) {}
        } message: {
            Text(AppLocalization.string(.diskCleanupConfirmationMessage))
        }
    }
}
