import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactViewTests: XCTestCase {
    private static var englishBundle: Bundle {
        AppLocalization.bundle(forLanguageIdentifier: "en")!
    }

    func testEnergyImpactRowShowsFormattedImpact() {
        let entry = EnergyImpactEntry(
            processIdentifier: 101,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil,
            impact: 7.4,
            isReadable: true
        )

        XCTAssertEqual(EnergyImpactRow.trailingText(for: entry, bundle: Self.englishBundle), "7.4")
    }

    func testEnergyImpactRowShowsUnavailableWhenUnreadable() {
        let entry = EnergyImpactEntry(
            processIdentifier: 102,
            name: "Protected App",
            bundleIdentifier: nil,
            bundleURL: nil,
            impact: 0,
            isReadable: false
        )

        XCTAssertEqual(EnergyImpactRow.trailingText(for: entry, bundle: Self.englishBundle), "Unavailable")
    }

    func testEnergyImpactRowIdentifierCanBeHidden() {
        let entry = EnergyImpactEntry(
            processIdentifier: 103,
            name: "Notes",
            bundleIdentifier: "com.apple.Notes",
            bundleURL: nil,
            impact: 1,
            isReadable: true
        )

        XCTAssertEqual(
            EnergyImpactRow.identifierText(
                for: entry,
                showsApplicationIdentifier: true,
                bundle: Self.englishBundle
            ),
            "com.apple.Notes"
        )
        XCTAssertNil(
            EnergyImpactRow.identifierText(
                for: entry,
                showsApplicationIdentifier: false,
                bundle: Self.englishBundle
            )
        )
    }

    func testEnergyImpactRowUsesBundleIconWhenBundleExists() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Safari.app")
        let entry = EnergyImpactEntry(
            processIdentifier: 104,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: bundleURL,
            impact: 3.1,
            isReadable: true
        )

        XCTAssertEqual(EnergyImpactRow.iconSource(for: entry), .bundle(bundleURL))
    }

    func testEnergyImpactRowFallsBackToSystemIconWhenBundleMissing() {
        let entry = EnergyImpactEntry(
            processIdentifier: 105,
            name: "Unknown",
            bundleIdentifier: nil,
            bundleURL: URL(fileURLWithPath: "/Applications/Missing.app"),
            impact: 0.2,
            isReadable: true
        )

        XCTAssertEqual(
            EnergyImpactRow.iconSource(for: entry, fileExists: { _ in false }),
            .fallbackSystemSymbol
        )
    }
}
