import Foundation

nonisolated struct FeedHealthSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: String { feedURL }
    let feedURL: String
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastError: FeedFetchError?
    var articleCount: Int
    var nextRefreshAfter: Date?
    var attempts: Int
}

@MainActor
enum FeedHealthStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func snapshotsByFeedURL() -> [String: FeedHealthSnapshot] {
        guard let data = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.feedHealthSnapshots)
            ?? FeedStorage.defaults.data(forKey: FeedStorage.Keys.feedHealthSnapshots),
              let snapshots = try? decoder.decode([FeedHealthSnapshot].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: snapshots.map { ($0.feedURL, $0) })
    }

    static func record(
        feed: FeedSource,
        status: FeedFetchStatus,
        attemptedAt: Date,
        articleCount: Int,
        nextRefreshAfter: Date?
    ) {
        var snapshots = snapshotsByFeedURL()
        var snapshot = snapshots[feed.url] ?? FeedHealthSnapshot(
            feedURL: feed.url,
            lastAttemptAt: nil,
            lastSuccessAt: nil,
            lastError: nil,
            articleCount: 0,
            nextRefreshAfter: nil,
            attempts: 0
        )

        snapshot.lastAttemptAt = attemptedAt
        if status.error == nil {
            snapshot.lastSuccessAt = attemptedAt
        }
        snapshot.lastError = status.error
        snapshot.articleCount = articleCount
        snapshot.nextRefreshAfter = nextRefreshAfter
        snapshot.attempts = status.attempts
        snapshots[feed.url] = snapshot
        persist(Array(snapshots.values))
    }

    static func removeSnapshots(for feedURLs: [String]) {
        guard !feedURLs.isEmpty else { return }
        var snapshots = snapshotsByFeedURL()
        var didRemove = false
        for feedURL in feedURLs {
            if snapshots.removeValue(forKey: feedURL) != nil {
                didRemove = true
            }
        }
        guard didRemove else { return }
        persist(Array(snapshots.values))
    }

    private static func persist(_ snapshots: [FeedHealthSnapshot]) {
        guard let data = try? encoder.encode(snapshots.sorted { $0.feedURL < $1.feedURL }) else { return }
        _ = FeedCacheSync.write(data, for: FeedStorage.Keys.feedHealthSnapshots)
    }
}
