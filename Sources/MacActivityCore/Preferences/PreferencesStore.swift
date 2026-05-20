import Foundation

public protocol PreferencesStoring: Sendable {
    func load() -> AppPreferences
    func save(_ preferences: AppPreferences) throws
}

public enum PreferencesStoreError: Error, Equatable {
    case saveFailed(String)
}

public final class UserDefaultsPreferencesStore: PreferencesStoring, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let key = "mac-activity.preferences"

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func load() -> AppPreferences {
        guard let data = userDefaults.data(forKey: key) else {
            return .default
        }

        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data)
        } catch {
            return .default
        }
    }

    public func save(_ preferences: AppPreferences) throws {
        do {
            let data = try JSONEncoder().encode(preferences)
            userDefaults.set(data, forKey: key)
        } catch {
            throw PreferencesStoreError.saveFailed(error.localizedDescription)
        }
    }
}
