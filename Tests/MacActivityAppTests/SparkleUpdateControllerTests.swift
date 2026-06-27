import MacActivityCore
import XCTest
@testable import MacActivityApp

@MainActor
final class SparkleUpdateControllerTests: XCTestCase {
    func testAllowedSparkleChannelsTreatsReleaseAsDefaultChannel() {
        XCTAssertEqual(SparkleUpdateController.allowedSparkleChannels(for: .release), [])
        XCTAssertEqual(SparkleUpdateController.allowedSparkleChannels(for: .beta), ["beta"])
        XCTAssertEqual(SparkleUpdateController.allowedSparkleChannels(for: .alpha), ["alpha", "beta"])
    }

    func testControllerWithoutSparkleConfigurationDoesNotStartUpdater() throws {
        let preferencesController = makePreferencesController()
        let controller = SparkleUpdateController(
            preferencesController: preferencesController,
            bundle: try makeBundle(info: [
                "CFBundleShortVersionString": "26.0.0",
                "CFBundleVersion": "1",
            ])
        )

        XCTAssertFalse(controller.checkForUpdates())
        XCTAssertEqual(controller.allowedChannels(), [])
        preferencesController.setUpdateChannel(.beta)
        XCTAssertEqual(controller.allowedChannels(), ["beta"])
    }

    func testSparkleConfigurationRequiresUsablePublicKeyAndFeedURL() throws {
        XCTAssertFalse(
            SparkleUpdateController.hasSparkleConfiguration(
                in: try makeBundle(info: [
                    "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)",
                    "SUFeedURL": "https://example.com/appcast.xml",
                ])
            )
        )
        XCTAssertFalse(
            SparkleUpdateController.hasSparkleConfiguration(
                in: try makeBundle(info: [
                    "SUPublicEDKey": "test-key",
                    "SUFeedURL": "$(SPARKLE_FEED_URL)",
                ])
            )
        )
        XCTAssertTrue(
            SparkleUpdateController.hasSparkleConfiguration(
                in: try makeBundle(info: [
                    "SUPublicEDKey": "test-key",
                    "SUFeedURL": "https://example.com/appcast.xml",
                ])
            )
        )
    }

    func testReleaseTagPrefersConfiguredReleaseTag() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "26.0.0",
            "MacActivityReleaseTag": " v26.0.0-beta.2 ",
        ])

        XCTAssertEqual(SparkleUpdateController.releaseTag(in: bundle), "v26.0.0-beta.2")
        XCTAssertEqual(SparkleUpdateController.currentReleaseVersion(in: bundle)?.channel, .beta)
    }

    func testReleaseTagFallsBackToShortVersionAndIgnoresPlaceholders() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "26.0.1",
            "MacActivityReleaseTag": "$(MACACTIVITY_RELEASE_TAG)",
        ])

        XCTAssertEqual(SparkleUpdateController.releaseTag(in: bundle), "v26.0.1")
        XCTAssertEqual(SparkleUpdateController.currentReleaseVersion(in: bundle)?.rawValue, "v26.0.1")
    }

    func testReleaseTagReturnsNilWhenNoUsableVersionExists() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": " ",
            "MacActivityReleaseTag": "$(MACACTIVITY_RELEASE_TAG)",
        ])

        XCTAssertNil(SparkleUpdateController.releaseTag(in: bundle))
        XCTAssertNil(SparkleUpdateController.currentReleaseVersion(in: bundle))
    }

    func testReleaseVersionStringNormalizesSparkleChannelMetadata() {
        XCTAssertEqual(
            SparkleUpdateController.releaseVersionString(
                displayVersionString: "v26.0.0-beta.2",
                versionString: "9",
                channel: "beta"
            ),
            "v26.0.0-beta.2"
        )
        XCTAssertEqual(
            SparkleUpdateController.releaseVersionString(
                displayVersionString: "v26.0.0",
                versionString: "7",
                channel: "alpha"
            ),
            "v26.0.0-alpha.7"
        )
        XCTAssertEqual(
            SparkleUpdateController.releaseVersionString(
                displayVersionString: "v26.0.0",
                versionString: "build-7",
                channel: "alpha"
            ),
            "v26.0.0"
        )
        XCTAssertEqual(
            SparkleUpdateController.releaseVersionString(
                displayVersionString: "v26.0.0",
                versionString: "7",
                channel: nil
            ),
            "v26.0.0"
        )
    }

    func testUpdateCandidateBuildsFromSparkleMetadata() {
        let candidate = SparkleUpdateController.updateCandidate(
            for: SparkleAppcastCandidateInput(
                displayVersionString: "v26.0.0",
                versionString: "7",
                channel: "alpha"
            )
        )

        XCTAssertEqual(candidate?.version.rawValue, "v26.0.0-alpha.7")
        XCTAssertEqual(candidate?.build, 7)
    }

    func testUpdateCandidateRejectsInvalidDisplayVersion() {
        let candidate = SparkleUpdateController.updateCandidate(
            for: SparkleAppcastCandidateInput(
                displayVersionString: "invalid",
                versionString: "7",
                channel: nil
            )
        )

        XCTAssertNil(candidate)
    }

    func testBestCandidateIndexSkipsInvalidItemsAndReturnsMatchingInputIndex() throws {
        let index = SparkleUpdateController.bestCandidateIndex(
            currentVersion: try ReleaseVersion("v26.0.0-alpha.1"),
            selectedChannel: .alpha,
            candidates: [
                SparkleAppcastCandidateInput(
                    displayVersionString: "invalid",
                    versionString: "1",
                    channel: nil
                ),
                SparkleAppcastCandidateInput(
                    displayVersionString: "v26.0.0",
                    versionString: "2",
                    channel: "beta"
                ),
                SparkleAppcastCandidateInput(
                    displayVersionString: "v26.0.0",
                    versionString: "3",
                    channel: "alpha"
                ),
            ]
        )

        XCTAssertEqual(index, 1)
    }

    func testBestCandidateIndexReturnsNilWhenNoCandidateIsEligible() throws {
        let index = SparkleUpdateController.bestCandidateIndex(
            currentVersion: try ReleaseVersion("v26.0.0"),
            selectedChannel: .release,
            candidates: [
                SparkleAppcastCandidateInput(
                    displayVersionString: "v26.0.0",
                    versionString: "1",
                    channel: "alpha"
                ),
            ]
        )

        XCTAssertNil(index)
    }

    private func makePreferencesController() -> PreferencesController {
        PreferencesController(
            store: InMemoryPreferencesStore(initial: .default),
            launchService: NoopLaunchAtLoginService()
        )
    }

    private func makeBundle(info: [String: String]) throws -> Bundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let infoPlist = NSMutableDictionary(dictionary: [
            "CFBundleExecutable": "Mac Activity",
            "CFBundleIdentifier": "com.how.macactivity.test",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Mac Activity",
            "CFBundlePackageType": "APPL",
        ])
        infoPlist.addEntries(from: info)
        XCTAssertTrue(infoPlist.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true))
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

}

private final class InMemoryPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private var value: AppPreferences

    init(initial: AppPreferences) {
        self.value = initial
    }

    func load() -> AppPreferences {
        value
    }

    func save(_ preferences: AppPreferences) throws {
        value = preferences
    }
}
