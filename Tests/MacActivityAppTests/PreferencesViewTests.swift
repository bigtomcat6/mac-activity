import XCTest
import MacActivityCore
@testable import MacActivityApp

@MainActor
final class PreferencesViewTests: XCTestCase {
    func testVersionInfoDisplayTextIncludesBuildWhenPresent() {
        let info = PreferencesVersionInfo(shortVersion: "26.0.0-alpha.2", build: "7")

        XCTAssertEqual(info.displayText, "26.0.0-alpha.2 (7)")
    }

    func testVersionInfoDisplayTextOmitsBlankBuild() {
        let info = PreferencesVersionInfo(shortVersion: "26.0.1", build: " ")

        XCTAssertEqual(info.displayText, "26.0.1")
    }

    func testCurrentVersionPrefersPrereleaseReleaseTag() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: bundleURL)
        }

        let infoPlist: NSDictionary = [
            "CFBundleExecutable": "Mac Activity",
            "CFBundleIdentifier": "com.how.macactivity.test",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Mac Activity",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "26.0.0",
            "CFBundleVersion": "2",
            "MacActivityReleaseTag": "v26.0.0-alpha.2",
        ]
        XCTAssertTrue(infoPlist.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true))

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let info = PreferencesVersionInfo.current(bundle: bundle)

        XCTAssertEqual(info.displayText, "v26.0.0-alpha.2")
    }

    func testCurrentVersionKeepsBuildWhenReleaseTagMatchesShortVersion() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "26.0.0",
            "CFBundleVersion": "4",
            "MacActivityReleaseTag": "v26.0.0",
        ])

        let info = PreferencesVersionInfo.current(bundle: bundle)

        XCTAssertEqual(info.displayText, "26.0.0 (4)")
    }

    func testCurrentVersionIgnoresPlaceholderReleaseTag() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "26.0.0",
            "CFBundleVersion": "5",
            "MacActivityReleaseTag": "$(MACACTIVITY_RELEASE_TAG)",
        ])

        let info = PreferencesVersionInfo.current(bundle: bundle)

        XCTAssertEqual(info.displayText, "26.0.0 (5)")
    }

    func testPreferencesViewBuildsUpdateHeader() {
        let controller = PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
        let view = PreferencesView(
            preferencesController: controller,
            versionInfo: PreferencesVersionInfo(shortVersion: "26.0.0", build: "5"),
            checkForUpdates: {}
        )

        XCTAssertFalse(String(describing: type(of: view.body)).isEmpty)
    }

    private func makeBundle(info: [String: String]) throws -> Bundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoPlist = NSMutableDictionary(dictionary: [
            "CFBundleExecutable": "Mac Activity",
            "CFBundleIdentifier": "com.how.macactivity.test",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Mac Activity",
            "CFBundlePackageType": "APPL",
        ])
        infoPlist.addEntries(from: info)
        XCTAssertTrue(infoPlist.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true))
        return try XCTUnwrap(Bundle(url: bundleURL))
    }
}

private final class InMemoryPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private var value: AppPreferences

    init(initial: AppPreferences) {
        self.value = initial
    }

    func load() -> AppPreferences {
        value
    }

    func save(_ preferences: AppPreferences) throws {
        value = preferences
    }
}
