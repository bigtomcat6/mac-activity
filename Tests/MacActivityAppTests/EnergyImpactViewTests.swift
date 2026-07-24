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

    func testEnergyImpactRowShowsLocalizedPowerText() {
        XCTAssertEqual(
            EnergyImpactRow.trailingText(for: entry(power: 1_840), bundle: Self.englishBundle),
            "1.8 mW"
        )
    }

    func testEnergyImpactRowDoesNotRenderCollectingOrUnavailableAsZero() {
        XCTAssertEqual(
            EnergyImpactRow.trailingText(for: entry(power: nil, status: .collecting), bundle: Self.englishBundle),
            "Collecting"
        )
        XCTAssertEqual(
            EnergyImpactRow.trailingText(for: entry(power: nil, status: .unavailable), bundle: Self.englishBundle),
            "Unavailable"
        )
    }

    func testEnergyImpactViewShowsLocalizedEmptyMessage() {
        XCTAssertEqual(
            EnergyImpactView.emptyMessage(isRefreshing: true, bundle: Self.englishBundle),
            "Waiting for the first sample"
        )
        XCTAssertEqual(
            EnergyImpactView.emptyMessage(isRefreshing: false, bundle: Self.englishBundle),
            "No regular apps are reporting an energy estimate."
        )
    }

    func testEnergyImpactViewVisibleRefreshIntervalIsThreeSeconds() {
        XCTAssertEqual(EnergyImpactView.visibleRefreshIntervalNanoseconds, 3_000_000_000)
    }

    func testRenderedEnergyImpactViewShowsEmptyStateAtFourHundredTwentyPoints() {
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
            .environment(\.locale, Locale(identifier: "en"))
            .frame(width: 420, height: 120)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
    }

    func testRenderedEnergyImpactViewShowsEnglishAndSimplifiedChineseRowsAtFourHundredTwentyPoints() async {
        defer { AppLocalization.setPreferredLanguageIdentifier(nil) }
        var sleepCount = 0
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [[], [entry(power: 1_840)], []]),
            samplingDelayNanoseconds: 1,
            sleep: { _ in
                sleepCount += 1
                guard sleepCount == 1 else { throw CancellationError() }
            }
        )
        await model.refresh()

        for localeIdentifier in ["en", "zh-Hans"] {
            AppLocalization.setPreferredLanguageIdentifier(localeIdentifier)
            let renderer = ImageRenderer(
                content: EnergyImpactView(
                    model: model,
                    refreshTrigger: 0,
                    showsApplicationIdentifier: true
                )
                .frame(width: 420, height: 160)
            )
            renderer.scale = 1

            XCTAssertNotNil(renderer.nsImage, localeIdentifier)
        }
    }

    func testRenderedEnergyImpactRowPreservesBundleIconAndApplicationIdentifier() {
        let renderer = ImageRenderer(
            content: EnergyImpactRow(
                entry: entry(bundleURL: Bundle.main.bundleURL),
                rank: 1,
                showsApplicationIdentifier: true
            )
            .frame(width: 420, height: ActiveProcessMemoryLayout.rowHeight)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
    }

    func testEnergyImpactRowIdentifierCanBeHidden() {
        XCTAssertEqual(
            EnergyImpactRow.identifierText(
                for: entry(),
                showsApplicationIdentifier: true,
                bundle: Self.englishBundle
            ),
            "com.apple.Safari"
        )
        XCTAssertNil(
            EnergyImpactRow.identifierText(
                for: entry(),
                showsApplicationIdentifier: false,
                bundle: Self.englishBundle
            )
        )
    }

    func testEnergyImpactRowUsesBundleIconWhenBundleExists() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Safari.app")

        XCTAssertEqual(
            EnergyImpactRow.iconSource(for: entry(bundleURL: bundleURL), fileExists: { _ in true }),
            .bundle(bundleURL)
        )
    }

    func testEnergyImpactRowFallsBackToSystemIconWhenBundleMissing() {
        XCTAssertEqual(
            EnergyImpactRow.iconSource(for: entry(bundleURL: URL(fileURLWithPath: "/Applications/Missing.app")), fileExists: { _ in false }),
            .fallbackSystemSymbol
        )
    }

    func testEnergyImpactRowAccessibilityIncludesOneBasedRankAndPowerText() {
        XCTAssertEqual(
            EnergyImpactPresentation.accessibilityLabel(
                entry: entry(name: "Safari", power: 860),
                rank: 2,
                bundle: Self.englishBundle
            ),
            "Safari, rank 2, 860 µW"
        )
    }

    private func entry(
        processIdentifier: pid_t = 101,
        name: String = "Safari",
        bundleURL: URL? = nil,
        power: Double? = 860,
        status: EnergyImpactStatus = .stable
    ) -> EnergyImpactEntry {
        EnergyImpactEntry(
            identity: EnergyImpactAppIdentity(
                rootProcessIdentifier: processIdentifier,
                rootProcessStartAbsoluteTime: 1
            ),
            name: name,
            bundleIdentifier: "com.apple.Safari",
            bundleURL: bundleURL,
            currentPowerMicrowatts: power,
            sustainedPowerMicrowatts: power,
            rankingScore: power,
            trend: .steady,
            coverage: .unavailable,
            status: status
        )
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
