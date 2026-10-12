import Foundation

public enum ReleaseVersionParseError: Error, Equatable {
    case invalid(String)
}

public struct ReleaseVersion: Equatable, Comparable, Sendable {
    public let rawValue: String
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let channel: UpdateChannel
    public let prereleaseNumber: Int

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = withoutPrefix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreFields = parts.first?.split(separator: ".", omittingEmptySubsequences: false) ?? []
        let coreParts = coreFields.compactMap(Self.parseNumber)

        guard coreFields.count == 3, coreParts.count == 3 else {
            throw ReleaseVersionParseError.invalid(rawValue)
        }

        self.rawValue = trimmed
        self.major = coreParts[0]
        self.minor = coreParts[1]
        self.patch = coreParts[2]

        guard parts.count == 2 else {
            self.channel = .release
            self.prereleaseNumber = 0
            return
        }

        let prereleaseParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard prereleaseParts.count == 2,
              let parsedChannel = UpdateChannel(rawValue: String(prereleaseParts[0])),
              parsedChannel != .release,
              let parsedNumber = Self.parseNumber(prereleaseParts[1]) else {
            throw ReleaseVersionParseError.invalid(rawValue)
        }

        self.channel = parsedChannel
        self.prereleaseNumber = parsedNumber
    }

    private static func parseNumber(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(value)
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.channel.rank != rhs.channel.rank { return lhs.channel.rank < rhs.channel.rank }
        return lhs.prereleaseNumber < rhs.prereleaseNumber
    }

    public func hasHigherBaseVersion(than other: ReleaseVersion) -> Bool {
        if major != other.major { return major > other.major }
        if minor != other.minor { return minor > other.minor }
        return patch > other.patch
    }

    public func hasSameBaseVersion(as other: ReleaseVersion) -> Bool {
        major == other.major && minor == other.minor && patch == other.patch
    }
}
