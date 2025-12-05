//
//  BookmarksView.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.11.25.
//

import SwiftUI
import SwiftData
import Foundation

private enum BookmarkSortOption: String, CaseIterable, Identifiable {
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

struct BookmarksView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var store: ArticleStore
    @Query(
        filter: #Predicate<FeedEntryModel> { $0.isBookmarked },
        // Die initiale Abfrage sortiert nach dem Hinzufügedatum (date) in umgekehrter Reihenfolge,
        // da dies der Standard-Sortieroption (.addedNewest) am nächsten kommt.
        sort: [SortDescriptor<FeedEntryModel>(\.date, order: .reverse)]
    ) var bookmarkedEntries: [FeedEntryModel]
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage("savedFeeds") private var savedFeedsData: Data = Data()
    @State private var feeds: [FeedSource] = []
    @State private var path: [FeedEntry] = []

    @State private var sortOption: BookmarkSortOption = .addedNewest
    
    // Verwenden Sie eine sortierte Computed Property, die von der sortOption abhängt
    private var sortedBookmarkedEntries: [FeedEntryModel] {
        switch sortOption {
        case .addedNewest:
            // .date ist das Hinzufügedatum in FeedEntryModel
            return bookmarkedEntries.sorted { $0.date > $1.date }
        case .addedOldest:
            return bookmarkedEntries.sorted { $0.date < $1.date }
        case .releaseNewest:
            // Sortieren nach dem tatsächlichen Veröffentlichungsdatum
            return bookmarkedEntries.sorted { releaseDate(for: $0) > releaseDate(for: $1) }
        case .releaseOldest:
            return bookmarkedEntries.sorted { releaseDate(for: $0) < releaseDate(for: $1) }
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
                    List(sortedBookmarkedEntries) { entry in // Verwenden Sie die sortierte Liste
                        let feedEntry = FeedEntry(
                            title: entry.title,
                            link: entry.link,
                            content: entry.content,
                            author: entry.author ?? "Unbekannt",
                            sourceTitle: entry.sourceTitle ?? "Unbekannt",
                            feedURL: entry.sourceURL,
                            pubDateString: entry.pubDateString ?? ""
                        )
                        let matchedFeed = feedForEntry(feedEntry)
                        let feedName = matchedFeed?.title ?? entry.sourceTitle ?? "Unbekannte Quelle"
                        let colorSourceURL = matchedFeed?.url
                            ?? feedEntry.feedURL
                            ?? feeds.first(where: { $0.title.caseInsensitiveCompare(feedName) == .orderedSame })?.url
                        let resolvedColor: Color = {
                            if let url = colorSourceURL {
                                let c = theme.color(for: url)
                                // If ThemeSettings returns a very light default (heuristic), keep it; otherwise, use it.
                                // To be robust, provide a deterministic fallback based on URL hash if needed.
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
                        // Verwenden Sie den robusten Parser für die Anzeige und für releaseDate()
                        let entryDate = (entry.pubDateString).map { DateParser.parse($0) }
                        let displayDate: Date? = (entryDate == Date.distantPast ? nil : entryDate)
                        let isRead = store.isRead(articleID: entry.link)

                        Button {
                            path.append(detailEntry)
                        } label: {
                            ArticleCardView(
                                feedTitle: feedName,
                                feedColor: feedColor,
                                title: entry.title,
                                summary: nil,
                                isRead: isRead,
                                date: displayDate,
                                isBookmarked: true
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                store.setRead(!isRead, articleID: entry.link)
                            } label: {
                                Image(systemName: isRead ? "circle.dashed" : "checkmark.circle")
                            }
                            .accessibilityLabel(isRead ? "Als ungelesen markieren" : "Als gelesen markieren")
                            .tint(theme.uiAccentColor)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                BookmarkService.removeBookmark(link: entry.link, context: context)
                            } label: {
                                Image(systemName: "bookmark.slash")
                            }
                            .accessibilityLabel("Lesezeichen entfernen")
                            .tint(.red)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Lesezeichen")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
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
                        Label(sortOption.menuTitle, systemImage: sortIconName)
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(theme.uiAccentColor)
                }
            }
            .navigationDestination(for: FeedEntry.self) { entry in
                let color = theme.color(for: feedForEntry(entry)?.url)
                FeedDetailView(entry: entry, feedColor: color)
            }
        }
        .onAppear(perform: loadFeeds)
        .onChange(of: savedFeedsData) { _, _ in
            loadFeeds()
        }
    }
}

private extension BookmarksView {
    func loadFeeds() {
        if let decodedFeeds = try? JSONDecoder().decode([FeedSource].self, from: savedFeedsData) {
            feeds = decodedFeeds
        } else {
            feeds = []
        }
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

    func releaseDate(for entry: FeedEntryModel) -> Date {
        if let pub = entry.pubDateString {
            let parsed = DateParser.parse(pub)
            if parsed != .distantPast { return parsed }
        }
        return entry.date
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
    
    func deterministicColor(from string: String) -> Color {
        var hasher = Hasher()
        hasher.combine(string)
        let value = hasher.finalize()
        // Map hash to hue in [0,1]
        let hue = Double(abs(value % 360)) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }
}
