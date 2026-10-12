import XCTest
@testable import MacActivityCore

final class UpdateCandidateSelectorTests: XCTestCase {
    func testReleaseCandidateWinsOverHigherPrereleaseForAlphaChannel() throws {
        let current = try ReleaseVersion("v26.0.0-alpha.2")
        let candidates = [
            try UpdateCandidate(version: "v26.0.1", build: "20"),
            try UpdateCandidate(version: "v26.1.0-alpha.3", build: "30"),
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "40")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .alpha,
            candidates: candidates
        )

        XCTAssertEqual(selected?.version.rawValue, "v26.0.1")
    }

    func testReleaseCandidateWinsOverHigherPrereleaseForBetaChannel() throws {
        let current = try ReleaseVersion("v26.0.0-alpha.2")
        let candidates = [
            try UpdateCandidate(version: "v26.0.1", build: "20"),
            try UpdateCandidate(version: "v26.1.0-alpha.3", build: "30"),
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "40")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .beta,
            candidates: candidates
        )

        XCTAssertEqual(selected?.version.rawValue, "v26.0.1")
    }

    func testBetaChannelDoesNotSeeAlphaOnlyCandidates() throws {
        let current = try ReleaseVersion("v26.0.0")
        let candidates = [
            try UpdateCandidate(version: "v26.1.0-alpha.3", build: "30")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .beta,
            candidates: candidates
        )

        XCTAssertNil(selected)
    }

    func testReleaseChannelOnlySeesReleaseCandidates() throws {
        let current = try ReleaseVersion("v26.0.0")
        let candidates = [
            try UpdateCandidate(version: "v26.0.1", build: "20"),
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "40")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .release,
            candidates: candidates
        )

        XCTAssertEqual(selected?.version.rawValue, "v26.0.1")
    }

    func testBetaChannelCanMoveFromStableToNewerBetaWhenNoReleaseCandidateExists() throws {
        let current = try ReleaseVersion("v26.0.1")
        let candidates = [
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "40")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .beta,
            candidates: candidates
        )

        XCTAssertEqual(selected?.version.rawValue, "v26.1.0-beta.1")
    }

    func testLowerBaseReleaseDoesNotDowngradeInstalledBeta() throws {
        let current = try ReleaseVersion("v26.1.0-beta.1")
        let candidates = [
            try UpdateCandidate(version: "v26.0.1", build: "50")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .beta,
            candidates: candidates
        )

        XCTAssertNil(selected)
    }

    func testSameChannelPrereleaseNumberCanAdvance() throws {
        let current = try ReleaseVersion("v26.1.0-alpha.2")
        let candidates = [
            try UpdateCandidate(version: "v26.1.0-alpha.3", build: "31")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .alpha,
            candidates: candidates
        )

        XCTAssertEqual(selected?.version.rawValue, "v26.1.0-alpha.3")
    }

    func testHigherChannelCanAdvanceWithinSameBaseVersion() throws {
        let current = try ReleaseVersion("v26.1.0-alpha.2")
        let candidates = [
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "41")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .beta,
            candidates: candidates
        )

        XCTAssertEqual(selected?.version.rawValue, "v26.1.0-beta.1")
    }

    func testHigherSameChannelVersionWinsBeforeBuildNumber() throws {
        let current = try ReleaseVersion("v26.0.0")
        let candidates = [
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "50"),
            try UpdateCandidate(version: "v26.1.0-beta.2", build: "40")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .beta,
            candidates: candidates
        )

        XCTAssertEqual(selected?.version.rawValue, "v26.1.0-beta.2")
    }

    func testInvalidReleaseVersionsAreRejected() {
        XCTAssertThrowsError(try ReleaseVersion("26.0"))
        XCTAssertThrowsError(try ReleaseVersion("26.0.0-rc.1"))
        XCTAssertThrowsError(try ReleaseVersion("26.0.0-beta"))
        XCTAssertThrowsError(try ReleaseVersion("26.0.0-release.1"))
    }

    func testEmptyAndMalformedVersionComponentsAreRejectedWithoutTrapping() {
        let invalidVersions = [
            "", " ", "\n\t", "v", " v ", "-", "v-", "26..0.0", ".26.0.0", "26.0.0.",
            "26.0.0.extra", "26.x.0.0", "+26.0.0", "-26.0.0", "26.0.0-",
            "26.0.0-beta..1", "26.0.0-beta.1.", "26.0.0-beta.-1", "26.0.0-beta.+1",
            "26.0.0-beta.1-extra", "999999999999999999999999999999.0.0"
        ]
        for value in invalidVersions {
            XCTAssertThrowsError(try ReleaseVersion(value), value) { error in
                XCTAssertEqual(error as? ReleaseVersionParseError, .invalid(value))
            }
        }
    }

    func testValidVersionsPreserveWhitespacePrefixAndChannelCompatibility() throws {
        let stable = try ReleaseVersion(" \nv26.0.1\t")
        XCTAssertEqual(stable.rawValue, "v26.0.1")
        XCTAssertEqual(stable.channel, .release)
        XCTAssertEqual(stable.patch, 1)
        XCTAssertEqual(try ReleaseVersion("26.0.1-alpha.0").prereleaseNumber, 0)
        XCTAssertEqual(try ReleaseVersion("v26.0.1-beta.12").channel, .beta)
        XCTAssertEqual(try ReleaseVersion("026.00.01").major, 26)
    }

    func testReleaseVersionOrderingUsesBaseChannelAndPrereleaseNumber() throws {
        XCTAssertLessThan(try ReleaseVersion("v26.0.0-alpha.2"), try ReleaseVersion("v26.0.0-alpha.3"))
        XCTAssertLessThan(try ReleaseVersion("v26.0.0-alpha.3"), try ReleaseVersion("v26.0.0-beta.1"))
        XCTAssertLessThan(try ReleaseVersion("v26.0.0-beta.3"), try ReleaseVersion("v26.0.0"))
        XCTAssertLessThan(try ReleaseVersion("v26.0.0"), try ReleaseVersion("v26.0.1"))
        XCTAssertLessThan(try ReleaseVersion("v26.0.1"), try ReleaseVersion("v26.1.0"))
        XCTAssertLessThan(try ReleaseVersion("v26.1.0"), try ReleaseVersion("v27.0.0"))
    }

    func testHigherBuildWinsWhenVersionMatches() throws {
        let current = try ReleaseVersion("v26.0.0")
        let candidates = [
            try UpdateCandidate(version: "v26.0.1", build: "20"),
            try UpdateCandidate(version: "v26.0.1", build: "21")
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .release,
            candidates: candidates
        )

        XCTAssertEqual(selected?.build, 21)
    }

    func testNonnumericBuildDefaultsToZero() throws {
        let candidate = try UpdateCandidate(version: "v26.0.1", build: "latest")

        XCTAssertEqual(candidate.build, 0)
    }
}
