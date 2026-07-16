import XCTest
@testable import MacActivityCore

final class AudioFeatureAvailabilityTests: XCTestCase {
    func testProductionProcessControlsRequireMacOS142AndValidatedTopologyPolicy() {
        let matrix: [(OperatingSystemVersion, Bool)] = [
            (.init(majorVersion: 13, minorVersion: 0, patchVersion: 0), false),
            (.init(majorVersion: 14, minorVersion: 0, patchVersion: 0), false),
            (.init(majorVersion: 14, minorVersion: 1, patchVersion: 0), false),
            (.init(majorVersion: 14, minorVersion: 2, patchVersion: 0), false),
            (.init(majorVersion: 15, minorVersion: 0, patchVersion: 0), false),
        ]

        for (version, expected) in matrix {
            XCTAssertEqual(
                AudioFeatureAvailability(
                    operatingSystemVersion: version,
                    nativeValidationPolicy: .conservative
                ).supportsProcessControls,
                expected,
                "Unexpected capability for \(version)"
            )
        }
    }

    func testValidatedTestPolicyEnablesProcessControlsOnlyOnMacOS142OrLater() {
        let policy = AudioRouteNativeValidationPolicy(
            validatedFingerprints: [.testFixture]
        )

        XCTAssertFalse(AudioFeatureAvailability(
            operatingSystemVersion: .init(majorVersion: 14, minorVersion: 1, patchVersion: 0),
            nativeValidationPolicy: policy
        ).supportsProcessControls)
        XCTAssertTrue(AudioFeatureAvailability(
            operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0),
            nativeValidationPolicy: policy
        ).supportsProcessControls)
    }

    func testPolicyReportsWhetherProductionHasValidatedFingerprints() {
        XCTAssertFalse(AudioRouteNativeValidationPolicy.conservative.hasValidatedFingerprints)
        XCTAssertTrue(AudioRouteNativeValidationPolicy(
            validatedFingerprints: [.testFixture]
        ).hasValidatedFingerprints)
    }

    func testEqualityIncludesOperatingSystemVersionAndValidationPolicy() {
        let validatedPolicy = AudioRouteNativeValidationPolicy(
            validatedFingerprints: [.testFixture]
        )

        XCTAssertEqual(
            AudioFeatureAvailability(
                operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0),
                nativeValidationPolicy: validatedPolicy
            ),
            AudioFeatureAvailability(
                operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0),
                nativeValidationPolicy: validatedPolicy
            )
        )
        XCTAssertNotEqual(
            AudioFeatureAvailability(
                operatingSystemVersion: .init(majorVersion: 14, minorVersion: 2, patchVersion: 0),
                nativeValidationPolicy: validatedPolicy
            ),
            AudioFeatureAvailability(
                operatingSystemVersion: .init(majorVersion: 14, minorVersion: 1, patchVersion: 0),
                nativeValidationPolicy: validatedPolicy
            )
        )
    }
}

private extension AudioRouteTopologyFingerprint {
    static let testFixture = AudioRouteTopologyFingerprint(
        osBuild: "test",
        sourceDeviceUIDs: ["source"],
        selectedTargetUIDs: ["target"],
        devices: []
    )
}
