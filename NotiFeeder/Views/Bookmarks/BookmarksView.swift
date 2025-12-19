//
//  BookmarksView.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.11.25.
//

import SwiftUI
import SwiftData
import Foundation

struct BookmarksView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var store: ArticleStore
    @Query(
        filter: #Predicate<FeedEntryModel> { $0.isBookmarked }
    ) var bookmarkedEntries: [FeedEntryModel]
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage("savedFeeds") private var savedFeedsData: Data = Data()
    @AppStorage("cachedEntries") private var cachedEntriesData: Data = Data() // <-- neu
    @State private var feeds: [FeedSource] = []
    @State private var path: [FeedEntry] = []

    @State private var sortOption: BookmarkSortOption = .addedNewest
    
    // Verwenden Sie eine sortierte Computed Property, die von der sortOption abhängt
    private var sortedBookmarkedEntries: [FeedEntryModel] {
        // Konkretes Array zuerst, dann typannotierte Closures für das Sortieren
        let entries = Array(bookmarkedEntries)

        switch sortOption {
        case .addedNewest:
            return entries.sorted(by: { (a: FeedEntryModel, b: FeedEntryModel) -> Bool in
                return a.date > b.date
            })
        case .addedOldest:
            return entries.sorted(by: { (a: FeedEntryModel, b: FeedEntryModel) -> Bool in
                return a.date < b.date
            })
        case .releaseNewest:
            return entries.sorted(by: { (a: FeedEntryModel, b: FeedEntryModel) -> Bool in
                return releaseDate(for: a) > releaseDate(for: b)
            })
        case .releaseOldest:
            return entries.sorted(by: { (a: FeedEntryModel, b: FeedEntryModel) -> Bool in
                return releaseDate(for: a) < releaseDate(for: b)
            })
        }
    }
    private var sortIconName: String {
        sortOption.iconName
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if sortedBookmarkedEntries.isEmpty { // Verwenden Sie sortedBookmarkedEntries, um leeren Zustand zu prüfen
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark.slash")
                            .font(.system(size: 44))
                            .foregroundStyle(theme.uiAccentColor)
                        Text("Keine Lesezeichen gespeichert")
                            .font(.headline)
                            .foregroundStyle(theme.uiAccentColor)
                        Text("Markierte Artikel werden hier angezeigt")
                            .font(.subheadline)
                            .foregroundStyle(Color(.tertiaryLabel))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 32)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(sortedBookmarkedEntries), id: \.link) { entry in
                                BookmarkEntryRow(
                                    entry: entry,
                                    feeds: $feeds,
                                    path: $path,
                                    cachedEntriesData: cachedEntriesData
                                )
                            } // end ForEach
                        } // end LazyVStack
                    } // end ScrollView
                    .background(Color(.systemGroupedBackground))
                 }
             }
             .navigationTitle("Lesezeichen")
             .toolbar {
                 ToolbarItem(placement: .topBarTrailing) {
                     Menu {
                         Text("Hinzugefügt")
                             .font(.caption2)
                             .foregroundStyle(.secondary)
                         sortButton(for: .addedNewest)
                         sortButton(for: .addedOldest)

                         Divider()

                         Text("Veröffentlicht")
                             .font(.caption2)
                             .foregroundStyle(.secondary)
                         sortButton(for: .releaseNewest)
                         sortButton(for: .releaseOldest)
                     } label: {
                         Label {
                             Text(sortOption.menuTitle)
                         } icon: {
                             Image(systemName: sortIconName)
                         }
                         .labelStyle(.titleAndIcon)
                     }
                     .tint(theme.uiAccentColor)
                 }
             }
             .navigationDestination(for: FeedEntry.self) { entry in
                 let color = theme.color(for: feedForEntry(entry)?.url)
                 FeedDetailView(
                     entry: entry,
                     feedColor: color,
                     entriesProvider: {
                         // Map the currently visible, sorted bookmarks to lightweight FeedEntry list for navigation
                         sortedBookmarkedEntries.map { m in
                             FeedEntry(
                                 title: m.title,
                                 link: m.link,
                                 content: m.content,
                                 author: m.author,
                                 sourceTitle: m.sourceTitle,
                                 feedURL: m.sourceURL,
                                 pubDateString: m.pubDateString,
                                 isRead: store.isRead(articleID: m.link)
                             )
                         }
                     },
                     onNavigateToEntry: { newEntry, _ in
                         withAnimation(.smooth(duration: 0.22)) {
                             if !path.isEmpty {
                                 path[path.count - 1] = newEntry
                             } else {
                                 path.append(newEntry)
                             }
                         }
                     }
                 )
             }
         }
        .onAppear(perform: loadFeeds)
        .onChange(of: savedFeedsData) { _, _ in
            loadFeeds()
        }
    }
}

