import Foundation
import Combine
import SwiftUI

extension Notification.Name {
    static let feedCachedEntriesDidRefresh = Notification.Name("feedCachedEntriesDidRefresh")
}

private enum TVLocalFeedLayer {
    static let savedFeedsKey = "tv.local.savedFeeds"

    static func savedFeeds(decoder: JSONDecoder) -> [FeedSource] {
        let stores = [FeedStorage.defaults, UserDefaults.standard]
        for store in stores {
            guard let data = store.data(forKey: savedFeedsKey),
                  let feeds = try? decoder.decode([FeedSource].self, from: data),
                  !feeds.isEmpty else {
                continue
            }
            return feeds
        }

        return developmentSeedFeeds
    }

#if targetEnvironment(simulator)
    private static let developmentSeedFeeds: [FeedSource] = [
        FeedSource(title: "Tagesschau", url: "https://www.tagesschau.de/xml/rss2/"),
        FeedSource(title: "Heise Online", url: "https://www.heise.de/rss/heise-atom.xml"),
        FeedSource(title: "Golem.de", url: "https://rss.golem.de/rss.php?feed=RSS2.0")
    ]
#else
    private static let developmentSeedFeeds: [FeedSource] = []
#endif
}

enum TVArticleFilter: Hashable, Identifiable {
    case all
    case unread
    case saved
    case feed(String, String)

    var id: String {
        switch self {
        case .all:
            return "all"
        case .unread:
            return "unread"
        case .saved:
            return "saved"
        case .feed(let url, _):
            return "feed:\(url)"
        }
    }

    var title: String {
        switch self {
        case .all:
            return "Alle Artikel"
        case .unread:
            return "Ungelesen"
        case .saved:
            return "Gespeichert"
        case .feed(_, let title):
            return title
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "newspaper"
        case .unread:
            return "circle"
        case .saved:
            return "bookmark"
        case .feed:
            return "dot.radiowaves.left.and.right"
        }
    }

    var isPrimary: Bool {
        switch self {
        case .all, .unread, .saved:
            return true
        case .feed:
            return false
        }
    }

    var emptyMessage: String {
        switch self {
        case .all:
            return "Aktualisiere deine iCloud-Quellen."
        case .unread:
            return "Alle sichtbaren Artikel sind gelesen."
        case .saved:
            return "Noch keine Artikel gespeichert."
        case .feed:
            return "Diese Quelle hat gerade keine sichtbaren Artikel."
        }
    }

    func matches(feed: FeedSource) -> Bool {
        if case .feed(let url, _) = self {
            return url == feed.url
        }
        return false
    }
}

@MainActor
final class TVArticleStore: ObservableObject {
    @Published private(set) var feeds: [FeedSource] = []
    @Published private(set) var entries: [FeedEntry] = []
    @Published private(set) var readLinks: Set<String> = []
    @Published private(set) var bookmarkedLinks: Set<String> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isUsingLocalFeedLayer = false
    @Published private(set) var feedColorMap: [String: String] = [:]

    private let feedClient = FeedNetworkClient(maxRetries: 1, timeout: 10)
    private let maxCachedEntries = 1500
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var didBootstrap = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        observeExternalStorageChanges()
        loadFromDisk()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var statusHeadline: String {
        if isRefreshing {
            return "Aktualisieren"
        }
        if let statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        return "\(entries.count) Artikel"
    }

    var statusDetail: String? {
        if isRefreshing {
            return isUsingLocalFeedLayer ? "Lokale Quellen" : "iCloud"
        }
        if isUsingLocalFeedLayer {
            guard let lastRefreshDate else { return "Lokal" }
            return "Lokal, \(Self.shortTimeFormatter.string(from: lastRefreshDate))"
        }
        guard let lastRefreshDate else { return nil }
        return "Aktualisiert \(Self.shortTimeFormatter.string(from: lastRefreshDate))"
    }

    var statusText: String {
        if let statusMessage, !statusMessage.isEmpty {
            return statusMessage
        }
        if isRefreshing {
            return "Aktualisiert"
        }
        if isUsingLocalFeedLayer {
            guard let lastRefreshDate else {
                return entries.isEmpty ? "Lokale Quellen" : "\(entries.count) Artikel | Lokal"
            }
            return "\(entries.count) Artikel | Lokal | \(DateFormatter.localized.string(from: lastRefreshDate))"
        }
        guard let lastRefreshDate else {
            return entries.isEmpty ? "Noch nicht aktualisiert" : "\(entries.count) Artikel"
        }
        return "\(entries.count) Artikel | \(DateFormatter.localized.string(from: lastRefreshDate))"
    }

