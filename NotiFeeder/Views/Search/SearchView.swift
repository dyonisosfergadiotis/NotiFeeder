//
//  SearchView.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.11.25.
//

import Foundation
import SwiftUI
import SwiftData
import Combine

struct SearchView: View {
    @AppStorage("savedFeeds") private var savedFeedsData: Data = Data()
    @State private var feeds: [FeedSource] = []
    @State private var searchText: String = ""
    @State private var snapshotResults: [ArticleSearchResult] = []
    @State private var path: [FeedEntry] = []
    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var store: ArticleStore
    @Environment(\.modelContext) private var modelContext
    @State private var bookmarkedLinks: Set<String> = []

    private var feedLookup: [String: String] {
        Dictionary(uniqueKeysWithValues: feeds.map { ($0.url, $0.title) })
    }

    private var feedSourceMap: [String: FeedSource] {
        Dictionary(uniqueKeysWithValues: feeds.map { ($0.url, $0) })
    }

    private var displayedResults: [ArticleSearchResult] {
        let sorted = snapshotResults.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return sorted }
        return sorted.filter { $0.matches(searchTerm: term) }
    }

    private func rebuildSnapshot() {
        let allResults: [ArticleSearchResult] = store.articlesByFeed.flatMap { feedURL, articles in
            let feedSource = feedSourceMap[feedURL]
            let feedTitle = feedSource?.title ?? feedTitleFromURL(feedURL)
            return articles.map {
                ArticleSearchResult(
                    article: $0,
                    feedTitle: feedTitle,
                    feedURL: feedURL,
                    isRead: store.isRead(articleID: $0.id)
                )
            }
        }
        snapshotResults = allResults
    }
    
    private func toggleReadState(for link: String, currentlyRead: Bool) {
        store.setRead(!currentlyRead, articleID: link)
        rebuildSnapshot()
    }
    
    private func toggleBookmark(for entry: FeedEntry, currentlyBookmarked: Bool) {
        BookmarkService.toggleBookmark(for: entry, context: modelContext)
        if currentlyBookmarked {
            bookmarkedLinks.remove(entry.link)
        } else {
            bookmarkedLinks.insert(entry.link)
        }
    }
    
    private func refreshBookmarksCache() {
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.isBookmarked })
        if let results = try? modelContext.fetch(descriptor) {
            bookmarkedLinks = Set(results.map { $0.link })
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if displayedResults.isEmpty {
                    EmptyResultsView(isSearching: !searchText.isEmpty, accentColor: theme.uiAccentColor)
                        .padding(.horizontal, 24)
                } else {
                    List(displayedResults) { result in
                        let feedColor = theme.color(for: result.feedURL)
                        let isRead = store.isRead(articleID: result.link)
                        let isBookmarked = bookmarkedLinks.contains(result.link)
                        Button {
                            path.append(result.feedEntry)
                        } label: {
                            ArticleCardView(
                                feedTitle: result.feedTitle,
                                feedColor: feedColor,
                                title: result.title,
                                summary: result.summary,
                                isRead: isRead,
                                date: result.publishedAt,
                                isBookmarked: isBookmarked
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                toggleReadState(for: result.link, currentlyRead: isRead)
                            } label: {
                                Label(isRead ? "Als ungelesen" : "Als gelesen",
                                      systemImage: isRead ? "xmark" : "checkmark")
                            }
                            .tint(isRead ? .orange : theme.uiAccentColor)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                toggleBookmark(for: result.feedEntry, currentlyBookmarked: isBookmarked)
                            } label: {
                                Label(isBookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen",
                                      systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
                            }
                            .tint(isBookmarked ? .red : theme.uiAccentColor)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                    .listStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Suche")
            .navigationDestination(for: FeedEntry.self) { entry in
                let color = theme.color(for: entry.sourceTitle.flatMap { title in
                    feeds.first(where: { $0.title == title })?.url
                })
                FeedDetailView(entry: entry, feedColor: color)
            }
        }
        .searchable(text: $searchText, prompt: "Artikel durchsuchen")
        .refreshable { rebuildSnapshot() }
        .onAppear {
            if let decodedFeeds = try? JSONDecoder().decode([FeedSource].self, from: savedFeedsData) {
                feeds = decodedFeeds
            } else {
                feeds = []
            }
            rebuildSnapshot()
            refreshBookmarksCache()
        }
        .onChange(of: feeds) { _ in
            rebuildSnapshot()
        }
        .onChange(of: savedFeedsData) { newData in
            if let decodedFeeds = try? JSONDecoder().decode([FeedSource].self, from: newData) {
                feeds = decodedFeeds
            } else {
                feeds = []
            }
            refreshBookmarksCache()
        }
        .onReceive(store.$readArticleIDs) { _ in
            rebuildSnapshot()
        }
    }

    private func feedTitleFromURL(_ urlString: String) -> String {
        if let host = URL(string: urlString)?.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return "Feed"
    }
}

private struct EmptyResultsView: View {
    let isSearching: Bool
    let accentColor: Color

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: isSearching ? "doc.text.magnifyingglass" : "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(accentColor.opacity(0.8))
            Text(isSearching ? "Keine Artikel gefunden" : "Artikel durchsuchen")
                .appTitle()
                .fontWeight(.semibold)
            Text(isSearching ? "Versuche es mit einem anderen Suchbegriff oder aktualisiere deine Feeds." : "Durchsuche alle geladenen Artikel nach Titeln und Zusammenfassungen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .appSecondary()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct ArticleSearchResult: Identifiable {
    let id: String
    let title: String
    let summary: String?
    let link: String
    let feedTitle: String
    let feedURL: String
    let publishedAt: Date?
    let isRead: Bool

    init(article: StoredFeedArticle, feedTitle: String, feedURL: String, isRead: Bool) {
        self.id = article.id
        self.title = article.title
        self.summary = article.summary
        self.link = article.link
        self.publishedAt = article.publishedAt
        self.feedTitle = article.feedTitle ?? feedTitle
        self.feedURL = feedURL
        self.isRead = isRead
    }

    var feedEntry: FeedEntry {
        let dateString = publishedAt.map { DateFormatter.rfc822.string(from: $0) }

        return FeedEntry(
            title: title,
            shortTitle: title,
            link: link,
            content: summary ?? "",
            author: nil,
            sourceTitle: feedTitle,
            feedURL: feedURL,
            pubDateString: dateString,
            isRead: isRead
        )
    }

    func matches(searchTerm: String) -> Bool {
        let term = searchTerm.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let haystack = [
            title,
            summary ?? "",
            feedTitle
        ].joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return haystack.contains(term)
    }
}