// --- helper functions moved to file scope extension (must be at file scope) ---
private extension BookmarksView {
    func releaseDate(for entry: FeedEntryModel) -> Date {
        if let pub = entry.pubDateString {
            let parsed = DateParser.parse(pub)
            if parsed != .distantPast { return parsed }
        }
        return entry.date
    }

    func feedForEntry(_ entry: FeedEntry) -> FeedSource? {
        guard
            let articleHost = URL(string: entry.link)?.host,
            let articleDomain = baseDomain(from: articleHost)
        else {
            return feeds.first { $0.title == entry.sourceTitle }
        }

        for feed in feeds {
            let feedHost = URL(string: feed.url)?.host
            if let feedDomain = baseDomain(from: feedHost), feedDomain == articleDomain {
                return feed
            }
        }
        return feeds.first { $0.title == entry.sourceTitle }
    }

    func loadFeeds() {
        if let decodedFeeds = try? JSONDecoder().decode([FeedSource].self, from: savedFeedsData) {
            feeds = decodedFeeds
        } else {
            feeds = []
        }
    }

    func cachedEntry(for link: String) -> FeedEntry? {
        guard !cachedEntriesData.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cached = try? decoder.decode([FeedEntry].self, from: cachedEntriesData) {
            return cached.first { $0.link == link }
        }
        return nil
    }

    func parsePubDate(_ pubDateString: String?) -> Date? {
        guard let s = pubDateString, !s.isEmpty else { return nil }
        let parsed = DateParser.parse(s)
        return (parsed == .distantPast) ? nil : parsed
    }

    func deterministicColor(from string: String) -> Color {
        var hash = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        let hue = Double((abs(hash) % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    func sortButton(for option: BookmarkSortOption) -> some View {
        Button {
            sortOption = option
        } label: {
            HStack {
                Label(option.menuTitle, systemImage: option.iconName)
                if sortOption == option {
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.uiAccentColor)
                }
            }
        }
    }

    func baseDomain(from host: String?) -> String? {
        guard var h = host?.lowercased() else { return nil }
        let prefixes = ["www.", "feeds.", "feed.", "rss."]
        for prefix in prefixes {
            if h.hasPrefix(prefix) {
                h.removeFirst(prefix.count)
                break
            }
        }
        let parts = h.split(separator: ".")
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: ".")
        } else {
            return h
        }
    }
}

// --- moved to file scope so it's visible to the struct and the extension ---
fileprivate enum BookmarkSortOption: String, CaseIterable, Identifiable {
    case addedNewest
    case addedOldest
    case releaseNewest
    case releaseOldest

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .addedNewest: return "Neueste zuerst"
        case .addedOldest: return "Älteste zuerst"
        case .releaseNewest: return "Neueste zuerst"
        case .releaseOldest: return "Älteste zuerst"
        }
    }

    var iconName: String {
        switch self {
        case .addedNewest, .addedOldest: return "bookmark.circle"
        case .releaseNewest, .releaseOldest: return "clock"
        }
    }

    var isDescending: Bool {
        switch self {
        case .addedNewest, .releaseNewest: return true
        case .addedOldest, .releaseOldest: return false
        }
    }
}

// Neue Subview ersetzt die vorherige entryRow-Funktion
private struct BookmarkEntryRow: View {
    let entry: FeedEntryModel
    @Binding var feeds: [FeedSource]
    @Binding var path: [FeedEntry]
    let cachedEntriesData: Data

    @EnvironmentObject private var store: ArticleStore
    @EnvironmentObject private var theme: ThemeSettings
    @Environment(\.modelContext) private var context

    var body: some View {
        // Versuche, vollständigen gecachten Eintrag zu finden (inkl. Bild/Content)
        if let full = cachedEntry(for: entry.link) {
            rowForCached(full, original: entry)
        } else {
            rowForFallback(entry)
        }
    }

