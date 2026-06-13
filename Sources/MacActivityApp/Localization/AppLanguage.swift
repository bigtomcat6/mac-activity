import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var preferredLanguageIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    init(preferredLanguageIdentifier: String?) {
        switch AppLocalization.normalizedLanguageIdentifier(preferredLanguageIdentifier)?.lowercased() {
        case "en":
            self = .english
        case "zh-hans":
            self = .simplifiedChinese
        default:
            self = .system
        }
    }
}
