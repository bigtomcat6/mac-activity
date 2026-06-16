import AppKit
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class StatusBarSummaryLayoutTests: XCTestCase {
    func testImagePresentationUsesTwoLineStatusBarImage() {
        let items = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "38%", secondaryText: "MEM", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓15.4K", style: .network),
        ]

        let presentation = StatusBarSummaryLayout.imagePresentation(
            summaryText: "fallback",
            items: items
        )

        XCTAssertEqual(presentation.accessibilityTitle, "CPU 7% | MEM 38% | ↑13.8K ↓15.4K")
        XCTAssertEqual(presentation.image.size.height, StatusBarSummaryLayout.statusBarHeight)
        XCTAssertEqual(presentation.image.size.width, StatusBarSummaryLayout.preferredWidth(for: items))
        XCTAssertGreaterThanOrEqual(presentation.length, 44)
        XCTAssertTrue(presentation.image.isTemplate)
    }

    func testImagePresentationUsesFallbackTextWhenNoStructuredItemsExist() {
        let presentation = StatusBarSummaryLayout.imagePresentation(
            summaryText: "Metrics",
            items: []
        )

        XCTAssertEqual(presentation.accessibilityTitle, "Metrics")
        XCTAssertEqual(presentation.image.size.height, StatusBarSummaryLayout.statusBarHeight)
        XCTAssertEqual(presentation.image.size.width, presentation.length)
        XCTAssertGreaterThanOrEqual(presentation.length, 44)
    }

    func testPreferredWidthUsesDeterministicColumnsAndSeparators() {
        let items = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "38%", secondaryText: "MEM", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓15.4K", style: .network),
        ]

        XCTAssertLessThanOrEqual(StatusBarSummaryLayout.preferredWidth(for: items), 154)
        XCTAssertEqual(StatusBarSummaryLayout.preferredWidth(for: []), 0)
    }

    func testFontsUseReadableStatusBarSizes() {
        XCTAssertEqual(StatusBarSummaryLayout.primaryFont(for: .metric).pointSize, 10)
        XCTAssertEqual(StatusBarSummaryLayout.secondaryFont(for: .metric).pointSize, 6)
        XCTAssertEqual(StatusBarSummaryLayout.primaryFont(for: .network).pointSize, 8)
        XCTAssertEqual(StatusBarSummaryLayout.secondaryFont(for: .network).pointSize, 8)
    }

    func testItemWidthIsStableForNetworkMetricAcrossDifferentValues() {
        let slower = StatusSummaryItem(
            kind: .network,
            primaryText: "↑512B",
            secondaryText: "↓999B",
            style: .network
        )
        let faster = StatusSummaryItem(
            kind: .network,
            primaryText: "↑13.8K",
            secondaryText: "↓125.4M",
            style: .network
        )

        XCTAssertEqual(
            StatusBarSummaryLayout.itemWidth(for: slower),
            StatusBarSummaryLayout.itemWidth(for: faster)
        )
    }

    func testFanMetricGetsHalfDigitMoreWidthThanDefaultMetricColumn() {
        let fan = StatusSummaryItem(
            kind: .fan,
            primaryText: "9999",
            secondaryText: "RPM",
            style: .metric
        )
        let primaryWidth = ("9999" as NSString).size(
            withAttributes: [.font: StatusBarSummaryLayout.primaryFont(for: .metric)]
        ).width
        let secondaryWidth = ("RPM" as NSString).size(
            withAttributes: [.font: StatusBarSummaryLayout.secondaryFont(for: .metric)]
        ).width
        let baseFanWidth = ceil(
            max(StatusBarSummaryLayout.metricMinimumWidth, max(primaryWidth, secondaryWidth))
        )
        let halfDigitWidth = ceil(
            ("0" as NSString).size(
                withAttributes: [.font: StatusBarSummaryLayout.primaryFont(for: .metric)]
            ).width / 2
        )

        XCTAssertEqual(
            StatusBarSummaryLayout.itemWidth(for: fan),
            baseFanWidth + halfDigitWidth,
            accuracy: 0.5
        )
    }

    func testPreferredWidthIsStableForSameMetricSelectionAcrossDifferentValues() {
        let quieterItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .temperature, primaryText: "41℃", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑512B", secondaryText: "↓999B", style: .network),
        ]
        let busierItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "100%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .temperature, primaryText: "105℃", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓125.4M", style: .network),
        ]

        XCTAssertEqual(
            StatusBarSummaryLayout.preferredWidth(for: quieterItems),
            StatusBarSummaryLayout.preferredWidth(for: busierItems)
        )
    }

    func testImagePresentationWidthIsStableForSameMetricSelectionAcrossDifferentValues() {
        let quieterItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .temperature, primaryText: "41℃", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑512B", secondaryText: "↓999B", style: .network),
        ]
        let busierItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "100%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .temperature, primaryText: "105℃", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓125.4M", style: .network),
        ]

        XCTAssertEqual(
            StatusBarSummaryLayout.imagePresentation(summaryText: "quiet", items: quieterItems).length,
            StatusBarSummaryLayout.imagePresentation(summaryText: "busy", items: busierItems).length
        )
    }

}
