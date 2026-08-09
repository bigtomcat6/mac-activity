import XCTest
import MacActivityCore
@testable import MacActivityApp

final class DashboardTrendLocalizationTests: XCTestCase {
    func testFormattedTimeRangeUsesLocalizedEndpointsWithoutAverageLabel() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let end = start.addingTimeInterval(30)
        let expectedStart = AppLocalization.formattedTime(start, includesSeconds: true)
        let expectedEnd = AppLocalization.formattedTime(end, includesSeconds: true)

        let value = AppLocalization.formattedTimeRange(
            start...end,
            includesSeconds: true
        )

        XCTAssertEqual(value, "\(expectedStart)–\(expectedEnd)")
        XCTAssertFalse(value.localizedCaseInsensitiveContains("avg"))
        XCTAssertFalse(value.contains("平均"))
    }

    func testFormattedTimeRangeCollapsesMatchingEndpoints() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(
            AppLocalization.formattedTimeRange(date...date, includesSeconds: true),
            AppLocalization.formattedTime(date, includesSeconds: true)
        )
    }

    func testNetworkReadoutsUseDirectionalArrows() throws {
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))
        let sample = DashboardTrendSample(
            timestamp: Date(timeIntervalSince1970: 10),
            primaryValue: 2_000,
            secondaryValue: 500
        )

        XCTAssertEqual(
            AppLocalization.chartPrimaryReadout(for: .network, sample: sample, bundle: simplifiedChinese),
            "↑ 500 B/s"
        )
        XCTAssertEqual(
            AppLocalization.chartSecondaryReadout(for: .network, sample: sample, bundle: simplifiedChinese),
            "↓ 2 KB/s"
        )
    }

    func testNetworkReadoutsNormalizeZeroWordToDigits() throws {
        let english = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "en"))
        let sample = DashboardTrendSample(
            timestamp: Date(timeIntervalSince1970: 10),
            primaryValue: 0,
            secondaryValue: 0
        )

        XCTAssertEqual(
            AppLocalization.chartPrimaryReadout(for: .network, sample: sample, bundle: english),
            "↑ 0 KB/s"
        )
        XCTAssertEqual(
            AppLocalization.chartSecondaryReadout(for: .network, sample: sample, bundle: english),
            "↓ 0 KB/s"
        )
        XCTAssertEqual(
            AppLocalization.chartAxisLabel(for: .network, value: 0, bundle: english),
            "0 KB/s"
        )
    }
}
