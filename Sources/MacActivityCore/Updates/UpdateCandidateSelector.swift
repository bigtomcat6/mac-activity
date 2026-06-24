import Foundation

public struct UpdateCandidate: Equatable, Sendable {
    public let version: ReleaseVersion
    public let build: Int

    public init(version: String, build: String) throws {
        self.version = try ReleaseVersion(version)
        self.build = Int(build) ?? 0
    }
}

public enum UpdateCandidateSelector {
    public static func bestCandidate(
        currentVersion: ReleaseVersion,
        selectedChannel: UpdateChannel,
        candidates: [UpdateCandidate]
    ) -> UpdateCandidate? {
        candidates
            .filter { selectedChannel.visibleChannels.contains($0.version.channel) }
            .filter { isEligible($0.version, currentVersion: currentVersion) }
            .sorted(by: isPreferred)
            .first
    }

    private static func isEligible(_ candidate: ReleaseVersion, currentVersion: ReleaseVersion) -> Bool {
        if candidate.hasHigherBaseVersion(than: currentVersion) {
            return true
        }

        guard candidate.hasSameBaseVersion(as: currentVersion) else {
            return false
        }

        if candidate.channel.rank != currentVersion.channel.rank {
            return candidate.channel.rank > currentVersion.channel.rank
        }

        return candidate.prereleaseNumber > currentVersion.prereleaseNumber
    }

    private static func isPreferred(_ lhs: UpdateCandidate, _ rhs: UpdateCandidate) -> Bool {
        if lhs.version.channel.rank != rhs.version.channel.rank {
            return lhs.version.channel.rank > rhs.version.channel.rank
        }

        if lhs.version != rhs.version {
            return lhs.version > rhs.version
        }

        return lhs.build > rhs.build
    }
}
