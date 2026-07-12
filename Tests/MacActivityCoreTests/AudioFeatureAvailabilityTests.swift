import XCTest
@testable import MacActivityCore

final class AudioFeatureAvailabilityTests: XCTestCase {
    func testProcessControlsRequireMacOS142() {
        let matrix: [(OperatingSystemVersion, Bool)] = [
            (.init(majorVersion: 13, minorVersion: 6, patchVersion: 0), false),
            (.init(majorVersion: 14, minorVersion: 0, patchVersion: 0), false),
            (.init(majorVersion: 14, minorVersion: 1, patchVersion: 0), false),
            (.init(majorVersion: 14, minorVersion: 2, patchVersion: 0), true),
            (.init(majorVersion: 15, minorVersion: 0, patchVersion: 0), true),
        ]

        for (version, expected) in matrix {
            XCTAssertEqual(
                AudioFeatureAvailability(operatingSystemVersion: version).supportsProcessControls,
                expected,
                "Unexpected capability for \(version)"
            )
        }
    }
}
