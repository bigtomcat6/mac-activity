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

    func testStableRowUsesSustainedPowerAndRisingTrend() {
        let row = EnergyImpactPresentation.row(
            entry: fixtureEntry(
                current: 1_400,
                sustained: 1_000,
                trend: .rising,
                status: .stable,
                coverage: 1
            ),
            rank: 2,
            bundle: AppLocalization.bundle(forLanguageIdentifier: "en")
        )

        XCTAssertEqual(row.primaryValue, "1 mW")
        XCTAssertEqual(row.trendSymbol, "arrow.up")
        XCTAssertNil(row.statusText)
        XCTAssertEqual(row.trendAccessibilityText, "rising")
        XCTAssertEqual(
            row.accessibilityLabel,
            "Test App, rank 2, up to 30 seconds 1 mW, rising"
        )
    }

    func testPrimaryValueFallsBackToFastPowerWithoutASustainedInterval() {
        let row = EnergyImpactPresentation.row(
            entry: fixtureEntry(
                current: 860,
                sustained: nil,
                trend: .steady,
                status: .collecting,
                coverage: 1
            ),
            rank: 1,
            bundle: AppLocalization.bundle(forLanguageIdentifier: "en")
        )

        XCTAssertEqual(row.primaryValue, "860 µW")
        XCTAssertEqual(row.statusText, "Collecting")
        XCTAssertNil(row.trendSymbol)
    }

    func testPartialAndStaleRowsExposeStatusWithoutChangingTheNumberToZero() {
        let englishBundle = AppLocalization.bundle(forLanguageIdentifier: "en")
        let partial = EnergyImpactPresentation.row(
            entry: fixtureEntry(
                current: 800,
                sustained: 700,
                trend: .rising,
                status: .partial,
                coverage: 0.7
            ),
            rank: 1,
            bundle: englishBundle
        )
        let stale = EnergyImpactPresentation.row(
            entry: fixtureEntry(
                current: 800,
                sustained: 700,
                trend: .rising,
                status: .stale,
                coverage: 0.7
            ),
            rank: 1,
            bundle: englishBundle
        )

        XCTAssertEqual(partial.primaryValue, "700 µW")
        XCTAssertEqual(partial.statusText, "Partial")
        XCTAssertEqual(partial.trendSymbol, "arrow.up")
        XCTAssertEqual(stale.primaryValue, "700 µW")
        XCTAssertEqual(stale.statusText, "Stale")
        XCTAssertNil(stale.trendSymbol)
    }

    func testNonNumericRowsKeepTheirStatusSeparateFromThePrimaryValue() {
        let englishBundle = AppLocalization.bundle(forLanguageIdentifier: "en")

        for status in [EnergyImpactStatus.collecting, .partial, .stale, .unavailable] {
            let row = EnergyImpactPresentation.row(
                entry: fixtureEntry(
                    current: nil,
                    sustained: nil,
                    trend: .falling,
                    status: status,
                    coverage: 0
                ),
                rank: 1,
                bundle: englishBundle
            )

            XCTAssertEqual(row.primaryValue, "—", "\(status)")
            XCTAssertNotNil(row.statusText, "\(status)")
            XCTAssertNil(row.trendSymbol, "\(status)")
            XCTAssertNotEqual(row.primaryValue, "0 µW", "\(status)")
        }
    }

    func testEveryStatusAndTrendCombinationUsesOnlyAllowedTrendSymbols() {
        let englishBundle = AppLocalization.bundle(forLanguageIdentifier: "en")

        for status in [.collecting, .stable, .partial, .stale, .unavailable] as [EnergyImpactStatus] {
            for trend in [.rising, .steady, .falling] as [EnergyImpactTrend] {
                let row = EnergyImpactPresentation.row(
                    entry: fixtureEntry(
                        current: 1_200,
                        sustained: 1_000,
                        trend: trend,
                        status: status,
                        coverage: 1
                    ),
                    rank: 1,
                    bundle: englishBundle
                )

                let expectedSymbol: String? = switch (status, trend) {
                case (.stable, .rising), (.partial, .rising): "arrow.up"
                case (.stable, .falling), (.partial, .falling): "arrow.down"
                default: nil
                }
                XCTAssertEqual(row.trendSymbol, expectedSymbol, "\(status) / \(trend)")
                XCTAssertNotEqual(row.primaryValue, "0 µW", "\(status) / \(trend)")
            }
        }
    }

    func testCoverageTextUsesReadableAndDiscoveredProcessCounts() {
        XCTAssertEqual(
            EnergyImpactPresentation.coverageText(
                readable: 7,
                discovered: 10,
                bundle: AppLocalization.bundle(forLanguageIdentifier: "en")
            ),
            "7 of 10 processes readable"
        )
    }

    func testInvalidPowerValuesNeverRenderZeroMicrowatts() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            let row = EnergyImpactPresentation.row(
                entry: fixtureEntry(
                    current: value,
                    sustained: value,
                    trend: .steady,
                    status: .unavailable,
                    coverage: 0
                ),
                rank: 1,
                bundle: AppLocalization.bundle(forLanguageIdentifier: "en")
            )

            XCTAssertNotEqual(row.primaryValue, "0 µW", "Invalid value \(value) must not appear as zero")
            XCTAssertEqual(row.primaryValue, "—")
            XCTAssertEqual(row.statusText, "Unavailable")
        }
    }

    func testAccessoryRowShowsBadgeAndMergesItIntoAccessibilityLabel() {
        let englishBundle = AppLocalization.bundle(forLanguageIdentifier: "en")

        let accessory = EnergyImpactPresentation.row(
            entry: fixtureEntry(
                kind: .accessory,
                current: 1_400,
                sustained: 1_000,
                trend: .rising,
                status: .stable,
                coverage: 1
            ),
            rank: 1,
            bundle: englishBundle
        )
        XCTAssertEqual(accessory.accessoryBadgeText, "Menu Bar")
        XCTAssertEqual(
            accessory.accessibilityLabel,
            "Test App, rank 1, up to 30 seconds 1 mW, Menu Bar · rising"
        )
        XCTAssertNil(
            EnergyImpactPresentation.row(
                entry: fixtureEntry(
                    kind: .regular,
                    current: 1_400,
                    sustained: 1_000,
                    trend: .rising,
                    status: .stable,
                    coverage: 1
                ),
                rank: 1,
                bundle: englishBundle
            ).accessoryBadgeText
        )
        let partialAccessory = EnergyImpactPresentation.row(
            entry: fixtureEntry(
                kind: .accessory,
                current: 1_400,
                sustained: 1_000,
                trend: .rising,
                status: .partial,
                coverage: 0.7
            ),
            rank: 1,
            bundle: englishBundle
        )
        XCTAssertEqual(
            partialAccessory.accessibilityLabel,
            "Test App, rank 1, up to 30 seconds 1 mW, Menu Bar · Partial · rising"
        )
    }

    private func fixtureEntry(
        kind: EnergyImpactAppKind = .regular,
        current: Double?,
        sustained: Double?,
        trend: EnergyImpactTrend,
        status: EnergyImpactStatus,
        coverage: Double
    ) -> EnergyImpactEntry {
        EnergyImpactEntry(
            identity: EnergyImpactAppIdentity(
                rootProcessIdentifier: 101,
                rootProcessStartAbsoluteTime: 1
            ),
            name: "Test App",
            bundleIdentifier: "com.example.test",
            bundleURL: nil,
            kind: kind,
            currentPowerMicrowatts: current,
            sustainedPowerMicrowatts: sustained,
            rankingScore: sustained ?? current,
            trend: trend,
            coverage: EnergyImpactCoverage(
                discoveredProcessCount: 10,
                readableProcessCount: Int((coverage * 10).rounded()),
                validProcessSeconds: coverage * 10,
                discoveredProcessSeconds: 10
            ),
            status: status,
            observedWindowSeconds: 30
        )
    }
}
