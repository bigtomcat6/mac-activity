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
            return "\(watts.formatted(.number.locale(locale).precision(.fractionLength(0...1)))) W"
        case .watts(let watts):
            return "\((watts * 1_000).formatted(.number.locale(locale).precision(.fractionLength(0...1)))) mW"
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

    private static func endpointTitle(
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
