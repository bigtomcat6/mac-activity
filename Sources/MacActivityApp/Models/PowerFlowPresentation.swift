import Foundation
import MacActivityCore

struct PowerFlowRowPresentation: Equatable {
    let title: String
    let powerText: String
    let accessibilityLabel: String
}

enum PowerFlowPresentation {
    static func powerText(
        _ measurement: PowerFlowMeasurement,
        locale: Locale,
        bundle: Bundle? = nil
    ) -> String {
        switch measurement {
        case .unavailable:
            return AppLocalization.string(.powerFlowUnavailable, bundle: bundle)
        case .watts(let watts) where watts >= 1:
            return "\(watts.formatted(.number.locale(locale).precision(.fractionLength(0...2)))) W"
        case .watts(let watts):
            return "\((watts * 1_000).formatted(.number.locale(locale).precision(.fractionLength(0...1)))) mW"
        }
    }

    static func diagramPowerText(
        _ measurement: PowerFlowDisplayMeasurement,
        provenance: PowerFlowDisplayProvenance,
        locale: Locale,
        bundle: Bundle? = nil
    ) -> String? {
        switch measurement {
        case .exact(let watts):
            // Provenance remains in help/accessibility wording, not a prefix.
            return powerText(.watts(watts), locale: locale, bundle: bundle)

        case .lowerBound(let knownWatts, _):
            let value = powerText(
                .watts(knownWatts),
                locale: locale,
                bundle: bundle
            )
            return "≥\(value)"

        case .unavailable:
            return "—"

        case .idle:
            return nil
        }
    }

    static func statusText(
        _ status: PowerFlowDiagramStatus,
        bundle: Bundle? = nil
    ) -> String {
        switch status {
        case .waiting:
            return AppLocalization.string(.powerFlowStatusWaiting, bundle: bundle)
        case .idle:
            return AppLocalization.string(.powerFlowStatusIdle, bundle: bundle)
        case .unavailable:
            return AppLocalization.string(.powerFlowStatusUnavailable, bundle: bundle)
        case .externalPower:
            return AppLocalization.string(.powerFlowStatusExternalPower, bundle: bundle)
        case .batteryPower:
            return AppLocalization.string(.powerFlowStatusBatteryPower, bundle: bundle)
        case .charging:
            return AppLocalization.string(.powerFlowStatusCharging, bundle: bundle)
        case .multipleSources:
            return AppLocalization.string(.powerFlowStatusMultipleSources, bundle: bundle)
        case .multipleFlows:
            return AppLocalization.string(.powerFlowStatusMultipleFlows, bundle: bundle)
        case .summary:
            return AppLocalization.string(.powerFlowStatusSummary, bundle: bundle)
        }
    }

    static func row(
        endpoint: PowerFlowEndpoint,
        bundle: Bundle? = nil
    ) -> PowerFlowRowPresentation {
        precondition(endpoint.direction != .idle)
        let title = endpointTitle(endpoint.type, bundle: bundle)
        let direction = endpoint.direction == .input
            ? AppLocalization.string(.powerFlowInput, bundle: bundle)
            : AppLocalization.string(.powerFlowOutput, bundle: bundle)
        let power = powerText(
            endpoint.measurement,
            locale: AppLocalization.currentLocale(bundle: bundle),
            bundle: bundle
        )
        return PowerFlowRowPresentation(
            title: title,
            powerText: power,
            accessibilityLabel: AppLocalization.string(
                .powerFlowRowAccessibility,
                direction,
                title,
                power,
                bundle: bundle
            )
        )
    }

    static func endpointTitle(
        _ type: PowerFlowEndpointType,
        bundle: Bundle?
    ) -> String {
        switch type {
        case .usbC:
            return "USB-C"
        case .magSafe:
            return "MagSafe"
        case .battery:
            return AppLocalization.string(.powerFlowEndpointBattery, bundle: bundle)
        case .mac:
            return AppLocalization.string(.powerFlowEndpointMac, bundle: bundle)
        case .unknownExternalInterface:
            return AppLocalization.string(.powerFlowEndpointUnknownExternal, bundle: bundle)
        }
    }
}
