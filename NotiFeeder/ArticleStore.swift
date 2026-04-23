// ArticleStore.swift
// Persistent storage for articles, summaries, and read-state using UserDefaults.
// This is a minimal, dependency-free approach and can be swapped to SwiftData later.

import Foundation
import Combine

// MARK: - Models expected in the app
// If these already exist elsewhere in the project, ensure these mirror the existing definitions
// or remove these duplicates and import the existing ones. The store relies on Codable.

public struct StoredFeedArticle: Codable, Hashable, Identifiable {
    public var id: String { link }
    public let title: String
    public let link: String
    public let publishedAt: Date?
    public let summary: String?
    public let feedTitle: String?
}

struct StoredArticleSummary: Codable, Hashable {
    let sourceSignature: String
    let summary: String
    let updatedAt: Date
}

// MARK: - ArticleStore
final class ArticleStore: ObservableObject {
    static let shared = ArticleStore()

    // Persisted keys
    private let articlesKey = FeedStorage.Keys.savedArticles
    private let summariesKey = FeedStorage.Keys.articleSummaries
    private let readKey = FeedStorage.Keys.readArticleIDs
    private let recentlyReadKey = "recentlyReadArticleIDs"
    private let maxArticlesPerFeed = 100
    private let maxStoredSummaries = 300

