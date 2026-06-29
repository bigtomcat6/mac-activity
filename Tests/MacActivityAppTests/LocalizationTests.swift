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

    func testPreferredLanguageStringLookupsStayCheap() {
        defer { AppLocalization.setPreferredLanguageIdentifier(nil) }
        AppLocalization.setPreferredLanguageIdentifier("zh-Hans")
        _ = AppLocalization.string(.preferences)

        let start = Date()
        for _ in 0..<10_000 {
            _ = AppLocalization.string(.preferences)
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
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
        let batteryOnBattery = DashboardMetric(
            kind: .battery,
            titleRole: .metric(.battery),
            value: "82%",
            detailRole: .batteryOnBattery
        )
        let cpuTemperature = DashboardMetric(
            kind: .temperature,
            titleRole: .temperature(.smc),
            value: "31.2 C"
        )
        let batteryTemperature = DashboardMetric(
            kind: .temperature,
            titleRole: .temperature(.battery),
            value: "31.2 C"
        )

        XCTAssertEqual(AppLocalization.dashboardMetricTitle(for: disk, bundle: simplifiedChinese), "磁盘")
        XCTAssertEqual(AppLocalization.dashboardMetricTitle(for: battery, bundle: simplifiedChinese), "电池")
        XCTAssertEqual(AppLocalization.dashboardMetricTitle(for: cpuTemperature, bundle: simplifiedChinese), "CPU 温度")
        XCTAssertEqual(AppLocalization.dashboardMetricTitle(for: batteryTemperature, bundle: simplifiedChinese), "电池温度")
        XCTAssertEqual(AppLocalization.dashboardMetricDetail(for: battery, bundle: simplifiedChinese), "正在充电")
        XCTAssertEqual(AppLocalization.dashboardMetricDetail(for: batteryOnBattery, bundle: simplifiedChinese), "使用电池")
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

        XCTAssertEqual(AppLocalization.chartAxisLabel(for: .cpu, value: 31.2, bundle: simplifiedChinese), "31%")
        XCTAssertEqual(AppLocalization.chartAxisLabel(for: .temperature, value: 31.2, bundle: simplifiedChinese), "31.2℃")
        XCTAssertEqual(AppLocalization.chartAxisLabel(for: .fan, value: 1_800, bundle: simplifiedChinese), "1,800 RPM")
        XCTAssertEqual(AppLocalization.chartPrimaryReadout(for: .temperature, sample: sample, bundle: simplifiedChinese), "31.2℃")
        XCTAssertEqual(AppLocalization.chartPrimaryReadout(for: .fan, sample: sample, bundle: simplifiedChinese), "31 RPM")
        XCTAssertEqual(AppLocalization.chartPrimaryReadout(for: .cpu, sample: sample, bundle: simplifiedChinese), "31%")
        XCTAssertEqual(AppLocalization.chartPrimaryReadout(for: .network, sample: sample, bundle: simplifiedChinese), "↑ 20 B/s")
        XCTAssertNil(AppLocalization.chartSecondaryReadout(for: .cpu, sample: sample, bundle: simplifiedChinese))
        XCTAssertEqual(AppLocalization.chartSecondaryReadout(for: .network, sample: sample, bundle: simplifiedChinese), "↓ 31 B/s")
    }

    func testLanguageIdentifierMatchingAndDisplayNamesCoverFallbacks() throws {
        let bundle = try makeLocalizationBundle(localizations: ["fr", "Base", "en", "de"])

        XCTAssertEqual(AppLocalization.availableLanguageIdentifiers(in: bundle), ["en", "de", "fr"])
        XCTAssertNil(AppLocalization.availableLanguageIdentifier(matching: ""))
        XCTAssertEqual(AppLocalization.availableLanguageIdentifier(matching: "EN_us"), "en")
        XCTAssertEqual(AppLocalization.availableLanguageIdentifier(matching: "zh_Hans_CN"), "zh-Hans")
        XCTAssertEqual(AppLocalization.availableLanguageIdentifier(matching: "fr-CA", in: bundle), "fr")
        XCTAssertNil(AppLocalization.bundle(forLanguageIdentifier: ""))
        XCTAssertEqual(AppLocalization.displayName(forLanguageIdentifier: "zz-Zzzz"), "zz-Zzzz")
        XCTAssertNotNil(AppLocalization.currentLanguageIdentifier())
    }

    func testHardcodedProductionStringScannerReportsRepresentativeLiterals() {
        let contents = [
            #"Label("Status", systemImage: "bolt")"#,
            #"ProgressView("Loading")"#,
            #".accessibilityLabel(Text("Usage"))"#,
            #"Text("")"#,
            #"Text("CFBundleName")"#
        ].joined(separator: "\n")
        let violations = Self.hardcodedProductionStringViolations(
            in: contents,
            relativePath: "Sources/MacActivityApp/Sample.swift"
        )

        XCTAssertEqual(
            violations,
            [
                #"Sources/MacActivityApp/Sample.swift:1: Label literal uses "Status""#,
                #"Sources/MacActivityApp/Sample.swift:2: ProgressView literal uses "Loading""#,
                #"Sources/MacActivityApp/Sample.swift:3: Text literal uses "Usage""#,
                #"Sources/MacActivityApp/Sample.swift:3: accessibility label literal uses "Usage""#
            ]
        )

        for allowedFragment in [
            "CFBundle",
            "MacActivityReleaseTag",
            "SUPublicEDKey",
            "SUFeedURL",
            "fatalError",
            "systemName:"
        ] {
            XCTAssertFalse(Self.shouldScanProductionStringLine("Text(\"\(allowedFragment)\")"))
        }
    }

    func testHardcodedProductionStringPatternsExposeExpectedCaptures() throws {
        let samples = [
            ("Label literal", #"Label("Status", systemImage: "bolt")"#, "Status"),
            ("ProgressView literal", #"ProgressView("Loading")"#, "Loading"),
            ("accessibility label literal", #".accessibilityLabel(Text("Usage"))"#, "Usage")
        ]

        for (patternName, line, literal) in samples {
            let pattern = Self.hardcodedProductionStringPatterns.first { $0.name == patternName }
            let regex = try XCTUnwrap(pattern?.regex)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let match = try XCTUnwrap(regex.firstMatch(in: line, range: range))
            let literalRange = try XCTUnwrap(Range(match.range(at: 1), in: line))
            XCTAssertEqual(String(line[literalRange]), literal)
        }
    }

    func testSwiftSourceFileDiscoveryReturnsEmptyForMissingDirectory() throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        XCTAssertEqual(try Self.swiftSourceFiles(in: missingDirectory), [])
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
            packageRoot.appendingPathComponent("Sources/MacActivityCore")
        ]
        let violations = try sourceRoots
            .flatMap(Self.swiftSourceFiles)
            .flatMap { fileURL in
                Self.hardcodedProductionStringViolations(
                    in: try String(contentsOf: fileURL, encoding: .utf8),
                    relativePath: Self.relativePath(for: fileURL, from: packageRoot)
                )
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

    private func makeLocalizationBundle(localizations: [String]) throws -> Bundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        for localization in localizations {
            try FileManager.default.createDirectory(
                at: bundleURL.appendingPathComponent("\(localization).lproj"),
                withIntermediateDirectories: true
            )
        }

        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private static let hardcodedProductionStringPatterns: [(name: String, regex: NSRegularExpression)] = [
        ("Text literal", regex(#"\bText\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Button literal", regex(#"\bButton\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Label literal", regex(#"\bLabel\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Toggle literal", regex(#"\bToggle\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Picker literal", regex(#"\bPicker\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Menu literal", regex(#"\bMenu\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("Section literal", regex(#"\bSection\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("TextField literal", regex(#"\bTextField\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("SecureField literal", regex(#"\bSecureField\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("ProgressView literal", regex(#"\bProgressView\s*\(\s*"((?:\\"|[^"])*)""#)),
        (
            "accessibility label literal",
            regex(#"\.accessibilityLabel\s*\(\s*Text\s*\(\s*"((?:\\"|[^"])*)""#)
        ),
        (
            "accessibility value literal",
            regex(#"\.accessibilityValue\s*\(\s*Text\s*\(\s*"((?:\\"|[^"])*)""#)
        ),
        ("help literal", regex(#"\.help\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("navigation title literal", regex(#"\.navigationTitle\s*\(\s*"((?:\\"|[^"])*)""#)),
        ("alert literal", regex(#"\.alert\s*\(\s*"((?:\\"|[^"])*)""#)),
        (
            "confirmation dialog literal",
            regex(#"\.confirmationDialog\s*\(\s*"((?:\\"|[^"])*)""#)
        ),
        ("tooltip literal", regex(#"\.toolTip\s*=\s*"((?:\\"|[^"])*)""#)),
        ("title literal", regex(#"\.title\s*=\s*"((?:\\"|[^"])*)""#)),
        ("failed literal", regex(#"\.failed\s*\(\s*"((?:\\"|[^"])*)""#))
    ]

    private static func regex(_ pattern: String) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern))!
    }

    private static func shouldScanProductionStringLine(_ line: String) -> Bool {
        let allowedFragments = [
            "CFBundle",
            "MacActivityReleaseTag",
            "SUPublicEDKey",
            "SUFeedURL",
            "fatalError",
            "systemName:"
        ]

        return allowedFragments.contains { line.contains($0) } == false
    }

    private static func hardcodedProductionStringViolations(in contents: String, relativePath: String) -> [String] {
        var violations: [String] = []

        for (lineOffset, line) in contents.components(separatedBy: .newlines).enumerated() {
            guard shouldScanProductionStringLine(line) else { continue }

            for pattern in hardcodedProductionStringPatterns {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                for match in pattern.regex.matches(in: line, range: range) {
                    let literalRange = Range(match.range(at: 1), in: line)!
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

        return violations
    }

    private static func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftSourceFiles(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))

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
