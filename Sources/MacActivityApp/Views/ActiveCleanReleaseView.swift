import SwiftUI

struct ActiveCleanReleaseView: View {
    @ObservedObject var model: ActiveCleanupModel
    let refreshTrigger: Int
    @State private var confirmingQuitProcessIdentifier: pid_t?
    @State private var diskCleanupConfirmationState: DiskCleanupConfirmationState = .inactive

    init(model: ActiveCleanupModel, refreshTrigger: Int = 0) {
        self.model = model
        self.refreshTrigger = refreshTrigger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ActiveCleanReleaseLayout.sectionSpacing) {
            DiskCleanupStatusView(
                model: model,
                confirmationState: $diskCleanupConfirmationState
            )
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
    }
}
