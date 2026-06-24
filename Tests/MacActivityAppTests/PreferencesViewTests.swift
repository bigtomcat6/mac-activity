import XCTest
@testable import MacActivityApp

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
}
