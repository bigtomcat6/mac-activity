import AppKit
import SwiftUI
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactViewTests: XCTestCase {
    private static var englishBundle: Bundle {
        AppLocalization.bundle(forLanguageIdentifier: "en")!
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

    func testEnergyImpactViewExpandedEmptyCopyAndScopeBearingTaskIdentity() {
        XCTAssertEqual(
            EnergyImpactView.emptyMessage(
                isRefreshing: false,
                scope: .regularAndAccessory,
                bundle: Self.englishBundle
            ),
            "No regular or menu-bar apps are reporting an energy estimate."
        )
        XCTAssertNotEqual(
            EnergyImpactRefreshTaskID(trigger: 1, scope: .regularOnly),
            EnergyImpactRefreshTaskID(trigger: 1, scope: .regularAndAccessory)
        )
    }

    func testEnergyImpactViewDoesNotClaimACompletedCheckBeforeFirstObservation() {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: []),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        XCTAssertNil(EnergyImpactView.coverageText(model: model, bundle: Self.englishBundle))
    }

    func testEnergyImpactViewSummarizesCoverageAfterAnObservation() async {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [[entry(), entry(processIdentifier: 202)]]),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(
            EnergyImpactView.coverageText(model: model, bundle: Self.englishBundle),
            "2 of 4 processes readable · Checked just now"
        )
    }

    func testEnergyImpactViewReportsAnEmptyCompletedObservation() async {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [[]]),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(
            EnergyImpactView.coverageText(model: model, bundle: Self.englishBundle),
            "0 of 0 processes readable · Checked just now"
        )
    }

    func testRenderedEnergyImpactViewShowsEmptyStateAtFourHundredTwentyPoints() {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: []),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: model,
                refreshTrigger: 0,
                showsApplicationIdentifier: true
            )
            .environment(\.locale, Locale(identifier: "en"))
            .frame(width: 420, height: 560)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
    }

    func testRenderedEnergyImpactViewStartsVisibleLifecycleThroughModel() async {
        let provider = EnergyImpactViewProviderStub(responses: [[]])
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: model,
                refreshTrigger: 0,
                showsApplicationIdentifier: true
            )
            .frame(width: 420, height: 560)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
        for _ in 0..<100 where provider.beginCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(provider.beginCount, 1)
        XCTAssertEqual(provider.observeCount, 1)
        XCTAssertEqual(provider.endCount, 1)
    }

    func testRenderedEnergyImpactViewForwardsExpandedScopeToModel() async {
        let provider = EnergyImpactViewProviderStub(responses: [[]])
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: model,
                refreshTrigger: 0,
                scope: .regularAndAccessory,
                showsApplicationIdentifier: true
            )
            .frame(width: 420, height: 560)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
        for _ in 0..<100 where provider.observeCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(provider.requestedScopes, [.regularAndAccessory])
    }

    func testRenderedEnergyImpactViewShowsLocalizedContentAtFourHundredTwentyPointsAndRestoresPreferredLanguageOverride() async {
        let initialPreferredLanguageIdentifier = AppLocalization.explicitPreferredLanguageIdentifier()
        defer { AppLocalization.setPreferredLanguageIdentifier(initialPreferredLanguageIdentifier) }

        AppLocalization.setPreferredLanguageIdentifier("fr")
        await assertLocalizedEnergyImpactViewRendersAtFourHundredTwentyPoints()

        XCTAssertEqual(AppLocalization.explicitPreferredLanguageIdentifier(), "fr")
    }

    private func assertLocalizedEnergyImpactViewRendersAtFourHundredTwentyPoints() async {
        let preferredLanguageIdentifier = AppLocalization.explicitPreferredLanguageIdentifier()
        defer { AppLocalization.setPreferredLanguageIdentifier(preferredLanguageIdentifier) }
        let renderedEntry = entry(power: 1_400, sustainedPower: 1_000, trend: .rising)
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [[renderedEntry]]),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        await model.refreshWhileVisible()

        let expectations: [(
            languageIdentifier: String,
            title: String,
            subtitle: String,
            sustainedLabel: String,
            accessibilityLabel: String
        )] = [
            (
                "en",
                "Energy Impact",
                "Up to 30 sec CPU energy estimate · Lower is better",
                "30 sec",
                "Safari, rank 1, up to 30 seconds 1 mW, rising"
            ),
            (
                "zh-Hans",
                "耗电影响",
                "最近最多 30 秒 CPU 能耗估算 · 越低越好",
                "30 秒",
                "Safari，第 1 名，最近最多 30 秒 1 mW，上升"
            )
        ]

        for expectation in expectations {
            AppLocalization.setPreferredLanguageIdentifier(expectation.languageIdentifier)
            XCTAssertEqual(AppLocalization.string(.energyImpactTitle), expectation.title)
            XCTAssertEqual(AppLocalization.string(.energyImpactSubtitleSustained), expectation.subtitle)
            XCTAssertEqual(AppLocalization.string(.energyImpactSustainedColumn), expectation.sustainedLabel)
            XCTAssertEqual(
                EnergyImpactPresentation.row(entry: renderedEntry, rank: 1).accessibilityLabel,
                expectation.accessibilityLabel
            )

            let renderer = ImageRenderer(
                content: EnergyImpactView(
                    model: model,
                    refreshTrigger: 0,
                    showsApplicationIdentifier: true
                )
                .frame(width: 420, height: 560)
            )
            renderer.scale = 1

            XCTAssertNotNil(renderer.nsImage, expectation.languageIdentifier)
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

    func testEnergyImpactRowAccessibilityContainsAppRankWindowValueAndStateOrTrend() {
        let row = EnergyImpactPresentation.row(
            entry: entry(power: 1_400, sustainedPower: 1_000, trend: .rising),
            rank: 2,
            bundle: Self.englishBundle
        )

        XCTAssertEqual(
            row.accessibilityLabel,
            "Safari, rank 2, up to 30 seconds 1 mW, rising"
        )
    }

    func testRenderedExpandedEnergyImpactViewSupportsAccessoryBadgeAtFourHundredTwentyPoints() async {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [[entry(kind: .accessory)]]),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        await model.refreshWhileVisible(scope: .regularAndAccessory)
        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: model,
                refreshTrigger: 0,
                scope: .regularAndAccessory,
                showsApplicationIdentifier: true
            )
            .frame(width: 420, height: 560)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
    }

    func testRenderedEnergyImpactRowHandlesLongNameAndBothIdentifierPreferencesAtFourHundredTwentyPoints() {
        for kind in [EnergyImpactAppKind.regular, .accessory] {
            let renderedEntry = entry(
                kind: kind,
                name: String(repeating: "A", count: 60),
                power: 1_400,
                sustainedPower: 1_000
            )
            for showsApplicationIdentifier in [false, true] {
                let renderer = ImageRenderer(
                    content: EnergyImpactRow(
                        entry: renderedEntry,
                        rank: 1,
                        showsApplicationIdentifier: showsApplicationIdentifier
                    )
                    .frame(width: 420, height: ActiveProcessMemoryLayout.rowHeight)
                )
                renderer.scale = 1

                XCTAssertNotNil(
                    renderer.nsImage,
                    "kind=\(kind) showsApplicationIdentifier=\(showsApplicationIdentifier)"
                )
            }
        }
    }

    private func entry(
        kind: EnergyImpactAppKind = .regular,
        processIdentifier: pid_t = 101,
        name: String = "Safari",
        bundleURL: URL? = nil,
        power: Double? = 860,
        sustainedPower: Double? = nil,
        trend: EnergyImpactTrend = .steady,
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
            kind: kind,
            currentPowerMicrowatts: power,
            sustainedPowerMicrowatts: sustainedPower ?? power,
            rankingScore: power,
            trend: trend,
            coverage: EnergyImpactCoverage(
                discoveredProcessCount: 2,
                readableProcessCount: 1,
                validProcessSeconds: 3,
                discoveredProcessSeconds: 6
            ),
            status: status,
            observedWindowSeconds: 30
        )
    }
}

@MainActor
private final class EnergyImpactViewProviderStub: EnergyImpactProviding {
    private var responses: [[EnergyImpactEntry]]
    private var nextGeneration: UInt64 = 0
    private(set) var beginCount = 0
    private(set) var observeCount = 0
    private(set) var endCount = 0
    private(set) var requestedScopes: [EnergyImpactAppScope] = []

    init(responses: [[EnergyImpactEntry]]) {
        self.responses = responses
    }

    func beginSession() async -> EnergyImpactSamplingLease? {
        beginCount += 1
        nextGeneration += 1
        return EnergyImpactSamplingLease(requestGeneration: nextGeneration)
    }

    func observe(
        lease: EnergyImpactSamplingLease,
        limit: Int,
        scope: EnergyImpactAppScope
    ) async -> [EnergyImpactEntry]? {
        observeCount += 1
        requestedScopes.append(scope)
        return responses.isEmpty ? [] : Array(responses.removeFirst().prefix(limit))
    }

    func endSession(_ lease: EnergyImpactSamplingLease) async {
        endCount += 1
    }
}
