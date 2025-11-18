import AppIntents
import Foundation

struct RefreshFeedsIntent: AppIntent {
    static var title: LocalizedStringResource = "Feeds prüfen"
    static var description = IntentDescription("Lädt alle gespeicherten Feeds und löst lokal neue Benachrichtigungen aus.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let feeds = Self.loadSavedFeeds()
        guard !feeds.isEmpty else {
            return .result(value: "Keine Feeds gefunden")
        }

        Task.detached(priority: .background) {
            await FeedBackgroundFetcher.shared.checkForNewEntries(feeds: feeds)
        }

        return .result(value: "Feeds werden geprüft")
    }

    private static func loadSavedFeeds() -> [FeedSource] {
        guard let data = UserDefaults.standard.data(forKey: "savedFeeds"),
              let parsed = try? JSONDecoder().decode([FeedSource].self, from: data) else {
            return []
        }
        return parsed
    }
}
