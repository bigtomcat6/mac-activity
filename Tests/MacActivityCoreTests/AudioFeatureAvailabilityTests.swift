import XCTest
@testable import MacActivityCore

final class AudioFeatureAvailabilityTests: XCTestCase {
    func testProcessControlsRequireMacOS142OrLater() {
        let matrix: [(OperatingSystemVersion, Bool)] = [
            (.init(majorVersion: 13, minorVersion: 0, patchVersion: 0), false),
            (.init(majorVersion: 14, minorVersion: 0, patchVersion: 0), false),
            (.init(majorVersion: 14, minorVersion: 1, patchVersion: 9), false),
            (.init(majorVersion: 14, minorVersion: 2, patchVersion: 0), true),
            (.init(majorVersion: 15, minorVersion: 0, patchVersion: 0), true),
            (.init(majorVersion: 26, minorVersion: 0, patchVersion: 0), true),
        ]

        for (version, expected) in matrix {
            XCTAssertEqual(
                AudioFeatureAvailability(
                    operatingSystemVersion: version
                ).supportsProcessControls,
                expected,
                "Unexpected capability for \(version)"
            )
        }
    }

    func testAvailabilityEqualityUsesTheOperatingSystemVersion() {
        let version = OperatingSystemVersion(
            majorVersion: 14,
            minorVersion: 2,
            patchVersion: 0
        )
        XCTAssertEqual(
            AudioFeatureAvailability(operatingSystemVersion: version),
            AudioFeatureAvailability(operatingSystemVersion: version)
        )
        XCTAssertNotEqual(
            AudioFeatureAvailability(operatingSystemVersion: version),
            AudioFeatureAvailability(
                operatingSystemVersion: .init(
                    majorVersion: 14,
                    minorVersion: 1,
                    patchVersion: 9
                )
            )
        )
    }
}
