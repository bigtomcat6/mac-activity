import XCTest
import MacActivityCore
@testable import MacActivityApp

final class EnergyImpactPresentationTests: XCTestCase {
    func testPowerTextUsesMicrowattsBelowOneMilliwatt() {
        XCTAssertEqual(
            EnergyImpactPresentation.powerText(
                microwatts: 860,
                locale: Locale(identifier: "en_US")
            ),
            "860 µW"
        )
    }

    func testPowerTextUsesMilliwattsAtOneThousandMicrowatts() {
        XCTAssertEqual(
            EnergyImpactPresentation.powerText(
                microwatts: 1_840,
                locale: Locale(identifier: "en_US")
            ),
            "1.8 mW"
        )
    }

    func testCollectingAndUnavailableDoNotRenderZero() {
        XCTAssertEqual(
            EnergyImpactPresentation.powerText(
                microwatts: nil,
                status: .collecting,
                bundle: AppLocalization.bundle(forLanguageIdentifier: "en")
            ),
            "Collecting"
        )
        XCTAssertEqual(
            EnergyImpactPresentation.powerText(
                microwatts: nil,
                status: .unavailable,
                bundle: AppLocalization.bundle(forLanguageIdentifier: "en")
            ),
            "Unavailable"
        )
    }

    func testInvalidPowerValuesNeverRenderZeroMicrowatts() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            let text = EnergyImpactPresentation.powerText(
                microwatts: value,
                status: .unavailable,
                bundle: AppLocalization.bundle(forLanguageIdentifier: "en")
            )

            XCTAssertNotEqual(text, "0 µW", "Invalid value \(value) must not appear as zero")
            XCTAssertEqual(text, "Unavailable")
        }
    }

    func testNumericStalePowerTextPreservesValueAndMarksItStale() {
        let englishBundle = AppLocalization.bundle(forLanguageIdentifier: "en")

        XCTAssertEqual(
            EnergyImpactPresentation.powerText(
                microwatts: 1_840,
                status: .stale,
                bundle: englishBundle
            ),
            "Stale · 1.8 mW"
        )
        XCTAssertEqual(
            EnergyImpactPresentation.powerText(
                microwatts: nil,
                status: .stale,
                bundle: englishBundle
            ),
            "Stale"
        )
    }
}
