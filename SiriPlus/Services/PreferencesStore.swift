import Foundation

@MainActor
final class PreferencesStore {
    private let defaults: UserDefaults
    private let key = "assistant.preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AssistantPreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(AssistantPreferences.self, from: data) else {
            return AssistantPreferences()
        }
        return preferences
    }

    func save(_ preferences: AssistantPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
