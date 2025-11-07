//
//  BookmarksView.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.11.25.
//

import SwiftUI
import SwiftData
import Foundation

struct BookmarksView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var store: ArticleStore
    @Query(
        filter: #Predicate<FeedEntryModel> { $0.isBookmarked },
        sort: [SortDescriptor<FeedEntryModel>(\.date, order: .reverse)]
    ) var bookmarkedEntries: [FeedEntryModel]
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage("savedFeeds") private var savedFeedsData: Data = Data()
    @State private var feeds: [FeedSource] = []
    @State private var path: [FeedEntry] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if bookmarkedEntries.isEmpty {
                    Text("Noch keine Lesezeichen vorhanden.")
                        .foregroundColor(.secondary)
                        .navigationTitle("Lesezeichen")
                } else {
                    List(bookmarkedEntries) { entry in
                        let feedEntry = FeedEntry(
                            title: entry.title,
                            link: entry.link,
                            content: entry.content,
                            author: entry.author ?? "Unbekannt",
                            sourceTitle: entry.sourceTitle ?? "Unbekannt",
                            pubDateString: entry.pubDateString ?? ""
                        )
                    let matchedFeed = feedForEntry(feedEntry)
                    let feedColor = theme.color(for: matchedFeed?.url)
                    let feedName = matchedFeed?.title ?? entry.sourceTitle ?? "Unbekannte Quelle"
                    let detailEntry: FeedEntry = {
                        var updated = feedEntry
                            updated.sourceTitle = feedName
                            return updated
                        }()
                    let entryDate = entry.pubDateString.flatMap { DateFormatter.rfc822.date(from: $0) }
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
                            date: entryDate
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
                            Label(isRead ? "Als ungelesen" : "Als gelesen",
                                  systemImage: isRead ? "xmark" : "checkmark")
                        }
                        .tint(isRead ? .orange : theme.uiAccentColor)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            BookmarkService.removeBookmark(link: entry.link, context: context)
                        } label: {
                            Label("Lesezeichen entfernen", systemImage: "bookmark.slash")
                        }
                    }
                }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                    .navigationTitle("Lesezeichen")
                }
            }
            .navigationDestination(for: FeedEntry.self) { entry in
                let color = theme.color(for: feedForEntry(entry)?.url)
                FeedDetailView(entry: entry, feedColor: color)
            }
        }
        .onAppear(perform: loadFeeds)
        .onChange(of: savedFeedsData) { _ in
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
