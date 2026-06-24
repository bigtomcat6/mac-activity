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
}
