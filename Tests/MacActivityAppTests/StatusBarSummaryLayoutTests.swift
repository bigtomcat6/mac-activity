import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class StatusBarSummaryLayoutTests: XCTestCase {
    func testPreferredWidthUsesDeterministicColumnsAndSeparators() {
        let items = [
            StatusSummaryItem(kind: .cpu, primaryText: "7%", secondaryText: "CPU", style: .metric),
            StatusSummaryItem(kind: .memory, primaryText: "38%", secondaryText: "MEM", style: .metric),
            StatusSummaryItem(kind: .network, primaryText: "↑13.8 K/s", secondaryText: "↓15.4 K/s", style: .network),
        ]

        XCTAssertGreaterThanOrEqual(StatusBarSummaryLayout.preferredWidth(for: items), 114)
        XCTAssertEqual(StatusBarSummaryLayout.preferredWidth(for: []), 0)
    }
}
