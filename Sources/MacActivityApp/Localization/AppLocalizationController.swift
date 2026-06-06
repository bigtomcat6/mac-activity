import Combine
import Foundation

@MainActor
final class AppLocalizationController: ObservableObject {
    static let shared = AppLocalizationController()

    @Published private(set) var preferredLanguageIdentifier: String?

    private init() {}

    func applyPreferredLanguageIdentifier(_ preferredLanguageIdentifier: String?) {
        let normalized = AppLocalization.normalizedLanguageIdentifier(preferredLanguageIdentifier)
        AppLocalization.setPreferredLanguageIdentifier(normalized)

        guard self.preferredLanguageIdentifier != normalized else {
            return
        }

        self.preferredLanguageIdentifier = normalized
    }
}
