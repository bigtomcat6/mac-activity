import AppKit
import SwiftUI
import XCTest
@testable import MacActivityCore
@testable import MacActivityApp

@MainActor
final class EnergyImpactViewTests: XCTestCase {
    func testHostedListOverflowPreservesPageAndDocumentSessionsAndInteractionState() throws {
        let page = DashboardListLifecycleRecorder()
        let document = DashboardListLifecycleRecorder()
        let host = DashboardListTestHost(DashboardListPage(onNaturalHeightChange: { _ in }) {
            DashboardListLifecyclePage(page: page, document: document)
        })
        defer { host.close() }
        host.settle()
        let pageID = try XCTUnwrap(page.identities.first)
        let documentID = try XCTUnwrap(document.identities.first)
        page.edit?()
        document.edit?()
        host.settle()
        for height: CGFloat in [80, 480] {
            host.resize(height: height)
            XCTAssertEqual(page.identities, [pageID])
            XCTAssertEqual(document.identities, [documentID])
            XCTAssertEqual(page.interaction, "pending confirmation")
            XCTAssertEqual(document.interaction, "pending confirmation")
            XCTAssertEqual(page.starts, 1)
            XCTAssertEqual(document.starts, 1)
            XCTAssertEqual(page.cancellations, 0)
            XCTAssertEqual(document.cancellations, 0)
            XCTAssertEqual(host.scrollViews.count, 1)
            for inactive in host.allScrollViews where !inactive.hasVerticalScroller {
                XCTAssertEqual(inactive.documentView!.frame.height, inactive.contentView.bounds.height, accuracy: 1,
                               "inactive native containers must have no hidden scrollable overflow")
            }
        }
    }

    func testHostedDynamicSummaryAtOverflowThresholdSettlesWithoutTaskRestarts() {
        let page = DashboardListLifecycleRecorder()
        let document = DashboardListLifecycleRecorder()
        let host = DashboardListTestHost(DashboardListPage(onNaturalHeightChange: { _ in }) {
            DashboardListLifecyclePage(page: page, document: document, expandsSummary: true)
        }, height: 160)
        defer { host.close() }
        host.settle()
        host.settle()
        XCTAssertEqual(page.starts, 1)
        XCTAssertEqual(document.starts, 1)
        XCTAssertEqual(page.cancellations, 0)
        XCTAssertEqual(document.cancellations, 0)
        XCTAssertEqual(page.identities.count, 1)
        XCTAssertEqual(document.identities.count, 1)
    }

    private static var englishBundle: Bundle {
        AppLocalization.bundle(forLanguageIdentifier: "en")!
    }