    func feedColor(for feedURL: String?) -> Color {
        guard let feedURL, !feedURL.isEmpty else {
            return TVFeedColorPalette.defaultColors.first ?? .accentColor
        }
        if let hex = feedColorMap[feedURL] {
            return TVFeedColorPalette.color(fromHex: hex)
        }
        return defaultFeedColor(for: feedURL)
    }

    func tintColor(for filter: TVArticleFilter) -> Color {
        switch filter {
        case .feed(let url, _):
            return feedColor(for: url)
        case .all, .unread, .saved:
            if let firstFeedURL = entries.first?.feedURL ?? feeds.first?.url {
                return feedColor(for: firstFeedURL)
            }
            return TVFeedColorPalette.defaultColors.first ?? .accentColor
        }
    }

    static var preview: TVArticleStore {
        let store = TVArticleStore()
        store.feeds = [
            FeedSource(title: "Beispiel", url: "https://example.com/feed")
        ]
        store.entries = [
            FeedEntry(
                title: "Apple TV Reader fuer lange Artikel",
                link: "https://example.com/article",
                content: "Der Reader nutzt dieselben Feed-Daten wie die iOS-App und ist fuer grosse TV-Schrift, klare Navigation und Siri-Remote-Fokus gebaut.",
                sourceTitle: "Beispiel",
                feedURL: "https://example.com/feed",
                pubDateString: "Wed, 24 Jun 2026 12:00:00 GMT"
            )
        ]
        return store
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        FeedStorage.migrateIfNeeded()
        FeedICloudSyncManager.shared.configureIfNeeded()
        FeedCloudKitSyncManager.shared.configureIfNeeded()
        await pullFromCloudAndReload()

        if entries.isEmpty, !feeds.isEmpty {
            await refresh()
        }
    }

    func entries(for filter: TVArticleFilter) -> [FeedEntry] {
        switch filter {
        case .all:
            return entries
        case .unread:
            return entries.filter { !readLinks.contains($0.link) }
        case .saved:
            return entries.filter { bookmarkedLinks.contains($0.link) }
        case .feed(let url, _):
            return entries.filter { $0.feedURL == url }
        }
    }

    func count(for filter: TVArticleFilter) -> Int {
        entries(for: filter).count
    }

    func resolvedEntry(for entry: FeedEntry) -> FeedEntry? {
        entries.first { $0.link == entry.link }
    }

    func isBookmarked(_ entry: FeedEntry) -> Bool {
        bookmarkedLinks.contains(entry.link)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        statusMessage = isUsingLocalFeedLayer ? "Lokale Quellen werden synchronisiert" : "iCloud wird synchronisiert"
        await pullFromCloudAndReload()

        guard !feeds.isEmpty else {
            statusMessage = "Keine Feeds"
            return
        }

        isRefreshing = true
        statusMessage = "Feeds werden geladen"
        defer { isRefreshing = false }

        let feedsSnapshot = feeds
        var freshEntries: [FeedEntry] = []
        var successfulFeeds = 0
        var failedFeeds: [String] = []

        for feed in feedsSnapshot {
            let status = await feedClient.fetch(feed: feed)
            if status.error == nil {
                successfulFeeds += 1
            } else {
                failedFeeds.append(feed.title)
            }

            let enriched = status.entries.map { entry -> FeedEntry in
                var copy = entry
                if copy.sourceTitle == nil {
                    copy.sourceTitle = feed.title
                }
                if copy.feedURL == nil {
                    copy.feedURL = feed.url
                }
                return copy
            }
            freshEntries.append(contentsOf: enriched)
        }

        let merged = mergeEntries(
            cachedEntries: loadCachedEntries(),
            freshEntries: freshEntries,
            readIDs: readLinks,
            activeFeedURLs: Set(feedsSnapshot.map(\.url))
        )
        entries = merged
        persistCachedEntries(merged, uploadToCloud: true)

        if successfulFeeds > 0 {
            lastRefreshDate = Date()
            persistLastRefreshDate(lastRefreshDate)
            statusMessage = nil
        } else if !failedFeeds.isEmpty {
            statusMessage = "Feeds konnten nicht geladen werden"
        } else {
            statusMessage = "Keine neuen Artikel"
        }
    }

    func markRead(_ entry: FeedEntry) {
        setRead(true, for: entry)
    }

    func toggleRead(_ entry: FeedEntry) {
        setRead(!readLinks.contains(entry.link), for: entry)
    }

    func toggleBookmark(_ entry: FeedEntry) {
        if bookmarkedLinks.contains(entry.link) {
            bookmarkedLinks.remove(entry.link)
        } else {
            bookmarkedLinks.insert(entry.link)
        }
        persistBookmarkedLinks()
    }

