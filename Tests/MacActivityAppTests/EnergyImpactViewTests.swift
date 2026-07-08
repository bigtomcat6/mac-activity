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

    func testEnergyImpactViewShowsCollectingMessageWhileRefreshingWithoutRows() {
        XCTAssertEqual(
            EnergyImpactView.emptyMessage(isRefreshing: true, bundle: Self.englishBundle),
            "Waiting for the first sample"
        )
        XCTAssertEqual(
            EnergyImpactView.emptyMessage(isRefreshing: false, bundle: Self.englishBundle),
            "No foreground apps are reporting energy impact."
        )
    }

    func testEnergyImpactViewVisibleRefreshIntervalIsThreeSeconds() {
        XCTAssertEqual(EnergyImpactView.visibleRefreshIntervalNanoseconds, 3_000_000_000)
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

        XCTAssertEqual(
            EnergyImpactRow.iconSource(for: entry, fileExists: { _ in true }),
            .bundle(bundleURL)
        )
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

    func testEnergyImpactRowProgressFractionUsesReadableMaximumImpact() {
        let entry = EnergyImpactEntry(
            processIdentifier: 106,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil,
            impact: 3,
            isReadable: true
        )

        XCTAssertEqual(
            EnergyImpactRow.progressFraction(for: entry, maximumImpact: 6),
            0.5,
            accuracy: 0.001
        )
    }

    func testEnergyImpactRowProgressFractionIsZeroForUnreadableOrZeroMaximum() {
        let unreadableEntry = EnergyImpactEntry(
            processIdentifier: 107,
            name: "Protected App",
            bundleIdentifier: nil,
            bundleURL: nil,
            impact: 8,
            isReadable: false
        )
        let readableEntry = EnergyImpactEntry(
            processIdentifier: 108,
            name: "Notes",
            bundleIdentifier: "com.apple.Notes",
            bundleURL: nil,
            impact: 4,
            isReadable: true
        )

        XCTAssertEqual(EnergyImpactRow.progressFraction(for: unreadableEntry, maximumImpact: 8), 0)
        XCTAssertEqual(EnergyImpactRow.progressFraction(for: readableEntry, maximumImpact: 0), 0)
    }

    func testEnergyImpactRowProgressFractionClampsAtOne() {
        let entry = EnergyImpactEntry(
            processIdentifier: 109,
            name: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode",
            bundleURL: nil,
            impact: 12,
            isReadable: true
        )

        XCTAssertEqual(EnergyImpactRow.progressFraction(for: entry, maximumImpact: 6), 1)
    }
}
