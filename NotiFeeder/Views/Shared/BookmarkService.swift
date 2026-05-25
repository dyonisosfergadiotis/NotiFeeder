import Foundation
import SwiftData

enum BookmarkService {
    private static let bookmarksKey = FeedStorage.Keys.bookmarkedArticleIDs
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func isBookmarked(link: String, context: ModelContext) -> Bool {
        if persistedBookmarkedLinks().contains(link) {
            return true
        }
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.link == link && $0.isBookmarked })
        if let result = try? context.fetch(descriptor) {
            return !result.isEmpty
        }
        return false
    }

    static func removeBookmark(link: String, context: ModelContext) {
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.link == link && $0.isBookmarked })
        if let results = try? context.fetch(descriptor) {
            for model in results {
                model.isBookmarked = false
            }
            try? context.save()
        }
        var links = persistedBookmarkedLinks()
        links.remove(link)
        persistBookmarkedLinks(links)
    }

    static func addOrUpdateBookmark(for entry: FeedEntry, context: ModelContext) {
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.link == entry.link })

        if let existing = (try? context.fetch(descriptor))?.first {
            existing.title = entry.title
            existing.shortTitle = entry.shortTitle
            existing.link = entry.link
            existing.content = entry.content
            existing.contentRaw = entry.contentRaw
            existing.author = entry.author
            existing.sourceTitle = entry.sourceTitle
            existing.sourceURL = entry.feedURL
            existing.pubDateString = entry.pubDateString
            let parsed = entry.pubDateString.map { DateParser.parse($0) } ?? .distantPast
            existing.date = (parsed == .distantPast ? Date() : parsed)
            existing.isBookmarked = true
            existing.isRead = entry.isRead
            existing.isNew = entry.isNew
        } else {
            let model = FeedEntryModel(
                title: entry.title,
                shortTitle: entry.shortTitle,
                link: entry.link,
                content: entry.content,
                contentRaw: entry.contentRaw,
                author: entry.author,
                sourceTitle: entry.sourceTitle,
                sourceURL: entry.feedURL,
                pubDateString: entry.pubDateString,
                date: {
                    let parsed = entry.pubDateString.map { DateParser.parse($0) } ?? .distantPast
                    return (parsed == .distantPast ? Date() : parsed)
                }(),
                isBookmarked: true,
                isRead: entry.isRead,
                isNew: entry.isNew
            )
            context.insert(model)
        }
        try? context.save()
        var links = persistedBookmarkedLinks()
        links.insert(entry.link)
        persistBookmarkedLinks(links)
    }

    static func toggleBookmark(for entry: FeedEntry, context: ModelContext) {
        if isBookmarked(link: entry.link, context: context) {
            removeBookmark(link: entry.link, context: context)
        } else {
            addOrUpdateBookmark(for: entry, context: context)
        }
    }

    static func allBookmarkedLinks(context: ModelContext) -> Set<String> {
        var links = persistedBookmarkedLinks()
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.isBookmarked })
        if let results = try? context.fetch(descriptor) {
            links.formUnion(results.map(\.link))
        }
        return links
    }

    @MainActor
    static func syncBookmarksFromCloudIfNeeded(context: ModelContext) async {
        await FeedCloudKitSyncManager.shared.syncDataFromCloudIfNeeded(for: bookmarksKey)
        guard FeedCacheSync.bestAvailableData(for: bookmarksKey) != nil else {
            let localLinks = bookmarkedLinksFromModels(context: context)
            if !localLinks.isEmpty {
                persistBookmarkedLinks(localLinks)
            }
            return
        }
        applyPersistedBookmarksToModels(context: context)
    }

    private static func applyPersistedBookmarksToModels(context: ModelContext) {
        let persisted = persistedBookmarkedLinks()
        let descriptor = FetchDescriptor<FeedEntryModel>()
        guard let models = try? context.fetch(descriptor) else { return }

        var didMutate = false
        for model in models {
            let shouldBeBookmarked = persisted.contains(model.link)
            if model.isBookmarked != shouldBeBookmarked {
                model.isBookmarked = shouldBeBookmarked
                didMutate = true
            }
        }

        if didMutate {
            try? context.save()
        }
    }

    private static func bookmarkedLinksFromModels(context: ModelContext) -> Set<String> {
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.isBookmarked })
        if let results = try? context.fetch(descriptor) {
            return Set(results.map(\.link))
        }
        return []
    }

    private static func persistedBookmarkedLinks() -> Set<String> {
        guard let data = FeedCacheSync.bestAvailableData(for: bookmarksKey),
              let links = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return Set(links)
    }

    private static func persistBookmarkedLinks(_ links: Set<String>) {
        let sortedLinks = links.sorted()
        guard let data = try? encoder.encode(sortedLinks) else { return }
        let token = FeedCacheSync.write(data, for: bookmarksKey)
        Task { @MainActor in
            FeedCloudKitSyncManager.shared.uploadLocalData(data, token: token, for: bookmarksKey)
        }
    }
}
