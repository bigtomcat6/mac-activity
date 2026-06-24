import XCTest
@testable import MacActivityCore

final class UpdateCandidateSelectorTests: XCTestCase {
    func testReleaseCandidateWinsOverHigherPrereleaseForAlphaChannel() throws {
        let current = try ReleaseVersion("v26.0.0-alpha.2")
        let candidates = [
            try UpdateCandidate(version: "v26.0.1", build: "20"),
            try UpdateCandidate(version: "v26.1.0-alpha.3", build: "30"),
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "40"),
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
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "40"),
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
            try UpdateCandidate(version: "v26.1.0-alpha.3", build: "30"),
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
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "40"),
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
            try UpdateCandidate(version: "v26.1.0-beta.1", build: "40"),
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
            try UpdateCandidate(version: "v26.0.1", build: "50"),
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
            try UpdateCandidate(version: "v26.1.0-alpha.3", build: "31"),
        ]

        let selected = UpdateCandidateSelector.bestCandidate(
            currentVersion: current,
            selectedChannel: .alpha,
            candidates: candidates
        )

        XCTAssertEqual(selected?.version.rawValue, "v26.1.0-alpha.3")
    }
}
