import Foundation

enum LastReadingArticleStore {
    private static let key = "nf_last_minimized_article_v1"
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func save(_ entry: FeedEntry) {
        guard let data = try? encoder.encode(entry) else { return }
        FeedStorage.defaults.set(data, forKey: key)
    }

    static func restore() -> FeedEntry? {
        guard let data = FeedStorage.defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(FeedEntry.self, from: data)
    }

    static func clear() {
        FeedStorage.defaults.removeObject(forKey: key)
    }
}