    // In-memory cache
    @Published private(set) var articlesByFeed: [String: [StoredFeedArticle]] = [:] // key: feed URL
    @Published private(set) var articleSummariesByID: [String: StoredArticleSummary] = [:]
    @Published private(set) var readArticleIDs: Set<String> = []
    @Published private(set) var recentlyReadArticleIDs: Set<String> = []

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "ArticleStore.queue", qos: .utility)
    private var cloudSyncObservers: [NSObjectProtocol] = []

    private init(defaults: UserDefaults = FeedStorage.defaults) {
        self.defaults = defaults
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        observeCloudSync()
        loadFromDisk()
        promoteRecentlyReadFromPreviousSession()
    }

    deinit {
        for observer in cloudSyncObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Persistence
    private func loadFromDisk() {
        // Load articles
        if let data = FeedCacheSync.bestAvailableData(for: articlesKey) ?? defaults.data(forKey: articlesKey),
           let loaded = try? decoder.decode([String: [StoredFeedArticle]].self, from: data) {
            articlesByFeed = loaded
        } else {
            articlesByFeed = [:]
        }
        if let data = FeedCacheSync.bestAvailableData(for: summariesKey) ?? defaults.data(forKey: summariesKey),
           let loaded = try? decoder.decode([String: StoredArticleSummary].self, from: data) {
            articleSummariesByID = loaded
        } else {
            articleSummariesByID = [:]
        }
        // Load read-state
        if let data = FeedCacheSync.bestAvailableData(for: readKey) ?? defaults.data(forKey: readKey),
           let loaded = try? decoder.decode([String].self, from: data) {
            readArticleIDs = Set(loaded)
        } else {
            readArticleIDs = []
        }
        if let data = FeedCacheSync.bestAvailableData(for: recentlyReadKey) ?? defaults.data(forKey: recentlyReadKey),
           let loaded = try? decoder.decode([String].self, from: data) {
            recentlyReadArticleIDs = Set(loaded)
        } else {
            recentlyReadArticleIDs = []
        }
    }

    private func saveArticlesToDisk() {
        let snapshot = articlesByFeed
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? self.encoder.encode(snapshot) {
                _ = FeedCacheSync.write(data, for: self.articlesKey)
            }
        }
    }

    private func saveSummariesToDisk() {
        let snapshot = articleSummariesByID
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? self.encoder.encode(snapshot) {
                _ = FeedCacheSync.write(data, for: self.summariesKey)
            }
        }
    }

    private func saveReadStateToDisk() {
        let array = readArticleIDs.sorted()
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? self.encoder.encode(array) {
                _ = FeedCacheSync.write(data, for: self.readKey)
                Task { @MainActor in
                    FeedICloudSyncManager.shared.pushLocalData(data, for: self.readKey)
                }
            }
        }
    }

    private func saveRecentlyReadStateToDisk() {
        let array = recentlyReadArticleIDs.sorted()
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? self.encoder.encode(array) {
                _ = FeedCacheSync.write(data, for: self.recentlyReadKey)
            }
        }
    }

    private func promoteRecentlyReadFromPreviousSession() {
        guard !recentlyReadArticleIDs.isEmpty else { return }

        readArticleIDs.formUnion(recentlyReadArticleIDs)
        recentlyReadArticleIDs.removeAll()
        saveReadStateToDisk()
        saveRecentlyReadStateToDisk()
    }

    // MARK: Public API
    func articles(for feedURL: String) -> [StoredFeedArticle] {
        articlesByFeed[feedURL] ?? []
    }

    func mergeArticles(_ newArticles: [StoredFeedArticle], for feedURL: String) {
        var existing = articlesByFeed[feedURL] ?? []
        let existingIDs = Set(existing.map { $0.id })
        let uniques = newArticles.filter { !existingIDs.contains($0.id) }
        if !uniques.isEmpty {
            existing.append(contentsOf: uniques)
            // Optional: Sort by date desc if available, else keep insertion order
            existing.sort { (lhs, rhs) in
                switch (lhs.publishedAt, rhs.publishedAt) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.title < rhs.title
                }
            }
            if existing.count > maxArticlesPerFeed {
                existing = Array(existing.prefix(maxArticlesPerFeed))
            }
            articlesByFeed[feedURL] = existing
            saveArticlesToDisk()
        }
    }

    func setRead(_ isRead: Bool, articleID: String) {
        if isRead {
            readArticleIDs.insert(articleID)
        } else {
            readArticleIDs.remove(articleID)
            recentlyReadArticleIDs.remove(articleID)
            saveRecentlyReadStateToDisk()
        }
        saveReadStateToDisk()
    }

    func isRead(articleID: String) -> Bool {
        readArticleIDs.contains(articleID)
    }

    func summary(articleID: String, matching sourceSignature: String) -> String? {
        guard let stored = articleSummariesByID[articleID],
              stored.sourceSignature == sourceSignature else {
            return nil
        }
        return stored.summary
    }

    func saveSummary(_ summary: String, articleID: String, sourceSignature: String) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }

        if let existing = articleSummariesByID[articleID],
           existing.sourceSignature == sourceSignature,
           existing.summary == trimmedSummary {
            return
        }

        articleSummariesByID[articleID] = StoredArticleSummary(
            sourceSignature: sourceSignature,
            summary: trimmedSummary,
            updatedAt: Date()
        )
        trimStoredSummariesIfNeeded()
        saveSummariesToDisk()
    }

    // MARK: Recently Read Articles
    /// Tracks articles that should continue to appear in the unread flow
    /// until a real refresh promotes them to permanently read.
    func markRecentlyRead(articleID: String) {
        guard !recentlyReadArticleIDs.contains(articleID) else { return }
        recentlyReadArticleIDs.insert(articleID)
        saveRecentlyReadStateToDisk()
    }

    func unmarkRecentlyRead(articleID: String) {
        guard recentlyReadArticleIDs.contains(articleID) else { return }
        recentlyReadArticleIDs.remove(articleID)
        saveRecentlyReadStateToDisk()
    }

    func clearRecentlyRead() {
        guard !recentlyReadArticleIDs.isEmpty else { return }
        recentlyReadArticleIDs.removeAll()
        saveRecentlyReadStateToDisk()
    }

    func isRecentlyRead(articleID: String) -> Bool {
        recentlyReadArticleIDs.contains(articleID)
    }

    @MainActor
    func syncFromCloudIfNeeded() {
        FeedICloudSyncManager.shared.syncDataFromCloudIfNeeded(for: readKey)
        loadFromDisk()
    }

    private func observeCloudSync() {
        let center = NotificationCenter.default

        let readObserver = center.addObserver(
            forName: .feedReadArticleIDsDidSyncFromICloud,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadFromDisk()
        }

        cloudSyncObservers = [readObserver]
    }

    private func trimStoredSummariesIfNeeded() {
        guard articleSummariesByID.count > maxStoredSummaries else { return }

        let retainedEntries = articleSummariesByID
            .sorted { lhs, rhs in
                lhs.value.updatedAt > rhs.value.updatedAt
            }
            .prefix(maxStoredSummaries)

        articleSummariesByID = Dictionary(uniqueKeysWithValues: retainedEntries.map { ($0.key, $0.value) })
    }
}
