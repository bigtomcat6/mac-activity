import Foundation

struct AppLanguage: Hashable, Identifiable {
    static let system = AppLanguage(canonicalLanguageIdentifier: nil)

    let preferredLanguageIdentifier: String?

    var id: String {
        preferredLanguageIdentifier ?? "system"
    }

    init(preferredLanguageIdentifier: String?) {
        guard let normalized = AppLocalization.normalizedLanguageIdentifier(preferredLanguageIdentifier) else {
            self.preferredLanguageIdentifier = nil
            return
        }

        let available = AppLocalization.availableLanguageIdentifiers()
        self.preferredLanguageIdentifier = Bundle.preferredLocalizations(
            from: available,
            forPreferences: [normalized]
        ).first
    }

    private init(canonicalLanguageIdentifier: String?) {
        self.preferredLanguageIdentifier = canonicalLanguageIdentifier
    }

    static func supportedLanguages(in bundle: Bundle? = nil) -> [AppLanguage] {
        [.system] + AppLocalization.availableLanguageIdentifiers(in: bundle)
            .map { AppLanguage(canonicalLanguageIdentifier: $0) }
    }
}
