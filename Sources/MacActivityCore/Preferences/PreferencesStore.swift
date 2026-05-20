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
            let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
            let migrated = migrateLegacyDefaultsIfNeeded(decoded, rawData: data)
            if migrated != decoded {
                try? save(migrated)
            }
            return migrated
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

    private func migrateLegacyDefaultsIfNeeded(_ preferences: AppPreferences, rawData: Data) -> AppPreferences {
        guard isLegacyMenuBarPreferencePayload(rawData),
              preferences.selectedSummaryMetrics == [.cpu, .memory, .network] else {
            return preferences
        }

        var migrated = preferences
        migrated.selectedSummaryMetrics = AppPreferences.default.selectedSummaryMetrics
        return migrated
    }

    private func isLegacyMenuBarPreferencePayload(_ data: Data) -> Bool {
        guard let json = String(data: data, encoding: .utf8) else {
            return false
        }

        return json.contains(#""isMenuBarEnabled""#)
    }
}
