import AppKit
import SwiftUI
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

    func testRenderedEnergyImpactViewShowsEmptyState() {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: []),
            samplingDelayNanoseconds: 1,
            sleep: { _ in throw CancellationError() }
        )
        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: model,
                refreshTrigger: 0,
                showsApplicationIdentifier: true
            )
            .frame(width: 360, height: 80)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
    }

    func testRenderedEnergyImpactViewShowsEnergyRows() async {
        let readableEntry = EnergyImpactEntry(
            processIdentifier: 201,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            bundleURL: nil,
            impact: 8.4,
            isReadable: true
        )
        let unreadableEntry = EnergyImpactEntry(
            processIdentifier: 202,
            name: "Protected App",
            bundleIdentifier: nil,
            bundleURL: nil,
            impact: 0,
            isReadable: false
        )
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [[readableEntry], [readableEntry, unreadableEntry]]),
            samplingDelayNanoseconds: 1,
            sleep: { _ in
                sleepCount += 1
                guard sleepCount == 1 else { throw CancellationError() }
            }
        )

        await model.refresh()

        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: model,
                refreshTrigger: 0,
                showsApplicationIdentifier: true
            )
            .frame(width: 360, height: 120)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
    }

    func testRenderedEnergyImpactRowUsesBundleIcon() {
        let entry = EnergyImpactEntry(
            processIdentifier: 203,
            name: "Test Host",
            bundleIdentifier: Bundle.main.bundleIdentifier,
            bundleURL: Bundle.main.bundleURL,
            impact: 2.5,
            isReadable: true
        )
        let renderer = ImageRenderer(
            content: EnergyImpactRow(
                entry: entry,
                maximumImpact: 5,
                showsApplicationIdentifier: true
            )
            .frame(width: 360, height: ActiveProcessMemoryLayout.rowHeight)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
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

@MainActor
private final class EnergyImpactViewProviderStub: EnergyImpactProviding {
    private var responses: [[EnergyImpactEntry]]

    init(responses: [[EnergyImpactEntry]]) {
        self.responses = responses
    }

    func topApps(limit: Int) -> [EnergyImpactEntry] {
        responses.isEmpty ? [] : Array(responses.removeFirst().prefix(limit))
    }
}
