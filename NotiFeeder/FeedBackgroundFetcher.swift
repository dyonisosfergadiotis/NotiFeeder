//
//  FeedBackgroundFetcher.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.11.25.
//


import Foundation
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
        let allEntries = flattenedEntries.map(\.1)
        let brandNewEntries = NotificationDeliveryTracker.markAndReturnNew(entries: allEntries)
        if brandNewEntries.isEmpty {
            return
        }

        let newIDs = Set(brandNewEntries.map(\.link))
        let newPairs = flattenedEntries.filter { newIDs.contains($0.1.link) }

        _ = newPairs
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

}
