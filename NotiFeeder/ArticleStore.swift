// ArticleStore.swift
// Persistent storage for articles and read-state using UserDefaults.
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

public struct StoredFeedSource: Codable, Hashable, Identifiable {
    public var id: String { url }
    public let title: String
    public let url: String
}

// MARK: - ArticleStore
final class ArticleStore: ObservableObject {
    static let shared = ArticleStore()

    // Persisted keys
    private let articlesKey = "savedArticles"
    private let readKey = "readArticleIDs"

    // In-memory cache
    @Published private(set) var articlesByFeed: [String: [StoredFeedArticle]] = [:] // key: feed URL
    @Published private(set) var readArticleIDs: Set<String> = []

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let queue = DispatchQueue(label: "ArticleStore.queue", qos: .utility)

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        loadFromDisk()
    }

    // MARK: Persistence
    private func loadFromDisk() {
        // Load articles
        if let data = defaults.data(forKey: articlesKey),
           let loaded = try? decoder.decode([String: [StoredFeedArticle]].self, from: data) {
            self.articlesByFeed = loaded
        }
        // Load read-state
        if let data = defaults.data(forKey: readKey),
           let loaded = try? decoder.decode([String].self, from: data) {
            self.readArticleIDs = Set(loaded)
        }
    }

    private func saveArticlesToDisk() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let data = try? self.encoder.encode(self.articlesByFeed) {
                self.defaults.set(data, forKey: self.articlesKey)
            }
        }
    }

    private func saveReadStateToDisk() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let array = Array(self.readArticleIDs)
            if let data = try? self.encoder.encode(array) {
                self.defaults.set(data, forKey: self.readKey)
            }
        }
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
            articlesByFeed[feedURL] = existing
            saveArticlesToDisk()
        }
    }

    func setRead(_ isRead: Bool, articleID: String) {
        if isRead { readArticleIDs.insert(articleID) } else { readArticleIDs.remove(articleID) }
        saveReadStateToDisk()
    }

    func isRead(articleID: String) -> Bool {
        readArticleIDs.contains(articleID)
    }
}
