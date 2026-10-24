import AppKit
import SwiftUI
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class BatteryCareLayoutTests: XCTestCase {
    func testNaturalHeightAddsMeasuredBatteryCareWithoutTakingOldViewport() {
        XCTAssertEqual(DashboardPopoverLayout.contentSize(for: NSSize(width: 420, height: 900),
            batteryCareHeight: 122, availableHeight: 1000), NSSize(width: 420, height: 682))
        XCTAssertEqual(DashboardPopoverLayout.contentSize(for: NSSize(width: 420, height: 350),
            batteryCareHeight: 122, availableHeight: 1000), NSSize(width: 420, height: 350))
        XCTAssertEqual(DashboardPopoverLayout.contentSize(for: NSSize(width: 420, height: 900),
            batteryCareHeight: 226, availableHeight: 460), NSSize(width: 420, height: 460))
    }

    func testInvalidOrIncompleteMeasurementsDoNotProduceSize() {
        for invalid: CGFloat in [.nan, .infinity, -1] {
            XCTAssertNil(DashboardPopoverLayout.contentSize(for: NSSize(width: 420, height: 700),
                batteryCareHeight: invalid, availableHeight: 800))
            XCTAssertNil(DashboardPopoverLayout.contentSize(for: NSSize(width: 420, height: 700),
                batteryCareHeight: 122, availableHeight: invalid))
        }
        let measurement = DashboardPopoverContentMeasurement()
        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(800, for: .scrollContent)
        XCTAssertNil(measurement.latestContentSize)
        measurement.report(.nan, for: .batteryCare)
        XCTAssertNil(measurement.latestContentSize)
        measurement.report(122, for: .batteryCare)
        XCTAssertEqual(measurement.latestContentSize, NSSize(width: 420, height: 965))
        XCTAssertEqual(measurement.batteryCareHeight, 122)
    }

    func testBootstrapIsReplacedByCompleteNaturalMeasurementAbove560() {
        let measurement = DashboardPopoverContentMeasurement()
        measurement.seedIfNeeded(NSSize(width: 420, height: 560))
        measurement.report(122, for: .batteryCare)
        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(800, for: .scrollContent)
        XCTAssertEqual(measurement.latestContentSize, NSSize(width: 420, height: 965))
        XCTAssertEqual(DashboardPopoverLayout.contentSize(for: measurement.latestContentSize!,
            batteryCareHeight: measurement.batteryCareHeight, availableHeight: 1000)?.height, 682)
    }

    func testSeedEqualToNaturalTotalStillPublishesNewBatteryBudget() {
        let measurement = DashboardPopoverContentMeasurement()
        measurement.seedIfNeeded(NSSize(width: 420, height: 965))
        var sizes: [NSSize] = []
        measurement.onContentSizeChange = { sizes.append($0) }
        measurement.report(122, for: .batteryCare)
        measurement.report(42, for: .header)
        measurement.report(1, for: .headerDivider)
        measurement.report(800, for: .scrollContent)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(sizes, [NSSize(width: 420, height: 965)], "seed has no battery budget; complete measurement must replace it")
        measurement.report(.greatestFiniteMagnitude, for: .batteryCare)
        measurement.report(.greatestFiniteMagnitude, for: .scrollContent)
        XCTAssertTrue(measurement.latestContentSize?.height.isFinite == true)
    }

    func testSliderPreviewDoesNotResizeWindow() async throws {
        let preferences = PreferencesController(store: PreferencesStoreFake(), launchService: NoopLaunchAtLoginService())
        let model = makeTestBatteryCareModel(preferences: preferences)
        let measurement = DashboardPopoverContentMeasurement()
        let host = DashboardListTestHost(DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: preferences,
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            batteryCareModel: model, onMeasuredSegmentHeight: { measurement.report($1, for: $0) }
        ).environment(\.dashboardPresentationIsPresented, false))
        defer { measurement.onContentSizeChange = nil; host.close() }
        measurement.onContentSizeChange = { size in
            if let size = DashboardPopoverLayout.contentSize(for: size,
                batteryCareHeight: measurement.batteryCareHeight, availableHeight: 1000) {
                host.panel.setContentSize(size)
            }
        }
        host.settle(); host.settle()
        let initialSize = try XCTUnwrap(DashboardPopoverLayout.contentSize(
            for: try XCTUnwrap(measurement.latestContentSize),
            batteryCareHeight: measurement.batteryCareHeight, availableHeight: 1000))
        host.panel.setContentSize(initialSize)
        host.settle()
        let height = host.panel.frame.height
        let batteryHeight = measurement.batteryCareHeight
        XCTAssertGreaterThan(batteryHeight, 0)
        print("A7 slider: width=\(host.panel.frame.width) naturalWindow=\(height) battery=\(batteryHeight)")
        for limit in [50, 100, 80] {
            model.previewLimit(limit)
            host.settle()
            XCTAssertEqual(host.panel.frame.height, height, accuracy: 1)
            XCTAssertEqual(measurement.batteryCareHeight, batteryHeight, accuracy: 1)
        }
        model.cancelPreview()
        host.settle()
        XCTAssertEqual(host.panel.frame.height, height, accuracy: 1)
        model.previewLimit(100)
        await model.commitPreview()
        host.settle()
        XCTAssertEqual(host.panel.frame.height, height, accuracy: 1)
    }

    func testShortViewportKeepsHeaderFixedAndExtremeViewportScrollsInsteadOfClipping() throws {
        let preferences = PreferencesController(store: PreferencesStoreFake(), launchService: NoopLaunchAtLoginService())
        var heights: [DashboardContentMeasurementSegment: CGFloat] = [:]
        let host = DashboardListTestHost(DashboardView(
            dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
            preferencesController: preferences,
            audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
            batteryCareModel: makeTestBatteryCareModel(preferences: preferences),
            onMeasuredSegmentHeight: { heights[$0] = $1 }
        ).environment(\.dashboardPresentationIsPresented, false), height: 300)
        defer { host.close() }
        host.settle(); host.settle()
        let fixedHeight = try XCTUnwrap(heights[.batteryCare]) +
            (try XCTUnwrap(heights[.header])) + (try XCTUnwrap(heights[.headerDivider]))
        let scroll = try XCTUnwrap(host.scrollViews.first)
        XCTAssertEqual(host.scrollViews.count, 1)
        XCTAssertEqual(scroll.frame.height, 300 - fixedHeight, accuracy: 1)
        let controls = try XCTUnwrap(descendants(host.controller.view).compactMap { $0 as? BatteryCareNativeControls }.first)
        let before = host.rect(controls)
        try host.assertBottomReachable(scroll)
        XCTAssertEqual(host.rect(controls), before, "normal header must not scroll with the page")
        host.resize(height: 80)
        host.settle()
        XCTAssertEqual(host.panel.frame.height, 80, accuracy: 1, "a min-size-expanded offscreen root is not adaptation")
        let fallback = try XCTUnwrap(host.scrollViews.first)
        XCTAssertEqual(host.scrollViews.count, 1)
        XCTAssertLessThanOrEqual(fallback.frame.height, 80)
        try host.assertBottomReachable(fallback)
        host.resize(height: 300)
        host.settle()
        let restored = try XCTUnwrap(descendants(host.controller.view).compactMap { $0 as? BatteryCareNativeControls }.first)
        XCTAssertEqual(host.rect(restored), before)
    }

    func testFourPagesKeepNaturalContentAndExposeSingleExtremeScrollAndKeyboardControl() throws {
        for tab in DashboardTab.allCases {
            let preferences = PreferencesController(store: PreferencesStoreFake(), launchService: NoopLaunchAtLoginService())
            var heights: [DashboardContentMeasurementSegment: CGFloat] = [:]
            let host = DashboardListTestHost(DashboardView(
                dashboardModel: DashboardModel(store: MetricsStore(), isActive: false),
                preferencesController: preferences,
                audioDashboardModel: AudioDashboardModel(coordinator: TestAudioControlCoordinator()),
                batteryCareModel: makeTestBatteryCareModel(preferences: preferences),
                onMeasuredSegmentHeight: { heights[$0] = $1 }, initialSelectedTab: tab
            ).environment(\.dashboardPresentationIsPresented, false), height: 400)
            defer { host.close() }
            host.settle(); host.settle()
            let natural = try XCTUnwrap(heights[.scrollContent])
            let fixed = try XCTUnwrap(heights[.batteryCare]) +
                (try XCTUnwrap(heights[.header])) + (try XCTUnwrap(heights[.headerDivider]))
            host.resize(height: 260)
            host.settle()
            XCTAssertEqual(try XCTUnwrap(heights[.scrollContent]), natural, accuracy: 1, "\(tab) must not compress its document")
            let controls = try XCTUnwrap(descendants(host.controller.view).compactMap { $0 as? BatteryCareNativeControls }.first)
            XCTAssertEqual(host.rect(controls).minY, 0, accuracy: 1)
            XCTAssertTrue(host.allScrollViews.contains { abs(host.rect($0).minY - fixed) < 1 })
            host.resize(height: 80)
            host.settle(); host.settle()
            XCTAssertEqual(host.panel.frame.height, 80, accuracy: 1)
            XCTAssertEqual(host.scrollViews.count, 1, "\(tab) must not have nested active scopes")
            let scroll = try XCTUnwrap(host.scrollViews.first)
            try host.assertBottomReachable(scroll)
            let more = try XCTUnwrap(descendants(host.controller.view).first {
                $0.accessibilityIdentifier() == "batteryCare.more"
            })
            XCTAssertTrue(host.panel.makeFirstResponder(more))
            more.scrollToVisible(more.bounds)
            host.settle()
            XCTAssertTrue(host.panel.firstResponder === more)
            XCTAssertTrue(scroll.contentView.documentVisibleRect.intersects(more.convert(more.bounds, to: scroll.documentView)))
            print("A7 geometry \(tab): fixed=\(fixed) naturalPage=\(natural) extremeViewport=\(scroll.contentView.bounds.height) document=\(scroll.documentView?.frame.height ?? 0)")
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
