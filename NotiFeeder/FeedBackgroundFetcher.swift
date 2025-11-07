//
//  FeedBackgroundFetcher.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.11.25.
//


import Foundation
import UserNotifications

final class FeedBackgroundFetcher {
    static let shared = FeedBackgroundFetcher()

    private init() {}

    func checkForNewEntries(feeds: [FeedSource]) async {
        guard !feeds.isEmpty else { return }
        var fetchedResults: [(feed: FeedSource, entries: [FeedEntry])] = []

        await withTaskGroup(of: (FeedSource, [FeedEntry]).self) { group in
            for feed in feeds {
                group.addTask { (feed, await self.fetchFeed(feed)) }
            }
            for await (feed, entries) in group {
                fetchedResults.append((feed, entries))
            }
        }

        let flattenedEntries: [(FeedSource, FeedEntry)] = fetchedResults.flatMap { result in
            result.entries.map { (result.feed, $0) }
        }

        let cachedLinks = UserDefaults.standard.stringArray(forKey: "cachedLinks") ?? []
        let newPairs = flattenedEntries.filter { pair in !cachedLinks.contains(pair.1.link) }

        guard !newPairs.isEmpty else { return }

        let allLinks = Set(cachedLinks + newPairs.map { $0.1.link })
        UserDefaults.standard.set(Array(allLinks), forKey: "cachedLinks")

        guard NotificationPreferenceStore.notificationsEnabled() else { return }
        let allowedFeeds = NotificationPreferenceStore.allowedFeedURLs(availableFeeds: feeds)
        guard !allowedFeeds.isEmpty else { return }

        let allowedPairs = newPairs.filter { allowedFeeds.contains($0.0.url) }
        guard !allowedPairs.isEmpty else { return }

        for (_, entry) in allowedPairs.prefix(3) {
            sendNotification(for: entry)
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

    private func plainText(from html: String) -> String {
        // Pure Foundation fallback: strip tags and decode common entities
        var text = html
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        // collapse whitespace
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func oneLineSummary(from html: String, limit: Int = 140) -> String {
        let text = plainText(from: html).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= limit { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        var trimmed = String(text[..<idx])
        if let lastSpace = trimmed.lastIndex(of: " ") { trimmed = String(trimmed[..<lastSpace]) }
        return trimmed
    }

    private func sendNotification(for entry: FeedEntry) {
        let content = UNMutableNotificationContent()
        content.title = entry.title
        let summary = oneLineSummary(from: entry.content)
        content.body = summary.isEmpty ? (entry.sourceTitle ?? "Neuer Artikel verfügbar") : summary
        content.sound = .default

        let request = UNNotificationRequest(identifier: entry.link, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
