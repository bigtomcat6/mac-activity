import Combine
import Foundation
import MacActivityCore
@preconcurrency import Sparkle

@MainActor
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate {
    private static let releaseTagInfoKey = "MacActivityReleaseTag"

    private let preferencesController: PreferencesController
    private let bundle: Bundle
    private var cancellables: Set<AnyCancellable> = []

    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard Self.hasSparkleConfiguration(in: bundle) else {
            return nil
        }

        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }()

    init(preferencesController: PreferencesController, bundle: Bundle = .main) {
        self.preferencesController = preferencesController
        self.bundle = bundle
        super.init()

        preferencesController.$state
            .map(\.updateChannel)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.updaterController?.updater.resetUpdateCycle()
            }
            .store(in: &cancellables)

        _ = updaterController
    }

    @discardableResult
    func checkForUpdates() -> Bool {
        guard let updaterController else {
            return false
        }

        updaterController.checkForUpdates(nil)
        return true
    }

    nonisolated static func allowedSparkleChannels(for selectedChannel: UpdateChannel) -> Set<String> {
        Set(selectedChannel.visibleChannels.filter { $0 != .release }.map(\.rawValue))
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.allowedSparkleChannels(for: preferencesController.state.updateChannel)
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        guard let currentVersion = Self.currentReleaseVersion(in: bundle) else {
            return nil
        }

        let candidateItems = appcast.items.compactMap { item -> (item: SUAppcastItem, candidate: UpdateCandidate)? in
            guard let candidate = Self.updateCandidate(for: item) else {
                return nil
            }

            return (item, candidate)
        }

        let candidates = candidateItems.map(\.candidate)
        guard let bestCandidate = UpdateCandidateSelector.bestCandidate(
            currentVersion: currentVersion,
            selectedChannel: preferencesController.state.updateChannel,
            candidates: candidates
        ) else {
            return SUAppcastItem.empty()
        }

        return candidateItems.first { $0.candidate == bestCandidate }?.item ?? SUAppcastItem.empty()
    }

    static func hasSparkleConfiguration(in bundle: Bundle) -> Bool {
        guard let publicKey = cleanInfoValue("SUPublicEDKey", in: bundle),
              !publicKey.isEmpty,
              let feedURLString = cleanInfoValue("SUFeedURL", in: bundle),
              URL(string: feedURLString) != nil else {
            return false
        }

        return true
    }

    static func currentReleaseVersion(in bundle: Bundle) -> ReleaseVersion? {
        guard let releaseTag = releaseTag(in: bundle) else {
            return nil
        }

        return try? ReleaseVersion(releaseTag)
    }

    static func releaseTag(in bundle: Bundle) -> String? {
        if let releaseTag = cleanInfoValue(releaseTagInfoKey, in: bundle), !releaseTag.isEmpty {
            return releaseTag
        }

        guard let shortVersion = cleanInfoValue("CFBundleShortVersionString", in: bundle),
              !shortVersion.isEmpty else {
            return nil
        }

        return "v\(shortVersion)"
    }

    private static func updateCandidate(for item: SUAppcastItem) -> UpdateCandidate? {
        guard let releaseVersionString = releaseVersionString(
            displayVersionString: item.displayVersionString,
            versionString: item.versionString,
            channel: item.channel
        ) else {
            return nil
        }

        return try? UpdateCandidate(version: releaseVersionString, build: item.versionString)
    }

    static func releaseVersionString(
        displayVersionString: String,
        versionString: String,
        channel: String?
    ) -> String? {
        if (try? ReleaseVersion(displayVersionString))?.channel != .release {
            return displayVersionString
        }

        guard let channel,
              let updateChannel = UpdateChannel(rawValue: channel),
              updateChannel != .release,
              Int(versionString) != nil else {
            return displayVersionString
        }

        return "\(displayVersionString)-\(updateChannel.rawValue).\(versionString)"
    }

    static func cleanInfoValue(_ key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("$(") ? nil : trimmed
    }
}
