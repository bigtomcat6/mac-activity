import AppKit
import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class StatusBarSummaryLayoutTests: XCTestCase {
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
            StatusSummaryItem(kind: .temperature, primaryText: "41℃", secondaryText: "SEN", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑512B", secondaryText: "↓999B", style: .network),
        ]
        let busierItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "100%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .temperature, primaryText: "105℃", secondaryText: "SEN", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓125.4M", style: .network),
        ]

        XCTAssertEqual(
            StatusBarSummaryLayout.preferredWidth(for: quieterItems),
            StatusBarSummaryLayout.preferredWidth(for: busierItems)
        )
    }

    func testSummaryViewReusesExistingMetricViewsAcrossValueUpdates() {
        let view = StatusBarSummaryView(frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        let initialItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "38%", secondaryText: "MEM", style: .metric),
        ]
        let updatedItems = [
            StatusSummaryItem(kind: .cpu, primaryText: "18%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "41%", secondaryText: "MEM", style: .metric),
        ]

        view.update(summaryText: "", items: initialItems)

        let stackView = try! XCTUnwrap(view.subviews.first as? NSStackView)
        let firstMetricView = stackView.arrangedSubviews[0]
        let secondMetricView = stackView.arrangedSubviews[2]

        view.update(summaryText: "", items: updatedItems)

        XCTAssertTrue(firstMetricView === stackView.arrangedSubviews[0])
        XCTAssertTrue(secondMetricView === stackView.arrangedSubviews[2])
    }

    func testNetworkSummaryViewUsesTwoLineVerticalLayoutWithUnifiedFonts() {
        let view = StatusBarSummaryView(frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        let items = [
            StatusSummaryItem(kind: .network, primaryText: "↑13.8K", secondaryText: "↓15.4K", style: .network),
        ]

        view.update(summaryText: "", items: items)

        let stackView = try! XCTUnwrap(view.subviews.first as? NSStackView)
        let itemView = try! XCTUnwrap(stackView.arrangedSubviews.first as? NSStackView)
        let primaryLabel = try! XCTUnwrap(itemView.arrangedSubviews.first as? NSTextField)
        let secondaryLabel = try! XCTUnwrap(itemView.arrangedSubviews.last as? NSTextField)

        XCTAssertEqual(itemView.orientation, .vertical)
        XCTAssertEqual(primaryLabel.font?.pointSize, secondaryLabel.font?.pointSize)
        XCTAssertEqual(primaryLabel.stringValue, "↑13.8K")
        XCTAssertEqual(secondaryLabel.stringValue, "↓15.4K")
    }
}
