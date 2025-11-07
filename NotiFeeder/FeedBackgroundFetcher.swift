import Foundation
import UserNotifications

@MainActor
final class FeedBackgroundFetcher {
    static let shared = FeedBackgroundFetcher()

    private init() {}

    func checkForNewEntries(feeds: [FeedSource]) async {
        var newEntries: [FeedEntry] = []

        await withTaskGroup(of: [FeedEntry].self) { group in
            for feed in feeds {
                group.addTask { await self.fetchFeed(feed) }
            }
            for await result in group {
                newEntries.append(contentsOf: result)
            }
        }

        // Vergleiche mit lokalem Cache
        let cachedLinks = UserDefaults.standard.stringArray(forKey: "cachedLinks") ?? []
        let newOnes = newEntries.filter { !cachedLinks.contains($0.link) }

        if !newOnes.isEmpty {
            // Speichern der neuen Links für nächsten Vergleich
            let allLinks = Set(cachedLinks + newOnes.map(\.link))
            UserDefaults.standard.set(Array(allLinks), forKey: "cachedLinks")

            // Benachrichtigen
            for entry in newOnes.prefix(3) { // max. 3 Pushes gleichzeitig
                sendNotification(for: entry)
            }
        }
    }

    private func fetchFeed(_ feed: FeedSource) async -> [FeedEntry] {
        guard let url = URL(string: feed.url) else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parser = RSSParser()
            return parser.parse(data: data)
        } catch {
            print("Fehler beim Laden: \(error)")
            return []
        }
    }

    private func sendNotification(for entry: FeedEntry) {
        let content = UNMutableNotificationContent()
        content.title = entry.title
        content.body = entry.sourceTitle ?? "Neuer Artikel verfügbar"
        content.sound = .default

        let request = UNNotificationRequest(identifier: entry.link, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}