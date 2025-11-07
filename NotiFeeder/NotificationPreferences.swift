import Foundation

struct NotificationPreferencesPayload: Codable {
    var enabledFeeds: Set<String>
    var knownFeeds: Set<String>
}

enum NotificationPreferenceStore {
    private static let feedPreferencesKey = "notificationFeedPreferences"
    private static let enabledToggleKey = "notificationsEnabledPreference"

    static func notificationsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledToggleKey) as? Bool ?? true
    }

    static func setNotificationsEnabled(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: enabledToggleKey)
    }

    static func allowedFeedURLs(from data: Data?, availableFeeds: [FeedSource]) -> Set<String> {
        guard let data, !data.isEmpty else {
            return Set(availableFeeds.map(\.url))
        }
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(NotificationPreferencesPayload.self, from: data) {
            return payload.enabledFeeds
        }
        if let legacy = try? decoder.decode(Set<String>.self, from: data) {
            return legacy
        }
        return Set(availableFeeds.map(\.url))
    }

    static func allowedFeedURLs(defaults: UserDefaults = .standard, availableFeeds: [FeedSource]) -> Set<String> {
        allowedFeedURLs(from: defaults.data(forKey: feedPreferencesKey), availableFeeds: availableFeeds)
    }
}
