import Foundation

enum NotificationDeliveryTracker {
    private static let cachedLinksKey = "cachedLinks"

    private static func storedIDs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: cachedLinksKey) ?? [])
    }

    static func hasTrackedArticles(defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: cachedLinksKey) ?? []).isEmpty
    }

    @discardableResult
    static func markAndReturnNew(entries: [FeedEntry], defaults: UserDefaults = .standard) -> [FeedEntry] {
        guard !entries.isEmpty else { return [] }
        var known = storedIDs(defaults: defaults)
        var updated = false
        var newEntries: [FeedEntry] = []

        for entry in entries {
            let identifier = entry.link
            if !known.contains(identifier) {
                newEntries.append(entry)
                known.insert(identifier)
                updated = true
            }
        }

        if updated {
            defaults.set(Array(known), forKey: cachedLinksKey)
        }

        return newEntries
    }
}
