import Foundation

public struct AudioFeatureAvailability: Equatable, Sendable {
    public let operatingSystemVersion: OperatingSystemVersion
    private let nativeRoutingIsValidated: Bool

    public init(
        operatingSystemVersion: OperatingSystemVersion,
        nativeValidationPolicy: AudioRouteNativeValidationPolicy
    ) {
        self.operatingSystemVersion = operatingSystemVersion
        self.nativeRoutingIsValidated = nativeValidationPolicy.enablesProcessControls
    }

    public static let current = AudioFeatureAvailability(
        operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion,
        nativeValidationPolicy: .conservative
    )

    public var supportsProcessControls: Bool {
        nativeRoutingIsValidated && (
            operatingSystemVersion.majorVersion > 14
            || (operatingSystemVersion.majorVersion == 14
                && operatingSystemVersion.minorVersion >= 2)
        )
    }

    public static func == (
        lhs: AudioFeatureAvailability,
        rhs: AudioFeatureAvailability
    ) -> Bool {
        lhs.operatingSystemVersion.majorVersion == rhs.operatingSystemVersion.majorVersion
            && lhs.operatingSystemVersion.minorVersion == rhs.operatingSystemVersion.minorVersion
            && lhs.operatingSystemVersion.patchVersion == rhs.operatingSystemVersion.patchVersion
            && lhs.nativeRoutingIsValidated == rhs.nativeRoutingIsValidated
    }
}
