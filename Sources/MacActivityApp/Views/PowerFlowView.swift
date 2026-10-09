import SwiftUI
import MacActivityCore

struct PowerFlowRefreshTaskID: Equatable {
    var presented: Bool = true
    var trigger: Int
}

struct PowerFlowView: View {
    @ObservedObject var model: PowerFlowModel
    @Environment(\.dashboardPresentationIsPresented) private var dashboardIsPresented
    let refreshTrigger: Int

    var body: some View {
        PowerFlowDiagramView(
            presentation: Self.presentation(
                snapshot: model.snapshot,
                isRefreshing: model.isRefreshing
            )
        )
        .task(id: PowerFlowRefreshTaskID(presented: dashboardIsPresented, trigger: refreshTrigger)) {
            guard dashboardIsPresented else { return }
            await model.refreshWhileVisible()
        }
    }

    static func presentation(
        snapshot: PowerFlowSnapshot,
        isRefreshing: Bool,
        bundle: Bundle? = nil
    ) -> PowerFlowDiagramPresentation {
        PowerFlowDiagramPresentationBuilder.build(
            snapshot: snapshot,
            isRefreshing: isRefreshing,
            bundle: bundle
        )
    }
}
