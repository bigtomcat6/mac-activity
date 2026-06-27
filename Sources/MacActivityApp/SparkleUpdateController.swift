import Combine
import Foundation
import MacActivityCore
@preconcurrency import Sparkle

@MainActor
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate {
    private static let releaseTagInfoKey = "MacActivityReleaseTag"

    private let preferencesController: PreferencesController
    private let bundle: Bundle
    private let versionDisplay: MacActivitySparkleVersionDisplay
    private let userDriverDelegate: MacActivitySparkleUserDriverDelegate
    private var cancellables: Set<AnyCancellable> = []

    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard Self.hasSparkleConfiguration(in: bundle) else {
            return nil
        }

        return SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: userDriverDelegate
        )
    }()

    init(preferencesController: PreferencesController, bundle: Bundle = .main) {
        self.preferencesController = preferencesController
        self.bundle = bundle
        versionDisplay = MacActivitySparkleVersionDisplay(bundle: bundle)
        userDriverDelegate = MacActivitySparkleUserDriverDelegate(versionDisplay: versionDisplay)
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
        allowedChannels()
    }

    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        guard let currentVersion = Self.currentReleaseVersion(in: bundle) else {
            return nil
        }

        let items = appcast.items
        let candidates = items.map(Self.appcastCandidateInput(for:))
        guard let bestIndex = Self.bestCandidateIndex(
            currentVersion: currentVersion,
            selectedChannel: preferencesController.state.updateChannel,
            candidates: candidates
        ) else {
            return SUAppcastItem.empty()
        }

        return items[bestIndex]
    }

    func allowedChannels() -> Set<String> {
        Self.allowedSparkleChannels(for: preferencesController.state.updateChannel)
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

    static func bestCandidateIndex(
        currentVersion: ReleaseVersion,
        selectedChannel: UpdateChannel,
        candidates: [SparkleAppcastCandidateInput]
    ) -> Int? {
        let indexedCandidates = candidates.enumerated().compactMap { offset, input -> (offset: Int, candidate: UpdateCandidate)? in
            guard let candidate = updateCandidate(for: input) else {
                return nil
            }

            return (offset, candidate)
        }
        let updateCandidates = indexedCandidates.map(\.candidate)
        guard let bestCandidate = UpdateCandidateSelector.bestCandidate(
            currentVersion: currentVersion,
            selectedChannel: selectedChannel,
            candidates: updateCandidates
        ) else {
            return nil
        }

        return indexedCandidates.first { $0.candidate == bestCandidate }?.offset
    }

    static func updateCandidate(for input: SparkleAppcastCandidateInput) -> UpdateCandidate? {
        guard let releaseVersionString = releaseVersionString(
            displayVersionString: input.displayVersionString,
            versionString: input.versionString,
            channel: input.channel
        ) else {
            return nil
        }

        return try? UpdateCandidate(version: releaseVersionString, build: input.versionString)
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

    static func appcastCandidateInput(for item: SUAppcastItem) -> SparkleAppcastCandidateInput {
        SparkleAppcastCandidateInput(
            displayVersionString: item.displayVersionString,
            versionString: item.versionString,
            channel: item.channel
        )
    }
}

struct SparkleAppcastCandidateInput: Equatable {
    let displayVersionString: String
    let versionString: String
    let channel: String?
}

final class MacActivitySparkleUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    private let versionDisplay: MacActivitySparkleVersionDisplay

    init(versionDisplay: MacActivitySparkleVersionDisplay) {
        self.versionDisplay = versionDisplay
        super.init()
    }

    func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        versionDisplay
    }
}

final class MacActivitySparkleVersionDisplay: NSObject, SUVersionDisplay {
    private let displayVersion: String

    init(bundle: Bundle = .main) {
        let shortVersion = Self.cleanInfoValue(
            "CFBundleShortVersionString",
            in: bundle
        ) ?? "0.0.0"
        displayVersion = Self.bundleDisplayVersion(
            shortVersion: shortVersion,
            releaseTag: Self.releaseTag(in: bundle, shortVersion: shortVersion)
        )
        super.init()
    }

    static func bundleDisplayVersion(shortVersion: String, releaseTag: String?) -> String {
        let releaseTag = releaseTag?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let releaseTag,
              !releaseTag.isEmpty,
              !releaseTag.contains("$("),
              releaseTag != "v\(shortVersion)" else {
            return shortVersion
        }

        return releaseTag.hasPrefix("v") ? String(releaseTag.dropFirst()) : releaseTag
    }

    func formatUpdateVersion(
        fromUpdate update: SUAppcastItem,
        andBundleDisplayVersion inOutBundleDisplayVersion: AutoreleasingUnsafeMutablePointer<NSString>,
        withBundleVersion bundleVersion: String
    ) -> String {
        inOutBundleDisplayVersion.pointee = displayVersion as NSString
        return update.displayVersionString
    }

    func formatBundleDisplayVersion(
        _ bundleDisplayVersion: String,
        withBundleVersion bundleVersion: String,
        matchingUpdate: SUAppcastItem?
    ) -> String {
        displayVersion
    }

    private static func releaseTag(in bundle: Bundle, shortVersion: String) -> String? {
        if let releaseTag = cleanInfoValue("MacActivityReleaseTag", in: bundle) {
            return releaseTag
        }

        return "v\(shortVersion)"
    }

    private static func cleanInfoValue(_ key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("$(") ? nil : trimmed
    }
}
