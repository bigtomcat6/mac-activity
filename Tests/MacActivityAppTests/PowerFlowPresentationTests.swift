import Foundation
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PowerFlowPresentationTests: XCTestCase {
    private static var englishBundle: Bundle {
        AppLocalization.bundle(forLanguageIdentifier: "en")!
    }

    func testDiagramPowerTextDistinguishesMeasuredDerivedAndMixedValues() {
        let locale = Locale(identifier: "en")

        XCTAssertEqual(
            PowerFlowPresentation.diagramPowerText(
                .exact(21.46),
                provenance: .measured,
                locale: locale
            ),
            "21.46 W"
        )
        XCTAssertEqual(
            PowerFlowPresentation.diagramPowerText(
                .exact(26.1),
                provenance: .derived,
                locale: locale
            ),
            "≈26.1 W"
        )
        XCTAssertEqual(
            PowerFlowPresentation.diagramPowerText(
                .exact(44),
                provenance: .mixed,
                locale: locale
            ),
            "≈44 W"
        )
    }

    func testDiagramPowerTextUsesLowerBoundWithoutAmbiguousApproximation() {
        XCTAssertEqual(
            PowerFlowPresentation.diagramPowerText(
                .lowerBound(knownWatts: 57, unavailableCount: 1),
                provenance: .mixed,
                locale: Locale(identifier: "en")
            ),
            "≥57 W"
        )
    }

    func testDiagramPowerTextUsesDashForUnavailableAndNoLabelForIdle() {
        XCTAssertEqual(
            PowerFlowPresentation.diagramPowerText(
                .unavailable,
                provenance: .measured,
                locale: Locale(identifier: "en")
            ),
            "—"
        )
        XCTAssertNil(
            PowerFlowPresentation.diagramPowerText(
                .idle,
                provenance: .measured,
                locale: Locale(identifier: "en")
            )
        )
    }

    func testDiagramPowerTextUsesLocalizedDecimalSeparator() {
        XCTAssertEqual(
            PowerFlowPresentation.diagramPowerText(
                .exact(21.46),
                provenance: .measured,
                locale: Locale(identifier: "de_DE")
            ),
            "21,46 W"
        )
    }

    func testDiagramPowerTextRetainsMilliwattsWithoutAbsentProvenancePrefix() {
        XCTAssertEqual(
            PowerFlowPresentation.diagramPowerText(
                .exact(0.65),
                provenance: .absent,
                locale: Locale(identifier: "en")
            ),
            "650 mW"
        )
    }

    func testStatusTextUsesLocalizedStatusForEachCase() {
        let cases: [(PowerFlowDiagramStatus, String)] = [
            (.waiting, "Waiting for Power Data"),
            (.idle, "No Active Power Flow"),
            (.unavailable, "Power Data Unavailable"),
            (.externalPower, "External Power"),
            (.batteryPower, "Battery Power"),
            (.charging, "Charging"),
            (.multipleSources, "Multiple Sources"),
            (.multipleFlows, "Multiple Power Flows"),
            (.summary, "Power Flow Summary"),
        ]

        for (status, expected) in cases {
            XCTAssertEqual(
                PowerFlowPresentation.statusText(status, bundle: Self.englishBundle),
                expected,
                "Unexpected text for \(status)"
            )
        }
    }

    func testMeasuredWattsUseUpToTwoFractionDigits() {
        XCTAssertEqual(
            PowerFlowPresentation.powerText(.watts(22.14), locale: Locale(identifier: "en")),
            "22.14 W"
        )
        XCTAssertEqual(
            PowerFlowPresentation.powerText(.watts(29.36), locale: Locale(identifier: "en")),
            "29.36 W"
        )
        XCTAssertEqual(
            PowerFlowPresentation.powerText(.watts(29.366), locale: Locale(identifier: "en")),
            "29.37 W"
        )
    }

    func testMeasuredMilliwattsRetainExistingFormatting() {
        XCTAssertEqual(
            PowerFlowPresentation.powerText(.watts(0.65), locale: Locale(identifier: "en")),
            "650 mW"
        )
    }

    func testUnavailableRowStatesDirectionTypeAndUnavailablePowerForAccessibility() {
        let row = PowerFlowPresentation.row(
            endpoint: PowerFlowEndpoint(
                id: "external-power",
                type: .usbC,
                direction: .input,
                measurement: .unavailable
            ),
            bundle: Self.englishBundle
        )

        XCTAssertEqual(row.title, "USB-C")
        XCTAssertEqual(row.powerText, "Power unavailable")
        XCTAssertEqual(row.accessibilityLabel, "Input, USB-C, Power unavailable")
    }

    func testMagSafeRowUsesMagSafeTitle() {
        let row = PowerFlowPresentation.row(
            endpoint: PowerFlowEndpoint(
                id: "external-power",
                type: .magSafe,
                direction: .input,
                measurement: .unavailable
            ),
            bundle: Self.englishBundle
        )

        XCTAssertEqual(row.title, "MagSafe")
    }

    func testUnknownExternalRowUsesLocalizedTitle() {
        let row = PowerFlowPresentation.row(
            endpoint: PowerFlowEndpoint(
                id: "external-power",
                type: .unknownExternalInterface,
                direction: .input,
                measurement: .unavailable
            ),
            bundle: Self.englishBundle
        )

        XCTAssertEqual(row.title, "Unknown external interface")
    }
}
