import Foundation
import SwiftUI
import Combine

@MainActor
final class MacFeedStore: ObservableObject {
    enum SmartFilter: String, CaseIterable, Identifiable {
        case all
        case unread
        case saved

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "Alle Artikel"
            case .unread: "Ungelesen"
            case .saved: "Gespeichert"
            }
        }

        var systemImage: String {
            switch self {
            case .all: "tray.full"
            case .unread: "circle"
            case .saved: "bookmark"
            }
        }
    }

    struct Selection: Hashable {
        enum Kind: Hashable {
            case smart(SmartFilter)
            case feed(String)
        }

        let kind: Kind

        static let all = Selection(kind: .smart(.all))
    }

    @Published private(set) var feeds: [FeedSource] = []
    @Published private(set) var entries: [FeedEntry] = []
    @Published private(set) var readArticleIDs: Set<String> = []
    @Published private(set) var bookmarkedArticleIDs: Set<String> = []
    @Published var selection: Selection = .all
    @Published var selectedArticleID: String?
    @Published var searchText = ""
    @Published var isRefreshing = false
    @Published var statusMessage: String?
    @Published var addFeedURL = ""

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        FeedStorage.migrateIfNeeded()
        loadPersistedState()
    }

    var selectedArticle: FeedEntry? {
        guard let selectedArticleID else { return nil }
        return entries.first { $0.id == selectedArticleID }
    }

    var visibleEntries: [FeedEntry] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries
            .filter { entry in
                switch selection.kind {
                case .smart(.all):
                    true
                case .smart(.unread):
                    !readArticleIDs.contains(entry.id) || entry.id == selectedArticleID
                case .smart(.saved):
                    bookmarkedArticleIDs.contains(entry.id)
                case .feed(let url):
                    entry.feedURL == url
                }
            }
            .filter { entry in
                guard !search.isEmpty else { return true }
                return entry.displayTitle.localizedCaseInsensitiveContains(search)
                    || entry.content.localizedCaseInsensitiveContains(search)
                    || (entry.sourceTitle?.localizedCaseInsensitiveContains(search) ?? false)
            }
            .sorted { lhs, rhs in
                lhs.parsedPubDate ?? .distantPast > rhs.parsedPubDate ?? .distantPast
            }
    }

    var unreadCount: Int {
        entries.filter { !readArticleIDs.contains($0.id) }.count
    }

    var savedCount: Int {
        entries.filter { bookmarkedArticleIDs.contains($0.id) }.count
    }

    func loadPersistedState() {
        feeds = decode([FeedSource].self, key: FeedStorage.Keys.savedFeeds) ?? []
        entries = mergeFlags(into: decode([FeedEntry].self, key: FeedStorage.Keys.cachedEntries) ?? [])
        readArticleIDs = Set(decode([String].self, key: FeedStorage.Keys.readArticleIDs) ?? [])
        bookmarkedArticleIDs = Set(decode([String].self, key: FeedStorage.Keys.bookmarkedArticleIDs) ?? [])
        entries = mergeFlags(into: entries)
        preserveValidSelection()
    }

    func refreshAllFeeds() {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "Aktualisiere Feeds ..."

        Task {
            var refreshed: [FeedEntry] = []
            var failedFeeds: [String] = []

            await withTaskGroup(of: (FeedSource, Result<[FeedEntry], Error>).self) { group in
                for feed in feeds {
                    group.addTask { [session] in
                        await Self.fetchEntries(for: feed, session: session)
                    }
                }

                for await (feed, result) in group {
                    switch result {
                    case .success(let items):
                        refreshed.append(contentsOf: items)
                    case .failure:
                        failedFeeds.append(feed.title)
                    }
                }
            }

            let merged = mergeRefreshedEntries(refreshed)
            entries = mergeFlags(into: merged)
            persistEntries()
            isRefreshing = false
            statusMessage = failedFeeds.isEmpty
                ? "Zuletzt aktualisiert: \(DateFormatter.localized.string(from: Date()))"
                : "Teilweise aktualisiert: \(failedFeeds.joined(separator: ", "))"
            preserveValidSelection()
        }
    }

    func addFeedFromDraft() {
        let trimmed = addFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            statusMessage = "Feed-URL ist ungültig."
            return
        }

        guard !feeds.contains(where: { $0.url == trimmed }) else {
            addFeedURL = ""
            statusMessage = "Feed ist bereits vorhanden."
            return
        }

        let hostTitle = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Feed"
        feeds.append(FeedSource(title: hostTitle, url: trimmed))
        persistFeeds()
        addFeedURL = ""
        selection = Selection(kind: .feed(trimmed))
        refreshAllFeeds()
    }

    func deleteSelectedFeed() {
        guard case .feed(let url) = selection.kind else { return }
        feeds.removeAll { $0.url == url }
        entries.removeAll { $0.feedURL == url }
        persistFeeds()
        persistEntries()
        selection = .all
        preserveValidSelection()
    }

    func selectNextArticle() {
        moveSelection(offset: 1)
    }

    func selectFirstVisibleArticleIfNeeded() {
        preserveValidSelection()
    }

    func markSelectedArticleReadIfNeeded() {
        guard let selectedArticleID else { return }
        markArticleReadIfNeeded(articleID: selectedArticleID)
    }

    func selectPreviousArticle() {
        moveSelection(offset: -1)
    }

    func toggleRead(_ entry: FeedEntry) {
        if readArticleIDs.contains(entry.id) {
            readArticleIDs.remove(entry.id)
        } else {
            readArticleIDs.insert(entry.id)
        }
        persistStringSet(readArticleIDs, key: FeedStorage.Keys.readArticleIDs)
        entries = mergeFlags(into: entries)
    }

    func markSelectedRead() {
        guard let selectedArticle else { return }
        markArticleReadIfNeeded(articleID: selectedArticle.id)
    }

    func toggleBookmark(_ entry: FeedEntry) {
        if bookmarkedArticleIDs.contains(entry.id) {
            bookmarkedArticleIDs.remove(entry.id)
        } else {
            bookmarkedArticleIDs.insert(entry.id)
        }
        persistStringSet(bookmarkedArticleIDs, key: FeedStorage.Keys.bookmarkedArticleIDs)
    }

    private func moveSelection(offset: Int) {
        let list = visibleEntries
        guard !list.isEmpty else { return }
        guard let selectedArticleID,
              let index = list.firstIndex(where: { $0.id == selectedArticleID }) else {
            self.selectedArticleID = list.first?.id
            return
        }

        let nextIndex = min(max(index + offset, 0), list.count - 1)
        self.selectedArticleID = list[nextIndex].id
        markArticleReadIfNeeded(articleID: list[nextIndex].id)
    }

    private func preserveValidSelection() {
        let list = visibleEntries
        if let selectedArticleID, list.contains(where: { $0.id == selectedArticleID }) {
            markArticleReadIfNeeded(articleID: selectedArticleID)
            return
        }
        selectedArticleID = list.first?.id
        if let selectedArticleID {
            markArticleReadIfNeeded(articleID: selectedArticleID)
        }
    }

    private func markArticleReadIfNeeded(articleID: String) {
        guard !readArticleIDs.contains(articleID) else { return }
        readArticleIDs.insert(articleID)
        persistStringSet(readArticleIDs, key: FeedStorage.Keys.readArticleIDs)
        entries = mergeFlags(into: entries)
    }

    private func mergeRefreshedEntries(_ refreshed: [FeedEntry]) -> [FeedEntry] {
        var byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

        for entry in refreshed {
            byID[entry.id] = entry
        }

        return Array(byID.values)
            .sorted { lhs, rhs in
                lhs.parsedPubDate ?? .distantPast > rhs.parsedPubDate ?? .distantPast
            }
    }

    private func mergeFlags(into rawEntries: [FeedEntry]) -> [FeedEntry] {
        rawEntries.map { entry in
            var copy = entry
            copy.isRead = readArticleIDs.contains(entry.id)
            copy.isNew = !copy.isRead
            return copy
        }
    }

    private static func fetchEntries(
        for feed: FeedSource,
        session: URLSession
    ) async -> (FeedSource, Result<[FeedEntry], Error>) {
        do {
            guard let url = URL(string: feed.url) else {
                throw URLError(.badURL)
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(
                "NewsFeeder Mac/1.0 (macOS; RSS Reader)",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, _) = try await session.data(for: request)
            let result = RSSParser().parseResult(data: data, baseURL: url)
            switch result {
            case .success(let parsed):
                let tagged = parsed.map { entry in
                    FeedEntry(
                        title: entry.title,
                        shortTitle: entry.shortTitle,
                        link: entry.link,
                        content: entry.content,
                        contentRaw: entry.contentRaw,
                        imageURL: entry.imageURL,
                        author: entry.author,
                        sourceTitle: feed.title,
                        feedURL: feed.url,
                        pubDateString: entry.pubDateString,
                        isRead: entry.isRead,
                        isNew: entry.isNew
                    )
                }
                return (feed, .success(tagged))
            case .failure(let error):
                return (feed, .failure(error))
            }
        } catch {
            return (feed, .failure(error))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = FeedCacheSync.bestAvailableData(for: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persistFeeds() {
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        _ = FeedCacheSync.write(data, for: FeedStorage.Keys.savedFeeds)
    }

    private func persistEntries() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        _ = FeedCacheSync.write(data, for: FeedStorage.Keys.cachedEntries)
    }

    private func persistStringSet(_ values: Set<String>, key: String) {
        guard let data = try? JSONEncoder().encode(Array(values).sorted()) else { return }
        _ = FeedCacheSync.write(data, for: key)
    }
}
