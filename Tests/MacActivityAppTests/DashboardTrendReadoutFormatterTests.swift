import XCTest
import MacActivityCore
@testable import MacActivityApp

final class DashboardTrendReadoutFormatterTests: XCTestCase {
    func testNetworkReadoutsUseArrowLabels() {
        let sample = DashboardTrendSample(
            timestamp: Date(timeIntervalSince1970: 10),
            primaryValue: 2_000,
            secondaryValue: 500
        )

        XCTAssertEqual(
            DashboardTrendReadoutFormatter.primaryReadout(for: .network, sample: sample),
            "↑ 500 B/s"
        )
        XCTAssertEqual(
            DashboardTrendReadoutFormatter.secondaryReadout(for: .network, sample: sample),
            "↓ 2 KB/s"
        )
    }

    func testNetworkReadoutsNormalizeZeroWordToDigits() {
        let sample = DashboardTrendSample(
            timestamp: Date(timeIntervalSince1970: 10),
            primaryValue: 0,
            secondaryValue: 0
        )

        XCTAssertEqual(
            DashboardTrendReadoutFormatter.primaryReadout(for: .network, sample: sample),
            "↑ 0 KB/s"
        )
        XCTAssertEqual(
            DashboardTrendReadoutFormatter.secondaryReadout(for: .network, sample: sample),
            "↓ 0 KB/s"
        )
        XCTAssertEqual(
            DashboardTrendReadoutFormatter.axisLabel(for: .network, value: 0),
            "0 KB/s"
        )
    }
}