    // MARK: - Cached branch
    private func rowForCached(_ detailEntry: FeedEntry, original: FeedEntryModel) -> some View {
        var d = detailEntry
        let feedName = feedForEntry(d)?.title ?? original.sourceTitle ?? "Unbekannte Quelle"
        d.sourceTitle = feedName
        d.feedURL = d.feedURL ?? original.sourceURL
        let matchedFeed = feedForEntry(d)
        let colorSourceURL = matchedFeed?.url ?? d.feedURL
        let feedColor = theme.color(for: colorSourceURL)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                path.append(d)
            } label: {
                ArticleCardView(
                    feedTitle: feedName,
                    feedColor: feedColor,
                    title: d.title,
                    summary: HTMLText.stripHTML(d.content),
                    isRead: store.isRead(articleID: d.link),
                    date: parsePubDate(d.pubDateString) ?? original.date,
                    isBookmarked: true,
                    highlightColor: feedColor
                )
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.setRead(!store.isRead(articleID: original.link), articleID: original.link)
            } label: {
                Image(systemName: store.isRead(articleID: original.link) ? "circle.dashed" : "checkmark.circle")
            }
            .accessibilityLabel("Als gelesen/ungelesen markieren")
            .tint(theme.uiAccentColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                BookmarkService.removeBookmark(link: original.link, context: context)
            } label: {
                Image(systemName: "bookmark.slash")
            }
            .accessibilityLabel("Lesezeichen entfernen")
            .tint(.red)
        }
    }

    // MARK: - Fallback branch
    private func rowForFallback(_ entryModel: FeedEntryModel) -> some View {
        let feedEntry = FeedEntry(
            title: entryModel.title,
            link: entryModel.link,
            content: entryModel.content,
            author: entryModel.author ?? "Unbekannt",
            sourceTitle: entryModel.sourceTitle ?? "Unbekannt",
            feedURL: entryModel.sourceURL,
            pubDateString: entryModel.pubDateString ?? ""
        )
        let matchedFeed = feedForEntry(feedEntry)
        let feedName = matchedFeed?.title ?? entryModel.sourceTitle ?? "Unbekannte Quelle"
        let colorSourceURL = matchedFeed?.url
            ?? feedEntry.feedURL
            ?? feeds.first(where: { $0.title.caseInsensitiveCompare(feedName) == .orderedSame })?.url
        let resolvedColor: Color = {
            if let url = colorSourceURL {
                let c = theme.color(for: url)
                if c != Color.clear { return c }
                return deterministicColor(from: url)
            } else {
                return deterministicColor(from: feedName)
            }
        }()
        let feedColor = resolvedColor
        let detailEntry: FeedEntry = {
            var updated = feedEntry
            updated.sourceTitle = feedName
            updated.feedURL = colorSourceURL
            return updated
        }()
        let displayDate = parsePubDate(entryModel.pubDateString) ?? entryModel.date
        let isRead = store.isRead(articleID: entryModel.link)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                path.append(detailEntry)
            } label: {
                ArticleCardView(
                    feedTitle: feedName,
                    feedColor: feedColor,
                    title: entryModel.title,
                    summary: HTMLText.stripHTML(entryModel.content),
                    isRead: isRead,
                    date: displayDate,
                    isBookmarked: true,
                    highlightColor: feedColor
                )
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.setRead(!isRead, articleID: entryModel.link)
            } label: {
                Image(systemName: isRead ? "circle.dashed" : "checkmark.circle")
            }
            .accessibilityLabel(isRead ? "Als ungelesen markieren" : "Als gelesen markieren")
            .tint(theme.uiAccentColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                BookmarkService.removeBookmark(link: entryModel.link, context: context)
            } label: {
                Image(systemName: "bookmark.slash")
            }
            .accessibilityLabel("Lesezeichen entfernen")
            .tint(.red)
        }
    }

    // MARK: - Small helpers (local to the row)
    private func cachedEntry(for link: String) -> FeedEntry? {
        guard !cachedEntriesData.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cached = try? decoder.decode([FeedEntry].self, from: cachedEntriesData) {
            return cached.first { $0.link == link }
        }
        return nil
    }

    private func parsePubDate(_ pubDateString: String?) -> Date? {
        guard let s = pubDateString, !s.isEmpty else { return nil }
        let parsed = DateParser.parse(s)
        return (parsed == .distantPast) ? nil : parsed
    }

    private func deterministicColor(from string: String) -> Color {
        var hash = 5381
        for byte in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        let hue = Double((abs(hash) % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    private func feedForEntry(_ entry: FeedEntry) -> FeedSource? {
        guard
            let articleHost = URL(string: entry.link)?.host,
            let articleDomain = baseDomain(from: articleHost)
        else {
            return feeds.first { $0.title == entry.sourceTitle }
        }

        for feed in feeds {
            let feedHost = URL(string: feed.url)?.host
            if let feedDomain = baseDomain(from: feedHost), feedDomain == articleDomain {
                return feed
            }
        }
        return feeds.first { $0.title == entry.sourceTitle }
    }

    private func baseDomain(from host: String?) -> String? {
        guard var h = host?.lowercased() else { return nil }
        let prefixes = ["www.", "feeds.", "feed.", "rss."]
        for prefix in prefixes {
            if h.hasPrefix(prefix) {
                h.removeFirst(prefix.count)
                break
            }
        }
        let parts = h.split(separator: ".")
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: ".")
        } else {
            return h
        }
    }
}

