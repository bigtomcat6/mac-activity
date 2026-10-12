import Foundation
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PowerFlowPresentationTests: XCTestCase {
    private static var englishBundle: Bundle {
        AppLocalization.bundle(forLanguageIdentifier: "en")!
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
