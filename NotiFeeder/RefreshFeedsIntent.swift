import AppIntents
import Foundation

struct RefreshFeedsIntent: AppIntent {
    static var title: LocalizedStringResource = "Feeds prüfen"
    static var description = IntentDescription("Lädt alle gespeicherten Feeds und löst lokal neue Benachrichtigungen aus.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let result = await FeedRefreshEngine.shared.refreshAllFeeds(trigger: .appIntent)

        guard result.totalFeeds > 0 else {
            return .result(value: "Keine Feeds gefunden")
        }

        guard !result.wasCancelled else {
            return .result(value: "Feed-Refresh abgebrochen")
        }

        if result.successfulFeeds == result.totalFeeds {
            return .result(
                value: "Aktualisiert: \(result.fetchedEntries) Einträge aus \(result.successfulFeeds) Feeds"
            )
        }

        return .result(
            value: "Teilweise aktualisiert: \(result.fetchedEntries) Einträge aus \(result.successfulFeeds)/\(result.totalFeeds) Feeds"
        )
    }
}
