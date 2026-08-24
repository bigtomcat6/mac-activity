import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class LocalizationTests: XCTestCase {
    func testAvailableLanguagesComeFromBundledLprojFolders() throws {
        let languages = AppLocalization.availableLanguageIdentifiers()

        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.contains("zh-Hans"))
        XCTAssertTrue(languages.contains("zh-Hant"))
        XCTAssertTrue(languages.contains("ja"))
        XCTAssertTrue(languages.contains("ko"))
        XCTAssertTrue(languages.contains("de"))
        XCTAssertTrue(languages.contains("fr"))
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
        XCTAssertNil(AppLocalization.bundle(forLanguageIdentifier: "es"))
        XCTAssertNil(AppLocalization.bundle(forLanguageIdentifier: "ru-RU"))
        XCTAssertNil(AppLanguage(preferredLanguageIdentifier: "es").preferredLanguageIdentifier)
        XCTAssertNil(AppLanguage(preferredLanguageIdentifier: "ru-RU").preferredLanguageIdentifier)
    }

    func testAppLanguageOptionsIncludeSystemAndBundledLanguages() {
        let languages = AppLanguage.supportedLanguages()

        XCTAssertEqual(languages.first?.preferredLanguageIdentifier, nil)
        XCTAssertTrue(languages.contains { $0.preferredLanguageIdentifier == "en" })
        XCTAssertTrue(languages.contains { $0.preferredLanguageIdentifier == "zh-Hans" })
        XCTAssertTrue(languages.contains { $0.preferredLanguageIdentifier == "zh-Hant" })
        XCTAssertTrue(languages.contains { $0.preferredLanguageIdentifier == "ja" })
        XCTAssertTrue(languages.contains { $0.preferredLanguageIdentifier == "ko" })
        XCTAssertTrue(languages.contains { $0.preferredLanguageIdentifier == "de" })
        XCTAssertTrue(languages.contains { $0.preferredLanguageIdentifier == "fr" })
    }

    func testAudioDashboardStringsExistForAllSupportedLanguages() throws {
        let audioKeys: [AppLocalization.Key] = [
            .dashboardTabAudio,
            .audioDevicesTitle,
            .audioProcessesTitle,
            .audioUnsupportedDeviceVolume,
            .audioProcessOwnedByAnotherInstance,
            .audioProcessRuntimeUnavailable,
        ]

        for language in AppLanguage.supportedLanguages() {
            guard let languageIdentifier = language.preferredLanguageIdentifier else {
                continue
            }

            let bundle = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: languageIdentifier))
            for key in audioKeys {
                let localized = AppLocalization.string(key, bundle: bundle)
                XCTAssertNotEqual(localized, key.rawValue, "Missing \(key.rawValue) in \(languageIdentifier)")
                XCTAssertFalse(localized.isEmpty, "\(key.rawValue) in \(languageIdentifier) must not be empty")
            }
        }
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
                let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(
                    localized,
                    key,
                    "Missing \(key) in \(language)"
                )
                XCTAssertFalse(
                    localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(key) in \(language) must not be empty"
                )
            }
        }
    }

    func testLocalizedFormatPlaceholdersMatchEnglish() throws {
        let english = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "en"))

        for language in AppLocalization.availableLanguageIdentifiers() where language != "en" {
            let localized = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: language))
            for key in AppLocalization.Key.allCases {
                let keyValue = key.rawValue
                XCTAssertEqual(
                    Self.formatPlaceholders(in: localized.localizedString(forKey: keyValue, value: nil, table: nil)),
                    Self.formatPlaceholders(in: english.localizedString(forKey: keyValue, value: nil, table: nil)),
                    "Format placeholders for \(keyValue) in \(language) must match English"
                )
            }
        }
    }

    func testGermanAudioCapturePermissionUsesCaptureTerminology() throws {
        let german = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "de"))
        let permissionCopy = AppLocalization.string(.audioProcessPermissionDenied, bundle: german)

        XCTAssertEqual(
            permissionCopy,
            "Die Berechtigung zur Audioerfassung ist erforderlich. Erlaube Mac Activity in den Systemeinstellungen und versuche es erneut."
        )
        XCTAssertFalse(permissionCopy.contains("Audioaufnahme"))
    }

    func testInfoPlistLocalizationKeysMatchRequiredSet() throws {
        let requiredKeys = Set([
            "CFBundleDisplayName",
            "NSHumanReadableCopyright",
            "NSAudioCaptureUsageDescription",
        ])
        let english = try infoPlistStrings(forLanguageIdentifier: "en")
        XCTAssertEqual(Set(english.keys), requiredKeys)

        for language in AppLocalization.availableLanguageIdentifiers() where language != "en" {
            let localized = try infoPlistStrings(forLanguageIdentifier: language)
            XCTAssertEqual(
                Set(localized.keys),
                requiredKeys,
                "InfoPlist.strings keys for \(language) must match the required localized keys"
            )
        }
    }

    func testAudioUsageDescriptionMatchesAccurateCopyInEveryLanguage() throws {
        let expectedDescriptions = [
            "en": "Mac Activity captures and reroutes an app’s outgoing audio to apply per-app volume and play it through your selected output devices.",
            "de": "Mac Activity erfasst und leitet die Audioausgabe einer App um, um die Lautstärke pro App anzuwenden und sie über die ausgewählten Ausgabegeräte wiederzugeben.",
            "fr": "Mac Activity capture et réachemine l’audio sortant d’une app afin d’appliquer son volume individuel et de le lire sur les appareils de sortie sélectionnés.",
            "ja": "Mac Activityは、アプリごとの音量を適用し、選択した出力デバイスで再生するために、アプリの出力音声をキャプチャして再ルーティングします。",
            "ko": "Mac Activity는 앱별 음량을 적용하고 선택한 출력 기기에서 재생하기 위해 앱의 출력 오디오를 캡처하고 다시 라우팅합니다.",
            "zh-Hans": "Mac Activity 会捕获并重新路由应用的输出音频，以应用单独的应用音量并通过您选择的输出设备播放。",
            "zh-Hant": "Mac Activity 會擷取並重新路由 App 的輸出音訊，以套用個別 App 音量並透過您選擇的輸出裝置播放。",
        ]

        XCTAssertEqual(Set(expectedDescriptions.keys), Set(AppLocalization.availableLanguageIdentifiers()))

        for (language, expectedDescription) in expectedDescriptions {
            let values = try infoPlistStrings(forLanguageIdentifier: language)
            let description = try XCTUnwrap(values["NSAudioCaptureUsageDescription"])
            XCTAssertEqual(description, expectedDescription, language)
            XCTAssertFalse(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, language)
            XCTAssertTrue(description.contains("Mac Activity"), language)
        }
    }

    func testAudioUsageDescriptionFallbackMatchesEnglishCopy() throws {
        let plistURL = Self.packageRootURL().appendingPathComponent("Configuration/MacActivity-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let values = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            values["NSAudioCaptureUsageDescription"] as? String,
            "Mac Activity captures and reroutes an app’s outgoing audio to apply per-app volume and play it through your selected output devices."
        )
    }

    func testGeneratedXcodeProjectIncludesBundledLocalizations() throws {
        let project = try String(
            contentsOf: Self.packageRootURL().appendingPathComponent("MacActivity.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )

        for language in AppLocalization.availableLanguageIdentifiers() {
            XCTAssertTrue(
                project.contains("path = \(quotedProjectValue("\(language).lproj/Localizable.strings"));"),
                language
            )
            XCTAssertTrue(
                project.contains("path = \(quotedProjectValue("\(language).lproj/InfoPlist.strings"));"),
                language
            )
            XCTAssertTrue(project.contains("\n\t\t\t\t\(quotedProjectValue(language)),"))
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
        let batteryConnectedToPower = DashboardMetric(
            kind: .battery,
            titleRole: .metric(.battery),
            value: "82%",
            detailRole: .batteryConnectedToPower
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
        XCTAssertEqual(AppLocalization.dashboardMetricDetail(for: batteryConnectedToPower, bundle: simplifiedChinese), "接入电源")
        XCTAssertEqual(AppLocalization.dashboardMetricDetail(for: batteryOnBattery, bundle: simplifiedChinese), "使用电池")
    }

    func testLegacyBatteryDetailStringsLocalizeConnectedPowerState() throws {
        let simplifiedChinese = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: "zh-Hans"))

        XCTAssertEqual(
            AppLocalization.metricDetail("Connected to Power", bundle: simplifiedChinese),
            "接入电源"
        )
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
            detailRole: .raw("256 B (25%)"),
            usedBytes: 256
        )

        XCTAssertEqual(
            AppLocalization.storageAccessibilityValue(for: [disk, swap], bundle: simplifiedChinese),
            "磁盘 750 B (75%)，交换 256 B"
        )
    }

    func testEnergyImpactPageStringsAreLocalized() throws {
        let expectations: [String: [AppLocalization.Key: String]] = [
            "en": [
                .energyImpactTitle: "Energy Impact",
                .energyImpactSubtitleSustained: "Up to 30 sec CPU energy estimate · Lower is better",
                .energyImpactAppColumn: "App",
                .energyImpactSustainedColumn: "30 sec",
                .energyImpactCoverage: "%1$lld of %2$lld processes readable",
                .energyImpactCheckedNow: "Checked just now",
                .energyImpactInfo: "Energy estimate details",
                .energyImpactExplanation: "Estimate based on CPU energy attributed to readable app processes. Protected or short-lived helpers may be omitted.",
                .energyImpactTrendRising: "rising",
                .energyImpactTrendSteady: "steady",
                .energyImpactTrendFalling: "falling",
                .energyImpactRowAccessibilitySustained: "%1$@, rank %2$lld, up to 30 seconds %3$@, %4$@",
                .energyImpactCollecting: "Collecting",
                .energyImpactPartial: "Partial",
                .energyImpactStale: "Stale",
                .energyImpactEmpty: "No regular apps are reporting an energy estimate.",
                .energyImpactUnavailable: "Unavailable",
                .powerFlowInput: "Input",
                .powerFlowOutput: "Output",
                .powerFlowEmpty: "No active endpoints",
                .powerFlowUnavailable: "Power unavailable",
                .powerFlowEndpointBattery: "Battery",
                .powerFlowEndpointMac: "Mac",
                .powerFlowEndpointUnknownExternal: "Unknown external interface",
                .powerFlowRowAccessibility: "%1$@, %2$@, %3$@",
                .preferencesProcessApplicationIdentifier: "Show application ID in process lists"
            ],
            "de": [
                .energyImpactTitle: "Energieeinfluss",
                .energyImpactSubtitleSustained: "CPU-Energieschätzung für bis zu 30 Sek. · Niedriger ist besser",
                .energyImpactAppColumn: "App",
                .energyImpactSustainedColumn: "30 Sek.",
                .energyImpactCoverage: "%1$lld von %2$lld Prozessen lesbar",
                .energyImpactCheckedNow: "Gerade geprüft",
                .energyImpactInfo: "Details zur Energieschätzung",
                .energyImpactExplanation: "Schätzung auf Basis der CPU-Energie lesbarer App-Prozesse. Geschützte oder kurzlebige Hilfsprozesse können fehlen.",
                .energyImpactTrendRising: "steigend",
                .energyImpactTrendSteady: "stabil",
                .energyImpactTrendFalling: "fallend",
                .energyImpactRowAccessibilitySustained: "%1$@, Rang %2$lld, bis zu 30 Sekunden %3$@, %4$@",
                .energyImpactCollecting: "Wird erfasst",
                .energyImpactPartial: "Teilweise",
                .energyImpactStale: "Veraltet",
                .energyImpactEmpty: "Keine regulären Apps melden eine Energieschätzung.",
                .energyImpactUnavailable: "Nicht verfügbar",
                .powerFlowInput: "Eingang",
                .powerFlowOutput: "Ausgang",
                .powerFlowEmpty: "Keine aktiven Endpunkte",
                .powerFlowUnavailable: "Leistung nicht verfügbar",
                .powerFlowEndpointBattery: "Akku",
                .powerFlowEndpointMac: "Mac",
                .powerFlowEndpointUnknownExternal: "Unbekannte externe Schnittstelle",
                .powerFlowRowAccessibility: "%1$@, %2$@, %3$@",
                .preferencesProcessApplicationIdentifier: "App-ID in Prozesslisten anzeigen"
            ],
            "fr": [
                .energyImpactTitle: "Impact énergétique",
                .energyImpactSubtitleSustained: "Estimation d’énergie CPU sur 30 s max. · Plus bas est préférable",
                .energyImpactAppColumn: "App",
                .energyImpactSustainedColumn: "30 s",
                .energyImpactCoverage: "%1$lld processus lisibles sur %2$lld",
                .energyImpactCheckedNow: "Vérifié à l’instant",
                .energyImpactInfo: "Détails de l’estimation énergétique",
                .energyImpactExplanation: "Estimation fondée sur l’énergie CPU attribuée aux processus lisibles. Les processus protégés ou très courts peuvent manquer.",
                .energyImpactTrendRising: "en hausse",
                .energyImpactTrendSteady: "stable",
                .energyImpactTrendFalling: "en baisse",
                .energyImpactRowAccessibilitySustained: "%1$@, rang %2$lld, jusqu’à 30 secondes %3$@, %4$@",
                .energyImpactCollecting: "Collecte",
                .energyImpactPartial: "Partiel",
                .energyImpactStale: "Obsolète",
                .energyImpactEmpty: "Aucune app standard ne fournit d’estimation énergétique.",
                .energyImpactUnavailable: "Indisponible",
                .powerFlowInput: "Entrée",
                .powerFlowOutput: "Sortie",
                .powerFlowEmpty: "Aucun point de terminaison actif",
                .powerFlowUnavailable: "Puissance indisponible",
                .powerFlowEndpointBattery: "Batterie",
                .powerFlowEndpointMac: "Mac",
                .powerFlowEndpointUnknownExternal: "Interface externe inconnue",
                .powerFlowRowAccessibility: "%1$@, %2$@, %3$@",
                .preferencesProcessApplicationIdentifier: "Afficher l’identifiant d’app dans les listes de processus"
            ],
            "ja": [
                .energyImpactTitle: "エネルギー影響",
                .energyImpactSubtitleSustained: "最大30秒のCPUエネルギー推定 · 低いほど良好",
                .energyImpactAppColumn: "アプリ",
                .energyImpactSustainedColumn: "30秒",
                .energyImpactCoverage: "%2$lld件中%1$lld件のプロセスを読み取り可能",
                .energyImpactCheckedNow: "たった今確認",
                .energyImpactInfo: "エネルギー推定の説明",
                .energyImpactExplanation: "読み取り可能なアプリプロセスに割り当てられたCPUエネルギーに基づく推定です。保護された、または短時間のヘルパーは含まれない場合があります。",
                .energyImpactTrendRising: "上昇",
                .energyImpactTrendSteady: "安定",
                .energyImpactTrendFalling: "下降",
                .energyImpactRowAccessibilitySustained: "%1$@、%2$lld位、最大30秒 %3$@、%4$@",
                .energyImpactCollecting: "収集中",
                .energyImpactPartial: "一部データ",
                .energyImpactStale: "古いデータ",
                .energyImpactEmpty: "エネルギー推定を報告している通常のアプリはありません。",
                .energyImpactUnavailable: "利用不可",
                .powerFlowInput: "入力",
                .powerFlowOutput: "出力",
                .powerFlowEmpty: "アクティブな端点はありません",
                .powerFlowUnavailable: "電力を取得できません",
                .powerFlowEndpointBattery: "バッテリー",
                .powerFlowEndpointMac: "Mac",
                .powerFlowEndpointUnknownExternal: "不明な外部インターフェース",
                .powerFlowRowAccessibility: "%1$@、%2$@、%3$@",
                .preferencesProcessApplicationIdentifier: "プロセスリストにアプリIDを表示"
            ],
            "ko": [
                .energyImpactTitle: "에너지 영향",
                .energyImpactSubtitleSustained: "최대 30초 CPU 에너지 추정치 · 낮을수록 좋음",
                .energyImpactAppColumn: "앱",
                .energyImpactSustainedColumn: "30초",
                .energyImpactCoverage: "프로세스 %2$lld개 중 %1$lld개 읽기 가능",
                .energyImpactCheckedNow: "방금 확인함",
                .energyImpactInfo: "에너지 추정치 설명",
                .energyImpactExplanation: "읽을 수 있는 앱 프로세스에 귀속된 CPU 에너지를 기반으로 한 추정치입니다. 보호되거나 수명이 짧은 도우미는 누락될 수 있습니다.",
                .energyImpactTrendRising: "상승",
                .energyImpactTrendSteady: "안정",
                .energyImpactTrendFalling: "하락",
                .energyImpactRowAccessibilitySustained: "%1$@, %2$lld위, 최대 30초 %3$@, %4$@",
                .energyImpactCollecting: "수집 중",
                .energyImpactPartial: "일부 데이터",
                .energyImpactStale: "오래된 데이터",
                .energyImpactEmpty: "에너지 추정치를 보고하는 일반 앱이 없습니다.",
                .energyImpactUnavailable: "사용할 수 없음",
                .powerFlowInput: "입력",
                .powerFlowOutput: "출력",
                .powerFlowEmpty: "활성 엔드포인트 없음",
                .powerFlowUnavailable: "전력 정보를 사용할 수 없음",
                .powerFlowEndpointBattery: "배터리",
                .powerFlowEndpointMac: "Mac",
                .powerFlowEndpointUnknownExternal: "알 수 없는 외부 인터페이스",
                .powerFlowRowAccessibility: "%1$@, %2$@, %3$@",
                .preferencesProcessApplicationIdentifier: "프로세스 목록에 앱 ID 표시"
            ],
            "zh-Hans": [
                .energyImpactTitle: "耗电影响",
                .energyImpactSubtitleSustained: "最近最多 30 秒 CPU 能耗估算 · 越低越好",
                .energyImpactAppColumn: "应用",
                .energyImpactSustainedColumn: "30 秒",
                .energyImpactCoverage: "可读取 %1$lld / %2$lld 个进程",
                .energyImpactCheckedNow: "刚刚检查",
                .energyImpactInfo: "估算说明",
                .energyImpactExplanation: "基于可读取应用进程所归属的 CPU 能耗进行估算；受保护或生命周期很短的辅助进程可能不会被计入。",
                .energyImpactTrendRising: "上升",
                .energyImpactTrendSteady: "稳定",
                .energyImpactTrendFalling: "下降",
                .energyImpactRowAccessibilitySustained: "%1$@，第 %2$lld 名，最近最多 30 秒 %3$@，%4$@",
                .energyImpactCollecting: "采集中",
                .energyImpactPartial: "部分数据",
                .energyImpactStale: "数据已过期",
                .energyImpactEmpty: "当前没有普通应用报告能耗估算。",
                .energyImpactUnavailable: "不可读取",
                .powerFlowInput: "输入端",
                .powerFlowOutput: "输出端",
                .powerFlowEmpty: "没有活动端点",
                .powerFlowUnavailable: "功率不可用",
                .powerFlowEndpointBattery: "电池",
                .powerFlowEndpointMac: "Mac",
                .powerFlowEndpointUnknownExternal: "未知外接接口",
                .powerFlowRowAccessibility: "%1$@，%2$@，%3$@",
                .preferencesProcessApplicationIdentifier: "在进程列表中显示应用 ID"
            ],
            "zh-Hant": [
                .energyImpactTitle: "耗電影響",
                .energyImpactSubtitleSustained: "最近最多 30 秒 CPU 能耗估算 · 越低越好",
                .energyImpactAppColumn: "應用程式",
                .energyImpactSustainedColumn: "30 秒",
                .energyImpactCoverage: "可讀取 %1$lld / %2$lld 個程序",
                .energyImpactCheckedNow: "剛剛檢查",
                .energyImpactInfo: "估算說明",
                .energyImpactExplanation: "基於可讀取應用程式程序所歸屬的 CPU 能耗進行估算；受保護或生命週期很短的輔助程序可能不會被計入。",
                .energyImpactTrendRising: "上升",
                .energyImpactTrendSteady: "穩定",
                .energyImpactTrendFalling: "下降",
                .energyImpactRowAccessibilitySustained: "%1$@，第 %2$lld 名，最近最多 30 秒 %3$@，%4$@",
                .energyImpactCollecting: "收集中",
                .energyImpactPartial: "部分資料",
                .energyImpactStale: "資料已過期",
                .energyImpactEmpty: "目前沒有一般應用程式回報能耗估算。",
                .energyImpactUnavailable: "無法讀取",
                .powerFlowInput: "輸入端",
                .powerFlowOutput: "輸出端",
                .powerFlowEmpty: "沒有活動端點",
                .powerFlowUnavailable: "功率無法取得",
                .powerFlowEndpointBattery: "電池",
                .powerFlowEndpointMac: "Mac",
                .powerFlowEndpointUnknownExternal: "未知外接介面",
                .powerFlowRowAccessibility: "%1$@、%2$@、%3$@",
                .preferencesProcessApplicationIdentifier: "在程序列表中顯示應用程式 ID"
            ],
        ]

        XCTAssertEqual(Set(expectations.keys), Set(AppLocalization.availableLanguageIdentifiers()))

        for (identifier, expectedStrings) in expectations {
            let bundle = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: identifier))
            for (key, expected) in expectedStrings {
                XCTAssertEqual(AppLocalization.string(key, bundle: bundle), expected, "\(key.rawValue) in \(identifier)")
            }
        }

        let part7AExpectations: [String: [AppLocalization.Key: String]] = [
            "en": [
                .preferencesEnergyImpactAppScope: "Energy app scope",
                .energyImpactScopeRegularOnly: "Regular apps",
                .energyImpactScopeRegularAndAccessory: "Regular and menu-bar apps",
                .energyImpactKindAccessory: "Menu Bar",
                .energyImpactEmptyExpanded: "No regular or menu-bar apps are reporting an energy estimate.",
            ],
            "de": [
                .preferencesEnergyImpactAppScope: "Umfang der Energie-Apps",
                .energyImpactScopeRegularOnly: "Reguläre Apps",
                .energyImpactScopeRegularAndAccessory: "Reguläre und Menüleisten-Apps",
                .energyImpactKindAccessory: "Menüleiste",
                .energyImpactEmptyExpanded: "Keine regulären oder Menüleisten-Apps melden eine Energieschätzung.",
            ],
            "fr": [
                .preferencesEnergyImpactAppScope: "Étendue des apps d’énergie",
                .energyImpactScopeRegularOnly: "Apps standard",
                .energyImpactScopeRegularAndAccessory: "Apps standard et de barre des menus",
                .energyImpactKindAccessory: "Barre des menus",
                .energyImpactEmptyExpanded: "Aucune app standard ou de barre des menus ne fournit d’estimation énergétique.",
            ],
            "ja": [
                .preferencesEnergyImpactAppScope: "エネルギー対象アプリ",
                .energyImpactScopeRegularOnly: "通常のアプリ",
                .energyImpactScopeRegularAndAccessory: "通常のアプリとメニューバーアプリ",
                .energyImpactKindAccessory: "メニューバー",
                .energyImpactEmptyExpanded: "エネルギー推定を報告している通常またはメニューバーアプリはありません。",
            ],
            "ko": [
                .preferencesEnergyImpactAppScope: "에너지 앱 범위",
                .energyImpactScopeRegularOnly: "일반 앱",
                .energyImpactScopeRegularAndAccessory: "일반 앱 및 메뉴 막대 앱",
                .energyImpactKindAccessory: "메뉴 막대",
                .energyImpactEmptyExpanded: "에너지 추정치를 보고하는 일반 또는 메뉴 막대 앱이 없습니다.",
            ],
            "zh-Hans": [
                .preferencesEnergyImpactAppScope: "能耗应用范围",
                .energyImpactScopeRegularOnly: "普通应用",
                .energyImpactScopeRegularAndAccessory: "普通应用与菜单栏应用",
                .energyImpactKindAccessory: "菜单栏",
                .energyImpactEmptyExpanded: "当前没有普通应用或菜单栏应用报告能耗估算。",
            ],
            "zh-Hant": [
                .preferencesEnergyImpactAppScope: "能耗應用程式範圍",
                .energyImpactScopeRegularOnly: "一般應用程式",
                .energyImpactScopeRegularAndAccessory: "一般應用程式與選單列應用程式",
                .energyImpactKindAccessory: "選單列",
                .energyImpactEmptyExpanded: "目前沒有一般應用程式或選單列應用程式回報能耗估算。",
            ],
        ]

        XCTAssertEqual(Set(part7AExpectations.keys), Set(AppLocalization.availableLanguageIdentifiers()))
        for (identifier, expectedStrings) in part7AExpectations {
            let bundle = try XCTUnwrap(AppLocalization.bundle(forLanguageIdentifier: identifier))
            for (key, expected) in expectedStrings {
                XCTAssertEqual(AppLocalization.string(key, bundle: bundle), expected, "\(key.rawValue) in \(identifier)")
            }
            XCTAssertEqual(
                AppLocalization.energyImpactScopeTitle(for: .regularOnly, bundle: bundle),
                try XCTUnwrap(expectedStrings[.energyImpactScopeRegularOnly])
            )
            XCTAssertEqual(
                AppLocalization.energyImpactScopeTitle(for: .regularAndAccessory, bundle: bundle),
                try XCTUnwrap(expectedStrings[.energyImpactScopeRegularAndAccessory])
            )
        }
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
            "Show application ID in process lists"
        )
        XCTAssertEqual(
            AppLocalization.string(.preferencesProcessApplicationIdentifier, bundle: simplifiedChinese),
            "在进程列表中显示应用 ID"
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

    private func quotedProjectValue(_ value: String) -> String {
        value.contains("-") ? "\"\(value)\"" : value
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

    private static func formatPlaceholders(in string: String) -> [String] {
        let pattern = "%(?:\\d+\\$)?(?:\\.\\d+)?[d@f]"
        let regex = regex(pattern)
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.matches(in: string, range: range).map { match in
            String(string[Range(match.range, in: string)!])
        }
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
