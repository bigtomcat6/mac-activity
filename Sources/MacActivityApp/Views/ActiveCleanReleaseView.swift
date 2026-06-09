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
        .task(id: refreshTrigger) {
            await model.refreshVisibleCleanReleaseSections()
        }
        .task(id: model.quittingProcessIdentifiers) {
            await model.refreshQuittingProcessesUntilResolved()
        }
    }
}
