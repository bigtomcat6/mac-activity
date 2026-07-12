import Foundation

public struct AudioFeatureAvailability: Equatable, Sendable {
    public let operatingSystemVersion: OperatingSystemVersion

    public init(operatingSystemVersion: OperatingSystemVersion) {
        self.operatingSystemVersion = operatingSystemVersion
    }

    public static let current = AudioFeatureAvailability(
        operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersion
    )

    public var supportsProcessControls: Bool {
        operatingSystemVersion.majorVersion > 14
            || (operatingSystemVersion.majorVersion == 14
                && operatingSystemVersion.minorVersion >= 2)
    }

    public static func == (
        lhs: AudioFeatureAvailability,
        rhs: AudioFeatureAvailability
    ) -> Bool {
        lhs.operatingSystemVersion.majorVersion == rhs.operatingSystemVersion.majorVersion
            && lhs.operatingSystemVersion.minorVersion == rhs.operatingSystemVersion.minorVersion
            && lhs.operatingSystemVersion.patchVersion == rhs.operatingSystemVersion.patchVersion
    }
}
