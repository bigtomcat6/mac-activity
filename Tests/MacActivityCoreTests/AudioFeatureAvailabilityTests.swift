import XCTest
@testable import MacActivityCore

final class AudioFeatureAvailabilityTests: XCTestCase {
    func testProcessVolumeRequiresMacOS142() {
        XCTAssertFalse(
            AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 13,
                    minorVersion: 6,
                    patchVersion: 0
                )
            ).supportsProcessVolume
        )
        XCTAssertFalse(
            AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 1,
                    patchVersion: 0
                )
            ).supportsProcessVolume
        )
        XCTAssertTrue(
            AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 14,
                    minorVersion: 2,
                    patchVersion: 0
                )
            ).supportsProcessVolume
        )
        XCTAssertTrue(
            AudioFeatureAvailability(
                operatingSystemVersion: OperatingSystemVersion(
                    majorVersion: 15,
                    minorVersion: 0,
                    patchVersion: 0
                )
            ).supportsProcessVolume
        )
    }
}
