import XCTest
import MacActivityCore
@testable import MacActivityApp

final class DashboardTrendLocalizationTests: XCTestCase {
    func testNetworkReadoutsUseLocalizedUploadDownloadLabels() throws {
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))
        let sample = DashboardTrendSample(
            timestamp: Date(timeIntervalSince1970: 10),
            primaryValue: 2_000,
            secondaryValue: 500
        )

        XCTAssertEqual(
            AppLocalization.chartPrimaryReadout(for: .network, sample: sample, bundle: simplifiedChinese),
            "上传 500 B/s"
        )
        XCTAssertEqual(
            AppLocalization.chartSecondaryReadout(for: .network, sample: sample, bundle: simplifiedChinese),
            "下载 2 KB/s"
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
            "Upload 0 KB/s"
        )
        XCTAssertEqual(
            AppLocalization.chartSecondaryReadout(for: .network, sample: sample, bundle: english),
            "Download 0 KB/s"
        )
        XCTAssertEqual(
            AppLocalization.chartAxisLabel(for: .network, value: 0, bundle: english),
            "0 KB/s"
        )
    }
}
