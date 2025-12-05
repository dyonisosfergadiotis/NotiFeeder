import Foundation
import SwiftData

enum BookmarkService {
    static func isBookmarked(link: String, context: ModelContext) -> Bool {
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
    }

    static func addOrUpdateBookmark(for entry: FeedEntry, context: ModelContext) {
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.link == entry.link })

        if let existing = (try? context.fetch(descriptor))?.first {
            existing.title = entry.title
            existing.shortTitle = entry.shortTitle
            existing.link = entry.link
            existing.content = HTMLText.stripHTML(entry.content)
            existing.author = entry.author
            existing.sourceTitle = entry.sourceTitle
            existing.sourceURL = entry.feedURL
            existing.pubDateString = entry.pubDateString
            let parsed = entry.pubDateString.map { DateParser.parse($0) } ?? .distantPast
            existing.date = (parsed == .distantPast ? Date() : parsed)
            existing.isBookmarked = true
        } else {
            let model = FeedEntryModel(
                title: entry.title,
                shortTitle: entry.shortTitle,
                link: entry.link,
                content: HTMLText.stripHTML(entry.content),
                author: entry.author,
                sourceTitle: entry.sourceTitle,
                sourceURL: entry.feedURL,
                pubDateString: entry.pubDateString,
                date: {
                    let parsed = entry.pubDateString.map { DateParser.parse($0) } ?? .distantPast
                    return (parsed == .distantPast ? Date() : parsed)
                }(),
                isBookmarked: true,
                isRead: entry.isRead
            )
            context.insert(model)
        }
        try? context.save()
    }

    static func toggleBookmark(for entry: FeedEntry, context: ModelContext) {
        if isBookmarked(link: entry.link, context: context) {
            removeBookmark(link: entry.link, context: context)
        } else {
            addOrUpdateBookmark(for: entry, context: context)
        }
    }
}
