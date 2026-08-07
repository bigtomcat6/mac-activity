import Foundation
import MacActivityCore

enum EnergyImpactPresentation {
    static func powerText(microwatts: Double, locale: Locale) -> String {
        guard microwatts.isFinite, microwatts >= 0 else { return "—" }
        if microwatts >= 1_000 {
            let value = (microwatts / 1_000).formatted(
                .number.locale(locale).precision(.fractionLength(0...1))
            )
            return "\(value) mW"
        }
        let value = microwatts.formatted(
            .number.locale(locale).precision(.fractionLength(0...1))
        )
        return "\(value) µW"
    }

    static func powerText(
        microwatts: Double?,
        status: EnergyImpactStatus,
        bundle: Bundle? = nil
    ) -> String {
        if status == .stale {
            guard let microwatts, microwatts.isFinite, microwatts >= 0 else {
                return AppLocalization.string(.energyImpactStale, bundle: bundle)
            }
            return AppLocalization.string(
                .energyImpactStaleWithValue,
                powerText(
                    microwatts: microwatts,
                    locale: AppLocalization.currentLocale(bundle: bundle)
                ),
                bundle: bundle
            )
        }
        guard let microwatts, microwatts.isFinite, microwatts >= 0 else {
            let key: AppLocalization.Key = switch status {
            case .collecting: .energyImpactCollecting
            case .partial: .energyImpactPartial
            case .stale: .energyImpactStale
            case .stable, .unavailable: .energyImpactUnavailable
            }
            return AppLocalization.string(key, bundle: bundle)
        }
        return powerText(
            microwatts: microwatts,
            locale: AppLocalization.currentLocale(bundle: bundle)
        )
    }

    static func accessibilityLabel(
        entry: EnergyImpactEntry,
        rank: Int,
        bundle: Bundle? = nil
    ) -> String {
        let value = powerText(
            microwatts: entry.displayPowerMicrowatts,
            status: entry.status,
            bundle: bundle
        )
        return AppLocalization.string(
            .energyImpactRowAccessibility,
            entry.name,
            rank,
            value,
            bundle: bundle
        )
    }
}
