import SwiftUI

struct ActiveCleanReleaseView: View {
    @ObservedObject var model: ActiveCleanupModel
    let refreshTrigger: Int
    let usedMemoryBytes: UInt64
    let showsApplicationIdentifier: Bool
    @State private var confirmingQuitProcessIdentifier: pid_t?
    @State private var diskCleanupConfirmationState: DiskCleanupConfirmationState = .inactive

    init(
        model: ActiveCleanupModel,
        refreshTrigger: Int = 0,
        usedMemoryBytes: UInt64 = 0,
        showsApplicationIdentifier: Bool = true
    ) {
        self.model = model
        self.refreshTrigger = refreshTrigger
        self.usedMemoryBytes = usedMemoryBytes
        self.showsApplicationIdentifier = showsApplicationIdentifier
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
                usedMemoryBytes: usedMemoryBytes,
                showsApplicationIdentifier: showsApplicationIdentifier,
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
