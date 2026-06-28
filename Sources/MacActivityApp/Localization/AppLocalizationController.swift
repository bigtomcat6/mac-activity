import Combine
import Foundation

@MainActor
final class AppLocalizationController: ObservableObject {
    static let shared = AppLocalizationController()
    private static let appleLanguagesKey = "AppleLanguages"

    @Published private(set) var preferredLanguageIdentifier: String?

    private init() {}

    func applyPreferredLanguageIdentifier(_ preferredLanguageIdentifier: String?) {
        let normalized = AppLocalization.normalizedLanguageIdentifier(preferredLanguageIdentifier)
        AppLocalization.setPreferredLanguageIdentifier(normalized)
        applyFoundationLanguageOverride(normalized)

        guard self.preferredLanguageIdentifier != normalized else {
            return
        }

        self.preferredLanguageIdentifier = normalized
    }

    private func applyFoundationLanguageOverride(_ languageIdentifier: String?) {
        if let languageIdentifier {
            // ponytail: Sparkle asks Foundation for preferred localizations; keep that native path aligned.
            UserDefaults.standard.set([languageIdentifier], forKey: Self.appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.appleLanguagesKey)
        }
    }
}