    private func setRead(_ isRead: Bool, for entry: FeedEntry) {
        let changed: Bool
        if isRead {
            changed = readLinks.insert(entry.link).inserted
        } else {
            changed = readLinks.remove(entry.link) != nil
        }
        guard changed else { return }

        if let index = entries.firstIndex(where: { $0.link == entry.link }) {
            entries[index].isRead = isRead
            if isRead {
                entries[index].isNew = false
            }
        }
        persistReadLinks()
        persistCachedEntries(entries, uploadToCloud: true)
    }

    private func loadFromDisk() {
        FeedStorage.migrateIfNeeded()
        for key in [
            FeedStorage.Keys.savedFeeds,
            FeedStorage.Keys.cachedEntries,
            FeedStorage.Keys.readArticleIDs,
            FeedStorage.Keys.bookmarkedArticleIDs,
            FeedStorage.Keys.feedColorMap
        ] {
            FeedCacheSync.syncIfNeeded(for: key)
        }

        let savedFeeds = loadSavedFeeds()
        feeds = savedFeeds.feeds
        isUsingLocalFeedLayer = savedFeeds.usesLocalLayer
        readLinks = loadStringSet(for: FeedStorage.Keys.readArticleIDs)
        bookmarkedLinks = loadStringSet(for: FeedStorage.Keys.bookmarkedArticleIDs)
        feedColorMap = loadFeedColorMap()
        entries = mergeEntries(
            cachedEntries: loadCachedEntries(),
            freshEntries: [],
            readIDs: readLinks,
            activeFeedURLs: Set(feeds.map(\.url))
        )
        lastRefreshDate = loadLastRefreshDate()
    }

    private func loadSavedFeeds() -> (feeds: [FeedSource], usesLocalLayer: Bool) {
        guard let data = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.savedFeeds)
                ?? FeedStorage.defaults.data(forKey: FeedStorage.Keys.savedFeeds),
              let decoded = try? decoder.decode([FeedSource].self, from: data) else {
            let localFeeds = TVLocalFeedLayer.savedFeeds(decoder: decoder)
            return (localFeeds, !localFeeds.isEmpty)
        }

