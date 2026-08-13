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

    static func row(
        entry: EnergyImpactEntry,
        rank: Int,
        bundle: Bundle? = nil
    ) -> EnergyImpactRowPresentation {
        let primary = primaryValue(for: entry, bundle: bundle)
        let statusText: String? = switch entry.status {
        case .stable: nil
        case .collecting: AppLocalization.string(.energyImpactCollecting, bundle: bundle)
        case .partial: AppLocalization.string(.energyImpactPartial, bundle: bundle)
        case .stale: AppLocalization.string(.energyImpactStale, bundle: bundle)
        case .unavailable: AppLocalization.string(.energyImpactUnavailable, bundle: bundle)
        }
        let showsTrend = (entry.status == .stable || entry.status == .partial)
            && (entry.displayPowerMicrowatts.map { $0.isFinite && $0 >= 0 } ?? false)
        let trendKey: AppLocalization.Key
        let trendSymbol: String?
        switch entry.trend {
        case .rising:
            trendKey = .energyImpactTrendRising
            trendSymbol = showsTrend ? "arrow.up" : nil
        case .steady:
            trendKey = .energyImpactTrendSteady
            trendSymbol = nil
        case .falling:
            trendKey = .energyImpactTrendFalling
            trendSymbol = showsTrend ? "arrow.down" : nil
        }
        let trendText = AppLocalization.string(trendKey, bundle: bundle)
        let accessibilityQualifier: String
        if let statusText, entry.status == .partial, trendSymbol != nil {
            accessibilityQualifier = "\(statusText) · \(trendText)"
        } else {
            accessibilityQualifier = statusText ?? trendText
        }
        let accessibility = AppLocalization.string(
            .energyImpactRowAccessibilitySustained,
            entry.name,
            rank,
            primary,
            accessibilityQualifier,
            bundle: bundle
        )
        return EnergyImpactRowPresentation(
            primaryValue: primary,
            statusText: statusText,
            trendSymbol: trendSymbol,
            trendAccessibilityText: trendText,
            accessibilityLabel: accessibility
        )
    }

    static func coverageText(
        readable: Int,
        discovered: Int,
        bundle: Bundle? = nil
    ) -> String {
        AppLocalization.string(
            .energyImpactCoverage,
            readable,
            discovered,
            bundle: bundle
        )
    }

    private static func primaryValue(for entry: EnergyImpactEntry, bundle: Bundle?) -> String {
        guard let microwatts = entry.displayPowerMicrowatts else { return "—" }
        return powerText(
            microwatts: microwatts,
            locale: AppLocalization.currentLocale(bundle: bundle)
        )
    }
}

struct EnergyImpactRowPresentation: Equatable {
    let primaryValue: String
    let statusText: String?
    let trendSymbol: String?
    let trendAccessibilityText: String
    let accessibilityLabel: String
}
