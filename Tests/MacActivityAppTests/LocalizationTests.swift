import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class LocalizationTests: XCTestCase {
    func testAvailableLanguagesComeFromBundledLprojFolders() throws {
        let languages = AppLocalization.availableLanguageIdentifiers()

        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.contains("zh-Hans"))
        XCTAssertFalse(languages.contains("Base"))
    }

    func testRegionalLanguageIdentifierFallsBackToBundledLocalization() throws {
        let bundle = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans-CN"))

        XCTAssertEqual(
            AppLocalization.string(.preferences, bundle: bundle),
            "偏好设置"
        )
    }

    func testAppLanguageOptionsIncludeSystemAndBundledLanguages() {
        let languages = AppLanguage.supportedLanguages()

        XCTAssertEqual(languages.first?.preferredLanguageIdentifier, nil)
        XCTAssertTrue(languages.contains { $0.preferredLanguageIdentifier == "en" })
        XCTAssertTrue(languages.contains { $0.preferredLanguageIdentifier == "zh-Hans" })
    }

    func testLanguagePickerUsesAutonymsForConcreteLanguages() throws {
        let english = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "en"))
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))

        XCTAssertEqual(AppLocalization.languageTitle(for: .system, bundle: english), "Follow System")
        XCTAssertEqual(AppLocalization.languageTitle(for: .system, bundle: simplifiedChinese), "跟随系统")
        XCTAssertEqual(
            AppLocalization.languageTitle(for: AppLanguage(preferredLanguageIdentifier: "en"), bundle: simplifiedChinese),
            "English"
        )
        XCTAssertEqual(
            AppLocalization.languageTitle(for: AppLanguage(preferredLanguageIdentifier: "zh-Hans"), bundle: english),
            "简体中文"
        )
    }

    func testEnglishAndSimplifiedChineseBundlesResolveCoreInterfaceStrings() throws {
        let english = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "en"))
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))

        XCTAssertEqual(AppLocalization.string(.preferences, bundle: english), "Preferences")
        XCTAssertEqual(AppLocalization.string(.preferences, bundle: simplifiedChinese), "偏好设置")

        XCTAssertEqual(AppLocalization.string(.preferencesCurrentVersion, bundle: english), "Current version")
        XCTAssertEqual(AppLocalization.string(.preferencesCurrentVersion, bundle: simplifiedChinese), "当前版本")
        XCTAssertEqual(AppLocalization.string(.preferencesCheckForUpdates, bundle: english), "Check for Updates")
        XCTAssertEqual(AppLocalization.string(.preferencesCheckForUpdates, bundle: simplifiedChinese), "检查更新")
        XCTAssertEqual(AppLocalization.string(.preferencesShowUpdateChannel, bundle: english), "Show update channel")
        XCTAssertEqual(AppLocalization.string(.preferencesShowUpdateChannel, bundle: simplifiedChinese), "显示更新频道")
        XCTAssertEqual(AppLocalization.string(.preferencesHideUpdateChannel, bundle: english), "Hide update channel")
        XCTAssertEqual(AppLocalization.string(.preferencesHideUpdateChannel, bundle: simplifiedChinese), "隐藏更新频道")

        XCTAssertEqual(AppLocalization.string(.live, bundle: english), "Live")
        XCTAssertEqual(AppLocalization.string(.live, bundle: simplifiedChinese), "实时")

        XCTAssertEqual(AppLocalization.metricTitle(for: .memory, bundle: english), "Memory")
        XCTAssertEqual(AppLocalization.metricTitle(for: .memory, bundle: simplifiedChinese), "内存")

        XCTAssertEqual(AppLocalization.temperatureSourceTitle(for: .battery, bundle: english), "Battery")
        XCTAssertEqual(AppLocalization.temperatureSourceTitle(for: .battery, bundle: simplifiedChinese), "电池")

        XCTAssertEqual(
            AppLocalization.string(.preferencesHardwareBatteryPercentage, bundle: english),
            "Show hardware battery percentage"
        )
        XCTAssertEqual(
            AppLocalization.string(.preferencesHardwareBatteryPercentage, bundle: simplifiedChinese),
            "显示硬件电池百分比"
        )
        XCTAssertEqual(
            AppLocalization.string(.preferencesHardwareBatteryPercentageHelp, bundle: english),
            "Uses raw AppleSmartBattery capacity when available; falls back to the system percentage."
        )
        XCTAssertEqual(
            AppLocalization.string(.preferencesHardwareBatteryPercentageHelp, bundle: simplifiedChinese),
            "可用时使用 AppleSmartBattery 的原始容量；不可用时回退为系统百分比。"
        )
        XCTAssertEqual(
            AppLocalization.string(.preferencesProcessApplicationIdentifier, bundle: english),
            "Show application ID in Actives process list"
        )
        XCTAssertEqual(
            AppLocalization.string(.preferencesProcessApplicationIdentifier, bundle: simplifiedChinese),
            "在“活跃”进程列表中显示应用 ID"
        )
        XCTAssertEqual(AppLocalization.string(.preferencesUpdateChannel, bundle: english), "Update channel")
        XCTAssertEqual(AppLocalization.string(.preferencesUpdateChannel, bundle: simplifiedChinese), "选择更新频道")
        XCTAssertEqual(AppLocalization.updateChannelTitle(for: .alpha, bundle: english), "Alpha")
        XCTAssertEqual(AppLocalization.updateChannelTitle(for: .beta, bundle: english), "Beta")
        XCTAssertEqual(AppLocalization.updateChannelTitle(for: .release, bundle: english), "Release")
        XCTAssertEqual(AppLocalization.updateChannelTitle(for: .alpha, bundle: simplifiedChinese), "Alpha")
        XCTAssertEqual(AppLocalization.updateChannelTitle(for: .beta, bundle: simplifiedChinese), "Beta")
        XCTAssertEqual(AppLocalization.updateChannelTitle(for: .release, bundle: simplifiedChinese), "Release")

        XCTAssertEqual(AppLocalization.string(.preferencesDiskCleanupScope, bundle: english), "Cleanup scope")
        XCTAssertEqual(AppLocalization.string(.preferencesDiskCleanupScope, bundle: simplifiedChinese), "清理范围")
        XCTAssertEqual(AppLocalization.diskCleanupCategoryTitle(for: .userCaches, bundle: english), "Caches")
        XCTAssertEqual(AppLocalization.diskCleanupCategoryTitle(for: .trash, bundle: english), "Trash")
        XCTAssertEqual(AppLocalization.diskCleanupCategoryTitle(for: .userLogs, bundle: english), "Logs")
        XCTAssertEqual(AppLocalization.diskCleanupCategoryTitle(for: .userCaches, bundle: simplifiedChinese), "缓存")
        XCTAssertEqual(AppLocalization.diskCleanupCategoryTitle(for: .trash, bundle: simplifiedChinese), "废纸篓")
        XCTAssertEqual(AppLocalization.diskCleanupCategoryTitle(for: .userLogs, bundle: simplifiedChinese), "日志")
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
                for: .cleanable(bytes: 4_096, itemCount: 2, categories: [.userCaches, .trash, .userLogs]),
                bundle: simplifiedChinese
            ),
            "可清理 \(cleanableBytes)"
        )
        XCTAssertEqual(
            DiskCleanupStatusView.subtitle(
                for: .cleanable(bytes: 4_096, itemCount: 2, categories: [.userCaches, .trash, .userLogs]),
                bundle: simplifiedChinese
            ),
            "已选择 2 个项目，来自缓存、废纸篓、日志。"
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

    func testPreferredLanguageSelectionOverridesDefaultBundle() {
        AppLocalization.setPreferredLanguageIdentifier("zh-Hans")
        XCTAssertEqual(AppLocalization.string(.preferences), "偏好设置")

        AppLocalization.setPreferredLanguageIdentifier("en")
        XCTAssertEqual(AppLocalization.string(.preferences), "Preferences")

        AppLocalization.setPreferredLanguageIdentifier(nil)
    }
}