    func testHostedTwentyRowsScrollInsideEnergyCard() async throws {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [publication(entries: (1...20).map {
                entry(processIdentifier: pid_t($0))
            })]),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        await model.refreshWhileVisible()
        let host = DashboardListTestHost(EnergyImpactView(
            model: model, powerFlowModel: testPowerFlowModel(), refreshTrigger: 0,
            showsApplicationIdentifier: true
        ).padding(18).environment(\.dashboardPresentationIsPresented, false))
        defer { host.close() }
        host.settle()
        XCTAssertEqual(host.scrollViews.count, 1, "only application rows should own scrolling")
        let scroll = try XCTUnwrap(host.scrollViews.first)
        let document = try XCTUnwrap(scroll.documentView)
        let viewport = host.rect(scroll)
        XCTAssertGreaterThan(viewport.minY, 18, "summary and columns must precede the rows")
        XCTAssertLessThanOrEqual(viewport.maxY, host.controller.view.bounds.height - 18 + 1)
        try host.assertBottomReachable(scroll)
        XCTAssertTrue(document.visibleRect.contains(NSRect(x: 0,
            y: document.bounds.maxY - 6 - 32, width: 1, height: 32 + 6)),
            "the last 32-point row and bottom padding are inside the visible document at the bottom")
        XCTAssertGreaterThanOrEqual(document.frame.height, 20 * 32 + 6)
    }

    func testHostedEnergyNaturalHeightSurvivesPanelClampAndListUpdates() async throws {
        let rowCounts = [20, 2, 1, 0]
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: rowCounts.map { count in
                publication(entries: (0..<count).map { entry(processIdentifier: pid_t($0 + 1)) })
            }), observationIntervalNanoseconds: 1, nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        await model.refreshWhileVisible()
        var heights: [CGFloat] = []
        let power = testPowerFlowModel()
        let host = DashboardListTestHost(DashboardListPage(onNaturalHeightChange: { heights.append($0) }) {
            EnergyImpactView(model: model, powerFlowModel: power, refreshTrigger: 0,
                             showsApplicationIdentifier: true).padding(18)
        }.environment(\.dashboardPresentationIsPresented, false))
        defer { host.close() }
        host.settle()
        let naturalHeight = try XCTUnwrap(heights.last)
        XCTAssertGreaterThan(naturalHeight, 560)
        let panelHost = DashboardPanelHost()
        host.panel.contentViewController = nil
        panelHost.show(contentViewController: host.controller,
            anchorRect: NSRect(x: 300, y: 500, width: 24, height: 24),
            visibleFrame: NSRect(x: 100, y: 100, width: 800, height: 330),
            contentSize: NSSize(width: 420, height: 560))
        defer { panelHost.destroy() }
        host.settle()
        XCTAssertLessThan(try XCTUnwrap(panelHost.contentSize).height, 560)
        XCTAssertEqual(try XCTUnwrap(heights.last), naturalHeight, accuracy: 1)
        let scroll = try XCTUnwrap(host.scrollViews.first)
        XCTAssertGreaterThan(host.rect(scroll).minY, 18)
        XCTAssertLessThanOrEqual(host.rect(scroll).maxY, host.controller.view.bounds.height - 18 + 1)
        try host.assertBottomReachable(scroll)
        let stableCount = heights.count
        host.settle()
        host.settle()
        XCTAssertEqual(heights.count, stableCount, "no idle measurement/resize feedback")
        for count in rowCounts.dropFirst() {
            await model.refreshWhileVisible()
            host.settle()
            XCTAssertEqual(model.entries.count, count)
            XCTAssertLessThan(try XCTUnwrap(heights.last), naturalHeight)
            let short = try XCTUnwrap(host.scrollViews.first)
            XCTAssertEqual(short.documentView!.frame.height, short.contentView.bounds.height, accuracy: 1)
        }
    }

    func testHostedEnergyLoadingAndEmptyDocumentsStayCompact() async throws {
        let provider = EnergyImpactViewProviderStub(responses: [publication(entries: [])])
        var resume: CheckedContinuation<Void, Never>?
        provider.beforeObservation = {
            await withCheckedContinuation { resume = $0 }
        }
        let model = EnergyImpactModel(provider: provider, observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 }, sleep: { _ in throw CancellationError() })
        let refresh = Task { await model.refreshWhileVisible() }
        for _ in 0..<100 where resume == nil { await Task.yield() }
        let continuation = try XCTUnwrap(resume)
        let power = testPowerFlowModel()
        var naturalHeight: CGFloat = 0
        let host = DashboardListTestHost(DashboardListPage(onNaturalHeightChange: { naturalHeight = $0 }) {
            EnergyImpactView(model: model, powerFlowModel: power, refreshTrigger: 0,
                             showsApplicationIdentifier: true).padding(18)
        }.environment(\.dashboardPresentationIsPresented, false))
        defer { host.close() }
        host.settle()
        XCTAssertTrue(model.isRefreshing)
        XCTAssertLessThan(naturalHeight, 300)
        let loading = try XCTUnwrap(host.scrollViews.first)
        XCTAssertEqual(loading.documentView!.frame.height, loading.contentView.bounds.height, accuracy: 1)
        provider.beforeObservation = nil
        continuation.resume()
        await refresh.value
        host.settle()
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertLessThan(naturalHeight, 300)
        let empty = try XCTUnwrap(host.scrollViews.first)
        XCTAssertEqual(empty.documentView!.frame.height, empty.contentView.bounds.height, accuracy: 1)
    }

    func testHostedEnergyFallsBackToOnePageScrollerOnlyWhenChromeCannotFit() async throws {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [publication(entries: (1...20).map {
                entry(processIdentifier: pid_t($0))
            })]), observationIntervalNanoseconds: 1, nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        await model.refreshWhileVisible()
        var naturalHeight: CGFloat = 0
        let power = testPowerFlowModel()
        let host = DashboardListTestHost(DashboardListPage(onNaturalHeightChange: { naturalHeight = $0 }) {
            EnergyImpactView(model: model, powerFlowModel: power, refreshTrigger: 0,
                             showsApplicationIdentifier: true).padding(18)
        }.environment(\.dashboardPresentationIsPresented, false))
        defer { host.close() }
        host.settle()
        let initialHeight = naturalHeight
        host.resize(height: 80)
        XCTAssertEqual(host.scrollViews.count, 1, "no nested active scrollers in overflow fallback")
        let outer = try XCTUnwrap(host.scrollViews.first)
        XCTAssertEqual(host.rect(outer).minY, 0, accuracy: 1)
        XCTAssertEqual(naturalHeight, initialHeight, accuracy: 1)
        try host.assertBottomReachable(outer)
        outer.contentView.scroll(to: .zero)
        outer.reflectScrolledClipView(outer.contentView)
        XCTAssertEqual(outer.contentView.bounds.minY, 0, accuracy: 1, "fixed content remains accessible at page top")
        host.resize(height: 480)
        XCTAssertEqual(host.scrollViews.count, 1)
        XCTAssertGreaterThan(host.rect(try XCTUnwrap(host.scrollViews.first)).minY, 18,
                             "return to rows-only scrolling when space becomes available")
        XCTAssertEqual(naturalHeight, initialHeight, accuracy: 1)
    }

    func testForcedLegacyPopoverHostsEnergyRowsAndReopensWithoutNaturalHeightDrift() async throws {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [publication(entries: (1...20).map {
                entry(processIdentifier: pid_t($0))
            })]), observationIntervalNanoseconds: 1, nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        await model.refreshWhileVisible()
        let power = testPowerFlowModel()
        var naturalHeight: CGFloat = 0
        let controller = NSHostingController(rootView: DashboardListPage(onNaturalHeightChange: { naturalHeight = $0 }) {
            EnergyImpactView(model: model, powerFlowModel: power, refreshTrigger: 0,
                             showsApplicationIdentifier: true).padding(18)
        }.environment(\.dashboardPresentationIsPresented, false))
        let adaptive = DashboardAdaptivePopoverHost(hostKindProvider: { .popover })
        adaptive.animates = false
        adaptive.contentViewController = controller
        adaptive.contentSize = NSSize(width: 420, height: 480)
        let screen = try XCTUnwrap(NSScreen.main)
        let anchorWindow = NSWindow(contentRect: NSRect(x: screen.visibleFrame.midX,
            y: screen.visibleFrame.midY, width: 80, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 24, height: 24))
        anchorWindow.contentView?.addSubview(anchor)
        anchorWindow.orderFront(nil)
        defer { adaptive.performClose(nil); anchorWindow.orderOut(nil) }
        var firstHeight: CGFloat?
        for _ in 0..<2 {
            adaptive.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(adaptive.activeHostKind, .popover)
            XCTAssertTrue(adaptive.isShown)
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                ((view as? NSScrollView).map { $0.hasVerticalScroller ? [$0] : [] } ?? [])
                    + view.subviews.flatMap(scrollViews)
            }
            let scroll = try XCTUnwrap(scrollViews(controller.view).first)
            XCTAssertGreaterThan(scroll.documentView!.frame.height, scroll.contentView.bounds.height)
            if let firstHeight { XCTAssertEqual(naturalHeight, firstHeight, accuracy: 1) }
            else { firstHeight = naturalHeight }
            adaptive.performClose(nil)
        }
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
        XCTAssertNotEqual(
            EnergyImpactRefreshTaskID(trigger: 1, scope: .regularOnly),
            EnergyImpactRefreshTaskID(trigger: 1, scope: .regularOnly, presented: false)
        )
        XCTAssertNotEqual(
            ActiveCleanReleaseRefreshTaskID(presented: true, trigger: 1),
            ActiveCleanReleaseRefreshTaskID(presented: false, trigger: 1)
        )
        XCTAssertNotEqual(
            ActiveCleanReleaseQuitRefreshTaskID(presented: true, identifiers: [1]),
            ActiveCleanReleaseQuitRefreshTaskID(presented: false, identifiers: [1])
        )
        XCTAssertNotEqual(
            PowerFlowRefreshTaskID(presented: true, trigger: 1),
            PowerFlowRefreshTaskID(presented: false, trigger: 1)
        )
        XCTAssertTrue(ActiveCleanReleaseRefreshTaskID(trigger: 1).presented)
        XCTAssertTrue(ActiveCleanReleaseQuitRefreshTaskID(identifiers: [1]).presented)
        XCTAssertTrue(PowerFlowRefreshTaskID(trigger: 1).presented)
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

    func testEnergyImpactViewUsesFullScopeCoverageBeyondTwentyVisibleRows() async {
        let rows = (1...20).map { index in
            entry(processIdentifier: pid_t(index))
        }
        let coverage = EnergyImpactCoverage(
            discoveredProcessCount: 42,
            readableProcessCount: 21,
            validProcessSeconds: 63,
            discoveredProcessSeconds: 126
        )
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [
                EnergyImpactPublication(entries: rows, coverage: coverage),
            ]),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        await model.refreshWhileVisible()

        XCTAssertEqual(model.entries.count, 20)
        XCTAssertEqual(
            EnergyImpactView.coverageText(model: model, bundle: Self.englishBundle),
            "21 of 42 processes readable · Checked just now"
        )
    }

    func testEnergyImpactViewSummarizesCoverageAfterAnObservation() async {
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [
                publication(
                    entries: [entry(), entry(processIdentifier: 202)],
                    coverage: EnergyImpactCoverage(
                        discoveredProcessCount: 4,
                        readableProcessCount: 2,
                        validProcessSeconds: 3,
                        discoveredProcessSeconds: 6
                    )
                ),
            ]),
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
            provider: EnergyImpactViewProviderStub(responses: [
                EnergyImpactPublication(entries: [], coverage: .unavailable),
            ]),
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
                powerFlowModel: testPowerFlowModel(),
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
        let provider = EnergyImpactViewProviderStub(responses: [publication(entries: [])])
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: model,
                powerFlowModel: testPowerFlowModel(),
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
        let provider = EnergyImpactViewProviderStub(responses: [publication(entries: [])])
        let model = EnergyImpactModel(
            provider: provider,
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: model,
                powerFlowModel: testPowerFlowModel(),
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

    func testRenderedEnergyImpactViewIncludesPowerFlowAtFourHundredTwentyPoints() async {
        let powerFlowModel = PowerFlowModel(
            provider: EnergyImpactPowerFlowProviderStub(responses: [
                PowerFlowSnapshot(endpoints: [
                    PowerFlowEndpoint(id: "external", type: .usbC, direction: .input, measurement: .unavailable),
                    PowerFlowEndpoint(id: "mac", type: .mac, direction: .output, measurement: .unavailable),
                ])
            ]),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        let energyModel = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [publication(entries: [])]),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )

        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: energyModel,
                powerFlowModel: powerFlowModel,
                refreshTrigger: 0,
                showsApplicationIdentifier: true
            )
            .frame(width: 420, height: 560)
        )
        renderer.scale = 1

        XCTAssertNotNil(renderer.nsImage)
    }

    private func assertLocalizedEnergyImpactViewRendersAtFourHundredTwentyPoints() async {
        let preferredLanguageIdentifier = AppLocalization.explicitPreferredLanguageIdentifier()
        defer { AppLocalization.setPreferredLanguageIdentifier(preferredLanguageIdentifier) }
        let renderedEntry = entry(power: 1_400, sustainedPower: 1_000, trend: .rising)
        let model = EnergyImpactModel(
            provider: EnergyImpactViewProviderStub(responses: [publication(entries: [renderedEntry])]),
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
                "Energy",
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
            XCTAssertEqual(AppLocalization.string(.dashboardTabEnergyImpact), expectation.title)
            XCTAssertEqual(AppLocalization.string(.energyImpactSubtitleSustained), expectation.subtitle)
            XCTAssertEqual(AppLocalization.string(.energyImpactSustainedColumn), expectation.sustainedLabel)
            XCTAssertEqual(
                EnergyImpactPresentation.row(entry: renderedEntry, rank: 1).accessibilityLabel,
                expectation.accessibilityLabel
            )

            let renderer = ImageRenderer(
                content: EnergyImpactView(
                    model: model,
                    powerFlowModel: testPowerFlowModel(),
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
            provider: EnergyImpactViewProviderStub(responses: [
                publication(entries: [entry(kind: .accessory)]),
            ]),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
        await model.refreshWhileVisible(scope: .regularAndAccessory)
        let renderer = ImageRenderer(
            content: EnergyImpactView(
                model: model,
                powerFlowModel: testPowerFlowModel(),
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

    private func testPowerFlowModel(
        responses: [PowerFlowSnapshot] = [PowerFlowSnapshot.empty]
    ) -> PowerFlowModel {
        PowerFlowModel(
            provider: EnergyImpactPowerFlowProviderStub(responses: responses),
            observationIntervalNanoseconds: 1,
            nowNanoseconds: { 0 },
            sleep: { _ in throw CancellationError() }
        )
    }

    private func publication(
        entries: [EnergyImpactEntry],
        coverage: EnergyImpactCoverage = .unavailable
    ) -> EnergyImpactPublication {
        EnergyImpactPublication(entries: entries, coverage: coverage)
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
    var beforeObservation: (() async -> Void)?
    private var responses: [EnergyImpactPublication]
    private var nextGeneration: UInt64 = 0
    private(set) var beginCount = 0
    private(set) var observeCount = 0
    private(set) var endCount = 0
    private(set) var requestedScopes: [EnergyImpactAppScope] = []

    init(responses: [EnergyImpactPublication]) {
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
    ) async -> EnergyImpactPublication? {
        await beforeObservation?()
        observeCount += 1
        requestedScopes.append(scope)
        guard responses.isEmpty == false else { return nil }
        return responses.removeFirst()
    }

    func endSession(_ lease: EnergyImpactSamplingLease) async {
        endCount += 1
    }
}

@MainActor
private final class EnergyImpactPowerFlowProviderStub: PowerFlowProviding {
    private var responses: [PowerFlowSnapshot]

    init(responses: [PowerFlowSnapshot]) {
        self.responses = responses
    }

    func snapshot() async -> PowerFlowSnapshot {
        guard responses.isEmpty == false else { return .empty }
        return responses.removeFirst()
    }
}

// Shared real AppKit hosting/geometry fixture for bounded dashboard lists.
@MainActor
private final class DashboardListLifecycleRecorder {
    var starts = 0
    var cancellations = 0
    var identities: Set<UUID> = []
    var interaction = ""
    var edit: (() -> Void)?
}

@MainActor
private struct DashboardListLifecyclePage: View {
    let page: DashboardListLifecycleRecorder
    let document: DashboardListLifecycleRecorder
    var expandsSummary = false
    @State private var identity = UUID()
    @State private var interaction = ""
    @State private var summaryHeight: CGFloat = 78

    var body: some View {
        VStack(spacing: 8) {
            Color.clear.frame(height: summaryHeight).fixedSize().layoutPriority(1)
            DashboardMeasuredList(spacing: 0) {
                DashboardListLifecycleDocument(recorder: document)
            }
        }
        .padding(18)
        .onAppear {
            page.identities.insert(identity)
            page.interaction = interaction
            page.edit = { interaction = "pending confirmation" }
        }
        .onChange(of: interaction) { page.interaction = $0 }
        .task {
            page.starts += 1
            if expandsSummary { summaryHeight = 97.5 }
            defer { page.cancellations += 1 }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}

@MainActor
private struct DashboardListLifecycleDocument: View {
    let recorder: DashboardListLifecycleRecorder
    @State private var identity = UUID()
    @State private var interaction = ""

    var body: some View {
        Text(interaction).frame(height: 700)
            .onAppear {
                recorder.identities.insert(identity)
                recorder.interaction = interaction
                recorder.edit = { interaction = "pending confirmation" }
            }
            .onChange(of: interaction) { recorder.interaction = $0 }
            .task {
                recorder.starts += 1
                defer { recorder.cancellations += 1 }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
    }
}

@MainActor
final class DashboardListTestHost {
    let controller: NSHostingController<AnyView>
    let panel: NSPanel

    init<Content: View>(_ view: Content, height: CGFloat = 480) {
        controller = NSHostingController(rootView: AnyView(view))
        panel = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 420, height: height),
                        styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = controller
        panel.setContentSize(NSSize(width: 420, height: height))
        panel.orderFront(nil)
    }

    func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        controller.view.layoutSubtreeIfNeeded()
    }

    func resize(height: CGFloat) {
        panel.setContentSize(NSSize(width: 420, height: height))
        settle()
    }

    func close() { panel.orderOut(nil) }

    // SwiftUI's disabled scroll scopes remove their native vertical scroller.
    // Count enabled scopes, not the stable but inactive wrapper containers.
    var scrollViews: [NSScrollView] { allScrollViews.filter(\.hasVerticalScroller) }

    var allScrollViews: [NSScrollView] {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        return descendants(controller.view).compactMap { $0 as? NSScrollView }.sorted {
            rect($0).minY < rect($1).minY
        }
    }

    func rect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: controller.view) }

    func assertBottomReachable(_ scroll: NSScrollView, file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        let viewport = rect(scroll)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height, file: file, line: line)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.maxY - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        XCTAssertEqual(rect(scroll), viewport, file: file, line: line)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 1, file: file, line: line)
    }
}