        let deletedURLs = FeedStorage.deletedFeedURLs()
        let cloudFeeds = decoded.filter { !deletedURLs.contains($0.url) }
        guard !cloudFeeds.isEmpty else {
            let localFeeds = TVLocalFeedLayer.savedFeeds(decoder: decoder)
            return (localFeeds, !localFeeds.isEmpty)
        }
        return (cloudFeeds, false)
    }

    private func loadCachedEntries() -> [FeedEntry] {
        guard let data = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.cachedEntries)
                ?? FeedStorage.defaults.data(forKey: FeedStorage.Keys.cachedEntries),
              let decoded = try? decoder.decode([FeedEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private func loadFeedColorMap() -> [String: String] {
        guard let data = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.feedColorMap)
                ?? FeedStorage.defaults.data(forKey: FeedStorage.Keys.feedColorMap),
              let decoded = try? decoder.decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func loadStringSet(for key: String) -> Set<String> {
        guard let data = FeedCacheSync.bestAvailableData(for: key)
                ?? FeedStorage.defaults.data(forKey: key),
              let decoded = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    private func defaultFeedColor(for feedURL: String) -> Color {
        let palette = TVFeedColorPalette.defaultColors
        guard !palette.isEmpty else { return .accentColor }
        let index = abs(feedURL.hashValue % palette.count)
        return palette[index]
    }

    private func persistReadLinks() {
        guard let data = try? encoder.encode(readLinks.sorted()) else { return }
        let token = FeedCacheSync.write(data, for: FeedStorage.Keys.readArticleIDs)
        FeedCloudKitSyncManager.shared.uploadLocalData(
            data,
            token: token,
            for: FeedStorage.Keys.readArticleIDs
        )
    }

    private func persistBookmarkedLinks() {
        guard let data = try? encoder.encode(bookmarkedLinks.sorted()) else { return }
        let token = FeedCacheSync.write(data, for: FeedStorage.Keys.bookmarkedArticleIDs)
        FeedCloudKitSyncManager.shared.uploadLocalData(
            data,
            token: token,
            for: FeedStorage.Keys.bookmarkedArticleIDs
        )
    }

    private func persistCachedEntries(_ entries: [FeedEntry], uploadToCloud: Bool) {
        guard let data = try? encoder.encode(entries) else { return }
        let token = FeedCacheSync.write(data, for: FeedStorage.Keys.cachedEntries)
        guard uploadToCloud else { return }
        FeedCloudKitSyncManager.shared.uploadLocalData(
            data,
            token: token,
            for: FeedStorage.Keys.cachedEntries
        )
    }

    private func mergeEntries(
        cachedEntries: [FeedEntry],
        freshEntries: [FeedEntry],
        readIDs: Set<String>,
        activeFeedURLs: Set<String>
    ) -> [FeedEntry] {
        var merged: [FeedEntry] = []
        var indexByLink: [String: Int] = [:]

        func appendOrUpdate(_ rawEntry: FeedEntry, preferIncomingDetails: Bool) {
            var entry = rawEntry
            if let feedURL = entry.feedURL, !activeFeedURLs.isEmpty, !activeFeedURLs.contains(feedURL) {
                return
            }
            entry.isRead = readIDs.contains(entry.link)
            if entry.isRead {
                entry.isNew = false
            }

            if let existingIndex = indexByLink[entry.link] {
                guard preferIncomingDetails else { return }
                var existing = merged[existingIndex]
                existing.title = entry.title
                existing.shortTitle = entry.shortTitle
                existing.content = entry.content
                existing.contentRaw = entry.contentRaw
                existing.imageURL = entry.imageURL
                existing.author = entry.author
                existing.sourceTitle = entry.sourceTitle ?? existing.sourceTitle
                existing.feedURL = entry.feedURL ?? existing.feedURL
                existing.pubDateString = entry.pubDateString ?? existing.pubDateString
                existing.isRead = entry.isRead
                existing.isNew = entry.isNew
                merged[existingIndex] = existing
                return
            }

            indexByLink[entry.link] = merged.count
            merged.append(entry)
        }

        for entry in cachedEntries {
            appendOrUpdate(entry, preferIncomingDetails: false)
        }
        for entry in freshEntries {
            appendOrUpdate(entry, preferIncomingDetails: true)
        }

        merged.sort { lhs, rhs in
            let lhsDate = DateParser.parse(lhs.pubDateString)
            let rhsDate = DateParser.parse(rhs.pubDateString)
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        if merged.count > maxCachedEntries {
            merged = Array(merged.prefix(maxCachedEntries))
        }

        return merged
    }

    private func loadLastRefreshDate() -> Date? {
        let key = FeedStorage.Keys.lastSuccessfulFeedRefresh
        let timestamp = max(
            FeedStorage.defaults.double(forKey: key),
            UserDefaults.standard.double(forKey: key)
        )
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func persistLastRefreshDate(_ date: Date?) {
        guard let date else { return }
        let timestamp = date.timeIntervalSince1970
        FeedStorage.defaults.set(timestamp, forKey: FeedStorage.Keys.lastSuccessfulFeedRefresh)
        UserDefaults.standard.set(timestamp, forKey: FeedStorage.Keys.lastSuccessfulFeedRefresh)
    }

    private func observeExternalStorageChanges() {
        let names: [Notification.Name] = [
            .feedSavedFeedsDidSyncFromICloud,
            .feedReadArticleIDsDidSyncFromICloud,
            .feedBookmarkedArticleIDsDidSyncFromICloud,
            .feedCachedEntriesDidRefresh,
            .feedSavedArticlesDidSyncFromCloudKit,
            .feedColorMapDidSyncFromICloud
        ]

        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.loadFromDisk()
                }
            }
        }
    }

    private func pullFromCloudAndReload() async {
        FeedICloudSyncManager.shared.syncAllFromCloudIfNeeded()
        await FeedCloudKitSyncManager.shared.syncAllFromCloudIfPossible()
        loadFromDisk()
    }

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

private enum TVFeedColorPalette {
    static let defaultColors: [Color] = [
        color(fromHex: "#FF9EB5"),
        color(fromHex: "#FFB38A"),
        color(fromHex: "#FFE16B"),
        color(fromHex: "#B8E85A"),
        color(fromHex: "#7EE7B8"),
        color(fromHex: "#6FE7E7"),
        color(fromHex: "#89B8FF"),
        color(fromHex: "#C0A6FF"),
        color(fromHex: "#FF9BE8")
    ]

    static func color(fromHex hex: String) -> Color {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let red: UInt64
        let green: UInt64
        let blue: UInt64

        switch sanitized.count {
        case 6:
            red = (value >> 16) & 0xFF
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
        default:
            red = 128
            green = 128
            blue = 128
        }

        return Color(
            .sRGB,
            red: Double(red) / 255.0,
            green: Double(green) / 255.0,
            blue: Double(blue) / 255.0,
            opacity: 1
        )
    }
}

extension FeedEntry {
    var previewText: String {
        let content = self.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            return content
        }

        if let raw = contentRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return HTMLText.stripHTML(raw)
        }

        return "Kein Vorschautext"
    }
}
