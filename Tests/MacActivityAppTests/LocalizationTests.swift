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

    func testUnsupportedLanguageIdentifierDoesNotFallBackToEnglish() {
        XCTAssertNil(AppLocalization.bundle(forLanguageIdentifier: "fr"))
        XCTAssertNil(AppLocalization.bundle(forLanguageIdentifier: "zh-Hant"))
        XCTAssertNil(AppLanguage(preferredLanguageIdentifier: "fr").preferredLanguageIdentifier)
        XCTAssertNil(AppLanguage(preferredLanguageIdentifier: "zh-Hant").preferredLanguageIdentifier)
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

    func testEveryLocalizationKeyExistsInEveryBundledLocalization() throws {
        let keys = Set(AppLocalization.Key.allCases.map(\.rawValue))

        for language in AppLocalization.availableLanguageIdentifiers() {
            let bundle = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: language))
            for key in keys {
                XCTAssertNotEqual(
                    bundle.localizedString(forKey: key, value: nil, table: nil),
                    key,
                    "Missing \(key) in \(language)"
                )
            }
        }
    }

    func testInfoPlistLocalizationKeysMatchEnglish() throws {
        let expectedKeys = Set(["CFBundleDisplayName", "CFBundleName", "NSHumanReadableCopyright"])
        let english = try infoPlistStrings(forLanguageIdentifier: "en")
        let englishKeys = Set(english.keys).intersection(expectedKeys)

        XCTAssertTrue(expectedKeys.isSuperset(of: englishKeys))
        XCTAssertTrue(englishKeys.contains("CFBundleDisplayName"))
        XCTAssertTrue(englishKeys.contains("NSHumanReadableCopyright"))

        for language in AppLocalization.availableLanguageIdentifiers() where language != "en" {
            let localized = try infoPlistStrings(forLanguageIdentifier: language)
            XCTAssertEqual(
                Set(localized.keys).intersection(expectedKeys),
                englishKeys,
                "InfoPlist.strings keys for \(language) must match English"
            )
        }
    }

    func testDashboardMetricTitlesAndDetailsLocalizeFromSemanticRoles() throws {
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))
        let disk = DashboardMetric(kind: .disk, titleRole: .metric(.disk), value: "75%")
        let battery = DashboardMetric(
            kind: .battery,
            titleRole: .metric(.battery),
            value: "82%",
            detailRole: .batteryCharging
        )

        XCTAssertEqual(AppLocalization.dashboardMetricTitle(for: disk, bundle: simplifiedChinese), "磁盘")
        XCTAssertEqual(AppLocalization.dashboardMetricTitle(for: battery, bundle: simplifiedChinese), "电池")
        XCTAssertEqual(AppLocalization.dashboardMetricDetail(for: battery, bundle: simplifiedChinese), "正在充电")
    }

    func testMemorySegmentTooltipLocalizesSegmentTitles() throws {
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))

        XCTAssertEqual(
            AppLocalization.memorySegmentTitle(for: .compressed, bundle: simplifiedChinese),
            "压缩"
        )
        XCTAssertEqual(
            AppLocalization.memorySegmentTooltip(
                title: "压缩",
                memory: "2.0GB",
                percent: "20%",
                bundle: simplifiedChinese
            ),
            "压缩：2.0GB（20%）"
        )
    }

    func testStorageAccessibilityLocalizesMetricTitles() throws {
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))
        let disk = DashboardMetric(
            kind: .disk,
            titleRole: .metric(.disk),
            value: "75%",
            detailRole: .raw("750 B (75%)")
        )
        let swap = DashboardMetric(
            kind: .swap,
            titleRole: .metric(.swap),
            value: "25%",
            detailRole: .raw("256 B")
        )

        XCTAssertEqual(
            AppLocalization.storageAccessibilityValue(for: [disk, swap], bundle: simplifiedChinese),
            "磁盘 750 B (75%)，交换 256 B"
        )
    }

    func testChartReadoutsUseLocalizedUnits() throws {
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))
        let sample = DashboardTrendSample(timestamp: Date(), primaryValue: 31.2, secondaryValue: 20.4)

        XCTAssertEqual(AppLocalization.chartAxisLabel(for: .temperature, value: 31.2, bundle: simplifiedChinese), "31.2℃")
        XCTAssertEqual(AppLocalization.chartPrimaryReadout(for: .temperature, sample: sample, bundle: simplifiedChinese), "31.2℃")
        XCTAssertEqual(AppLocalization.chartPrimaryReadout(for: .network, sample: sample, bundle: simplifiedChinese), "↑ 20 B/s")
        XCTAssertEqual(AppLocalization.chartSecondaryReadout(for: .network, sample: sample, bundle: simplifiedChinese), "↓ 31 B/s")
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
        XCTAssertEqual(AppLocalization.updateChannelTitle(for: .alpha, bundle: simplifiedChinese), "Alpha 版")
        XCTAssertEqual(AppLocalization.updateChannelTitle(for: .beta, bundle: simplifiedChinese), "Beta 版")
        XCTAssertEqual(AppLocalization.updateChannelTitle(for: .release, bundle: simplifiedChinese), "正式版")

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
            MemoryReleaseStatusView.subtitle(for: .failed(.exitCode(7)), bundle: simplifiedChinese),
            "内存释放失败，退出代码 7。"
        )
        XCTAssertEqual(
            TrashCleanupStatusView.subtitle(for: .cleanable(bytes: 4_096, itemCount: 2), bundle: simplifiedChinese),
            "确认后可移除 2 个项目。"
        )
        XCTAssertEqual(
            TrashCleanupStatusView.subtitle(for: .failed(.unableToDeleteItems), bundle: simplifiedChinese),
            "无法删除废纸篓项目。"
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
            DiskCleanupStatusView.subtitle(for: .failed(.unableToDeleteItems), bundle: simplifiedChinese),
            "无法删除已选择的磁盘清理项目。"
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
        defer { AppLocalization.setPreferredLanguageIdentifier(nil) }

        AppLocalization.setPreferredLanguageIdentifier("zh-Hans")
        XCTAssertEqual(AppLocalization.string(.preferences), "偏好设置")
        XCTAssertEqual(
            DiskCleanupStatusView.subtitle(
                for: .cleanable(bytes: 4_096, itemCount: 3, categories: [.userCaches, .trash, .userLogs])
            ),
            "已选择 3 个项目，来自缓存、废纸篓、日志。"
        )

        AppLocalization.setPreferredLanguageIdentifier("en")
        XCTAssertEqual(AppLocalization.string(.preferences), "Preferences")
    }

    func testProductionUIStringsUseLocalizationResources() throws {
        let packageRoot = Self.packageRootURL()
        let sourceRoots = [
            packageRoot.appendingPathComponent("Sources/MacActivityApp"),
            packageRoot.appendingPathComponent("Sources/MacActivityCore"),
        ]
        var violations: [String] = []

        for fileURL in try sourceRoots.flatMap(Self.swiftSourceFiles) {
            let relativePath = Self.relativePath(for: fileURL, from: packageRoot)
            let contents = try String(contentsOf: fileURL, encoding: .utf8)

            for (lineOffset, line) in contents.components(separatedBy: .newlines).enumerated() {
                guard Self.shouldScanProductionStringLine(line) else { continue }

                for pattern in Self.hardcodedProductionStringPatterns {
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    for match in pattern.regex.matches(in: line, range: range) {
                        guard match.numberOfRanges > 1,
                              let literalRange = Range(match.range(at: 1), in: line) else {
                            continue
                        }

                        let literal = String(line[literalRange])
                        guard literal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                            continue
                        }

                        violations.append(
                            "\(relativePath):\(lineOffset + 1): \(pattern.name) uses \"\(literal)\""
                        )
                    }
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Hard-coded production UI strings must use AppLocalization keys:\n\(violations.joined(separator: "\n"))"
        )
    }

    private func infoPlistStrings(forLanguageIdentifier language: String) throws -> [String: String] {
        let bundle = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: language))
        let path = try XCTUnwrap(bundle.path(forResource: "InfoPlist", ofType: "strings"))
        let dictionary = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
        return dictionary
    }

    private static let hardcodedProductionStringPatterns: [(name: String, regex: NSRegularExpression)] = [
        ("Text literal", try! NSRegularExpression(pattern: #"\bText\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Button literal", try! NSRegularExpression(pattern: #"\bButton\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Label literal", try! NSRegularExpression(pattern: #"\bLabel\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Toggle literal", try! NSRegularExpression(pattern: #"\bToggle\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Picker literal", try! NSRegularExpression(pattern: #"\bPicker\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Menu literal", try! NSRegularExpression(pattern: #"\bMenu\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Section literal", try! NSRegularExpression(pattern: #"\bSection\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("TextField literal", try! NSRegularExpression(pattern: #"\bTextField\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("SecureField literal", try! NSRegularExpression(pattern: #"\bSecureField\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("ProgressView literal", try! NSRegularExpression(pattern: #"\bProgressView\s*\(\s*"((?:\\"|[^"])*)""#)),
        (
            "accessibility label literal",
            try! NSRegularExpression(pattern: #"\.accessibilityLabel\s*\(\s*Text\s*\(\s*"((?:\\"|[^"])*)""#)
        ),
        (
            "accessibility value literal",
            try! NSRegularExpression(pattern: #"\.accessibilityValue\s*\(\s*Text\s*\(\s*"((?:\\"|[^"])*)""#)
        ),
        ("help literal", try! NSRegularExpression(pattern: #"\.help\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("navigation title literal", try! NSRegularExpression(pattern: #"\.navigationTitle\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("alert literal", try! NSRegularExpression(pattern: #"\.alert\s*\(\s*"((?:\\"|[^"])*)""#)),
        (
            "confirmation dialog literal",
            try! NSRegularExpression(pattern: #"\.confirmationDialog\s*\(\s*"((?:\\"|[^"])*)""#)
        ),
        ("tooltip literal", try! NSRegularExpression(pattern: #"\.toolTip\s*=\s*"((?:\\"|[^"])*)""#)),
        ("title literal", try! NSRegularExpression(pattern: #"\.title\s*=\s*"((?:\\"|[^"])*)""#)),
        ("failed literal", try! NSRegularExpression(pattern: #"\.failed\s*\(\s*"((?:\\"|[^"])*)""#)),
    ]

    private static func shouldScanProductionStringLine(_ line: String) -> Bool {
        let allowedFragments = [
            "CFBundle",
            "MacActivityReleaseTag",
            "SUPublicEDKey",
            "SUFeedURL",
            "fatalError",
            "systemName:",
        ]

        return allowedFragments.contains { line.contains($0) } == false
    }

    private static func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftSourceFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            files.append(fileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(for fileURL: URL, from rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path + "/"
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return filePath }
        return String(filePath.dropFirst(rootPath.count))
    }
}
