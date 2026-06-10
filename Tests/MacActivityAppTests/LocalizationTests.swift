import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class LocalizationTests: XCTestCase {
    func testEnglishAndSimplifiedChineseBundlesResolveCoreInterfaceStrings() throws {
        let english = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "en"))
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))

        XCTAssertEqual(AppLocalization.string(.preferences, bundle: english), "Preferences")
        XCTAssertEqual(AppLocalization.string(.preferences, bundle: simplifiedChinese), "偏好设置")

        XCTAssertEqual(AppLocalization.string(.live, bundle: english), "Live")
        XCTAssertEqual(AppLocalization.string(.live, bundle: simplifiedChinese), "实时")

        XCTAssertEqual(AppLocalization.metricTitle(for: .memory, bundle: english), "Memory")
        XCTAssertEqual(AppLocalization.metricTitle(for: .memory, bundle: simplifiedChinese), "内存")

        XCTAssertEqual(AppLocalization.temperatureSourceTitle(for: .battery, bundle: english), "Battery")
        XCTAssertEqual(AppLocalization.temperatureSourceTitle(for: .battery, bundle: simplifiedChinese), "电池")
    }

    func testCleanReleaseStringsResolveWithArguments() throws {
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))
        let remainingBytes = TrashCleanupStatusView.byteFormatter.string(fromByteCount: 2_048)
        let releasableBytes = MemoryReleaseStatusView.byteFormatter.string(fromByteCount: 2_097_152)
        let cleanableBytes = DiskCleanupStatusView.byteFormatter.string(fromByteCount: 4_096)

        XCTAssertEqual(
            MemoryReleaseStatusView.title(
                for: .usage(percent: 44.4, releasableBytes: 2_097_152),
                bundle: simplifiedChinese
            ),
            "可释放 \(releasableBytes)"
        )
        XCTAssertEqual(
            MemoryReleaseStatusView.subtitle(
                for: .usage(percent: 44.4, releasableBytes: 2_097_152),
                bundle: simplifiedChinese
            ),
            "内存 44%"
        )
        XCTAssertEqual(
            MemoryReleaseStatusView.subtitle(for: .released(bytes: 65_536, percentOfTotal: 2.5), bundle: simplifiedChinese),
            "占总内存的 2.5%"
        )
        XCTAssertEqual(
            MemoryReleaseStatusView.subtitle(for: .noSignificantRelease(observedBytes: 0), bundle: simplifiedChinese),
            "没有发现可立即释放的内存。"
        )
        XCTAssertEqual(
            MemoryReleaseStatusView.subtitle(for: .cooldown(remainingSeconds: 7.5), bundle: simplifiedChinese),
            "7.5 秒后再试。"
        )
        XCTAssertEqual(
            TrashCleanupStatusView.subtitle(for: .cleanable(bytes: 4_096, itemCount: 2), bundle: simplifiedChinese),
            "确认后可移除 2 个项目。"
        )
        XCTAssertEqual(
            TrashCleanupStatusView.subtitle(
                for: .partial(bytes: 12_288, deletedCount: 3, failedCount: 1, remainingBytes: 2_048),
                bundle: simplifiedChinese
            ),
            "已移除 3 个项目；1 个项目无法删除。仍剩余 \(remainingBytes)。"
        )
        XCTAssertEqual(
            DiskCleanupStatusView.title(
                for: .cleanable(bytes: 4_096, itemCount: 2, categoryCount: 1),
                bundle: simplifiedChinese
            ),
            "可清理 \(cleanableBytes)"
        )
        XCTAssertEqual(
            DiskCleanupStatusView.subtitle(
                for: .cleanable(bytes: 4_096, itemCount: 2, categoryCount: 1),
                bundle: simplifiedChinese
            ),
            "已选择 2 个项目，来自 1 个分类。"
        )
        XCTAssertEqual(
            DiskCleanupStatusView.subtitle(
                for: .partial(bytes: 12_288, deletedCount: 3, failedCount: 1, remainingBytes: 2_048),
                bundle: simplifiedChinese
            ),
            "已移除 3 个项目；1 个项目无法删除。仍剩余 \(remainingBytes)。"
        )
    }

    func testProcessAndDashboardStringsResolveWithArguments() throws {
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))

        XCTAssertEqual(
            ActiveProcessMemoryList.processActionMessage(for: .requested("Safari"), bundle: simplifiedChinese),
            "已请求 Safari 退出。"
        )
        XCTAssertEqual(
            ActiveProcessMemoryRow.quitButtonConfiguration(for: .confirming, bundle: simplifiedChinese),
            ActiveProcessQuitButtonConfiguration(title: "确认", isDestructive: true)
        )
        XCTAssertEqual(
            AppLocalization.memoryChartAccessibilityLabel(
                pressurePercent: 72,
                usedMemory: "8.0GB",
                totalMemory: "16.0GB",
                bundle: simplifiedChinese
            ),
            "内存 72%，已用 8.0GB，共 16.0GB"
        )
    }
}
