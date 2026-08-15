import SwiftUI
import MacActivityCore

struct PowerFlowView: View {
    @ObservedObject var model: PowerFlowModel
    let refreshTrigger: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PowerFlowColumn(
                title: AppLocalization.string(.powerFlowInput),
                endpoints: model.snapshot.inputEndpoints
            )
            PowerFlowColumn(
                title: AppLocalization.string(.powerFlowOutput),
                endpoints: model.snapshot.outputEndpoints
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: refreshTrigger) {
            await model.refreshWhileVisible()
        }
    }
}

private struct PowerFlowColumn: View {
    let title: String
    let endpoints: [PowerFlowEndpoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if endpoints.isEmpty {
                Text(AppLocalization.string(.powerFlowEmpty))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else {
                ForEach(endpoints) { endpoint in
                    PowerFlowEndpointRow(endpoint: endpoint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PowerFlowEndpointRow: View {
    let endpoint: PowerFlowEndpoint

    private var presentation: PowerFlowRowPresentation {
        PowerFlowPresentation.row(endpoint: endpoint)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(presentation.title)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(presentation.powerText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .frame(minHeight: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var symbolName: String {
        switch endpoint.type {
        case .usbC, .magSafe:
            return "bolt.fill"
        case .battery:
            return "battery.100"
        case .mac:
            return "desktopcomputer"
        case .unknownExternalInterface:
            return "questionmark.circle"
        }
    }
}
