import SwiftUI
import Foundation
import FoundationModels
import SwiftData

struct ContentView: View {
    @AppStorage("savedFeeds") private var savedFeedsData: Data = Data()
    @AppStorage("cachedEntries") private var cachedEntriesData: Data = Data()
    @State private var feeds: [FeedSource] = []
    @EnvironmentObject private var theme: ThemeSettings
    
    var body: some View {
        TabView {
            Tab("Feed", systemImage: "list.bullet") {
                FeedListView(feeds: $feeds, savedFeedsData: $savedFeedsData)
            }
            
            Tab(role: .search) {
                SearchView()
            }
            
            Tab("Lesezeichen", systemImage: "bookmark") {
                BookmarksView()
            }
            
            Tab("Einstellungen", systemImage: "gear") {
                SettingsView(feeds: $feeds, savedFeedsData: $savedFeedsData)
            }
        }
        .tabViewStyle(.automatic)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(theme.uiAccentColor)
        .onAppear {
            loadFeeds()
        }
    }
    
    func loadFeeds() {
        if let decoded = try? JSONDecoder().decode([FeedSource].self, from: savedFeedsData) {
            feeds = decoded
        } else {
            // Beispiel-Feed, wenn leer
            feeds = [FeedSource(title: "MacRumors", url: "https://feeds.macrumors.com/MacRumors-All"),FeedSource(title: "UFC", url: "https://ufc.tu-dortmund.de/feed")]
        }
    }
}

struct FeedListView: View {
    @Binding var feeds: [FeedSource]
    @Binding var savedFeedsData: Data
    @EnvironmentObject private var store: ArticleStore
    @EnvironmentObject private var theme: ThemeSettings
    @Environment(\.modelContext) private var modelContext
    @AppStorage("cachedEntries") private var cachedEntriesData: Data = Data()
    @AppStorage("notificationFeedPreferences") private var notificationFeedPreferencesData: Data = Data()
    @AppStorage("notificationsEnabledPreference") private var notificationsEnabledPreference: Bool = true
    
    @State private var entries: [FeedEntry] = []
    @State private var isLoading = false
    @State private var sortOption = "Neueste zuerst"
    @State private var showReadEntries = false
    @State private var didTriggerInitialLoad = false
    @State private var path: [FeedEntry] = []
    @State private var didRestoreCachedEntries = false

    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var lastRefreshDate: Date? = nil
    @State private var bookmarkedLinks: Set<String> = []

    private let maxArticlesPerFeed = 100
    private var sortIconName: String {
        sortOption == "Neueste zuerst" ? "arrow.down.circle" : "arrow.up.circle"
    }
    
    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(filteredEntries) { entry in
                    entryRow(for: entry)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .listRowSpacing(6)
            .background(Color(.systemGroupedBackground))
            .overlay {
                if filteredEntries.isEmpty {
                    EmptyFeedView()
                        .environmentObject(theme)
                        .padding(.horizontal, 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .animation(.easeInOut(duration: 0.2), value: filteredEntries.isEmpty)
                }
            }
            .refreshable {
                // Cancel a previous refresh if still running
                refreshTask?.cancel()
                let now = Date()
                if let last = lastRefreshDate, now.timeIntervalSince(last) < 0.4 {
                    // Debounce very fast repeated pulls
                    return
                }
                lastRefreshDate = now

                refreshTask = Task { @MainActor in
                    // Small, consistent delay for nicer pull-to-refresh feel
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    _ = withTransaction(Transaction(animation: .easeInOut(duration: 0.22))) {
                        Task { await loadRSSFeed() }
                    }
                }
                await refreshTask?.value
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if hasUnread {
                        Button {
                            markAllAsRead()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .tint(theme.uiAccentColor)
                        .accessibilityLabel("Alle ungelesenen als gelesen markieren")
                    }

                    Button {
                        showReadEntries.toggle()
                    } label: {
                        Image(systemName: showReadEntries ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .contentTransition(.symbolEffect)
                    .animation(.easeInOut(duration: 0.2), value: showReadEntries)
                    .tint(theme.uiAccentColor)
                    .accessibilityLabel(showReadEntries ? "Gelesene ausblenden" : "Gelesene anzeigen")

                    Menu {
                        Button {
                            guard sortOption != "Neueste zuerst" else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sortOption = "Neueste zuerst"
                            }
                        } label: {
                            Label("Neueste zuerst", systemImage: "arrow.down.circle")
                                .labelStyle(.titleAndIcon)
                        }
                        Button {
                            guard sortOption != "Älteste zuerst" else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sortOption = "Älteste zuerst"
                            }
                        } label: {
                            Label("Älteste zuerst", systemImage: "arrow.up.circle")
                                .labelStyle(.titleAndIcon)
                        }
                    } label: {
                        Image(systemName: sortIconName)
                    }
                    .tint(theme.uiAccentColor)
                }
            }
            .navigationDestination(for: FeedEntry.self) { entry in
                FeedDetailView(entry: entry,
                               feedColor: feedColor(for: feedSource(for: entry)?.url),
                               onAppearMarkRead: {
                    markAsRead(entry)
                })
            }
        }
        .onAppear {
            if !didRestoreCachedEntries {
                didRestoreCachedEntries = true
                restoreCachedEntries()
            }
            triggerInitialLoadIfPossible()
            Task { @MainActor in
                refreshBookmarkedLinks()
            }
        }
        .onChange(of: sortOption) { oldValue, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                applySorting()
            }
        }
        .onChange(of: feeds) { oldValue, newValue in
            triggerInitialLoadIfPossible()
        }
        .onChange(of: showReadEntries) { oldValue, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                // Trigger list diffing animation on filteredEntries changes
            }
        }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay nötig, sonst zu früh
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .forEach { scene in
                        scene.windows.first?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
                    }
            }
        }
    }

    @ViewBuilder
    private func entryRow(for entry: FeedEntry) -> some View {
        let matchedFeed = feedSource(for: entry)
        let feedName = matchedFeed?.title ?? feedTitle(for: entry)
        let rowFeedColor = feedColor(for: matchedFeed?.url)
        let entryDateValue = entryDate(for: entry)
        let strippedSummary = HTMLText.stripHTML(entry.content)
        let detailEntry: FeedEntry = {
            var updated = entry
            updated.sourceTitle = feedName
            updated.feedURL = matchedFeed?.url
            return updated
        }()
        let isBookmarked = bookmarkedLinks.contains(detailEntry.link)

        Button {
            path.append(detailEntry)
        } label: {
            ArticleCardView(
                feedTitle: feedName,
                feedColor: rowFeedColor,
                title: entry.title,
                summary: strippedSummary,
                isRead: entry.isRead,
                date: entryDateValue,
                isBookmarked: isBookmarked,
                highlightColor: rowFeedColor
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if entry.isRead {
                Button {
                    markAsUnread(entry)
                } label: {
                    Image(systemName: "circle.dashed")
                }
                .accessibilityLabel("Als ungelesen markieren")
                .tint(theme.uiSwipeColor)
            } else {
                Button {
                    markAsRead(entry)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .accessibilityLabel("Als gelesen markieren")
                .tint(theme.uiSwipeColor)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                toggleBookmark(for: detailEntry, isCurrentlyBookmarked: isBookmarked)
            } label: {
                Image(systemName: isBookmarked ? "bookmark.slash" : "bookmark")
            }
            .accessibilityLabel(isBookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen")
            .tint(isBookmarked ? .red : theme.uiSwipeColor)
        }
    }

    private func triggerInitialLoadIfPossible() {
        guard !didTriggerInitialLoad else { return }
        guard !feeds.isEmpty else { return }
        didTriggerInitialLoad = true
        Task {
            await loadRSSFeed()
        }
    }
    
    private func feedColor(for url: String?) -> Color {
        // Return a color without causing any side effects during view updates.
        // If ThemeSettings.color(for:) is pure, delegate to it; otherwise, provide a safe fallback.
        // We defensively avoid optional-chaining into theme to ensure no mutations happen here.
        if let url = url {
            // Assume ThemeSettings.color(for:) is a pure function; if not, this wrapper is the single place to adjust.
            return theme.color(for: url)
        } else {
            return theme.uiAccentColor.opacity(0.35)
        }
    }
}

// MARK: - Feed Management Logic

extension FeedListView {
    @MainActor
    func loadRSSFeed() async {
        isLoading = true

        var feedURLByLink: [String: String] = [:]

        let feedsSnapshot = feeds
        var newEntries: [FeedEntry] = []

        await withTaskGroup(of: (FeedSource, [FeedEntry]).self) { group in
            for feed in feedsSnapshot {
                group.addTask {
                    let entries = await fetchFeed(feed)
                    return (feed, entries)
                }
            }

            for await (feed, result) in group {
                let enrichedEntries: [FeedEntry] = result.map { entry in
                    var enriched = entry
                    if enriched.sourceTitle == nil {
                        enriched.sourceTitle = feed.title
                    }
                    if enriched.feedURL == nil {
                        enriched.feedURL = feed.url
                    }
                    return enriched
                }

                if !enrichedEntries.isEmpty {
                    let storedArticles = enrichedEntries.map { entry in
                        StoredFeedArticle(
                            title: entry.title,
                            link: entry.link,
                            publishedAt: entry.pubDateString.flatMap { DateFormatter.rfc822.date(from: $0) },
                            summary: HTMLText.stripHTML(entry.content),
                            feedTitle: feed.title
                        )
                    }
                    store.mergeArticles(storedArticles, for: feed.url)
                }

                for entry in enrichedEntries {
                    feedURLByLink[entry.link] = entry.feedURL ?? feed.url
                }

                newEntries.append(contentsOf: enrichedEntries)
            }
        }

        withTransaction(Transaction(animation: .easeInOut(duration: 0.2))) {
            for newEntry in newEntries {
                if let existingIndex = entries.firstIndex(where: { $0.link == newEntry.link }) {
                    var existing = entries[existingIndex]
                    existing.title = newEntry.title
                    existing.content = newEntry.content
                    existing.imageURL = newEntry.imageURL
                    existing.author = newEntry.author
                    existing.pubDateString = newEntry.pubDateString
                    existing.feedURL = newEntry.feedURL ?? existing.feedURL
                    existing.sourceTitle = newEntry.sourceTitle ?? existing.sourceTitle
                    entries[existingIndex] = existing
                    entries[existingIndex].isRead = store.isRead(articleID: entries[existingIndex].link)
                } else {
                    var fresh = newEntry
                    fresh.isRead = store.isRead(articleID: fresh.link)
                    entries.append(fresh)
                }
            }
        }

        enforceArticleLimit(feedURLByLink: feedURLByLink)
        persistEntriesCache()

        let hadTrackedEntries = NotificationDeliveryTracker.hasTrackedArticles()
        let brandNewEntries = NotificationDeliveryTracker.markAndReturnNew(entries: newEntries)
        let enabledFeeds = enabledNotificationFeedURLs()
        let feedsByURL = Dictionary(uniqueKeysWithValues: feeds.map { ($0.url, $0) })
        let eligibleEntries = brandNewEntries.filter { entry in
            guard !enabledFeeds.isEmpty else { return false }
            let feedURL = feedURLByLink[entry.link] ?? feedSource(for: entry)?.url
            guard let feedURL else { return true }
            return enabledFeeds.contains(feedURL)
        }

        if notificationsEnabledPreference && hadTrackedEntries && !eligibleEntries.isEmpty {
            let entriesToNotify = eligibleEntries
            NotificationScheduler.shared.requestAuthorizationIfNeeded { granted in
                guard granted else { return }
                for entry in entriesToNotify {
                    let feedURL = feedURLByLink[entry.link] ?? feedSource(for: entry)?.url
                    let feedTitle = feedURL.flatMap { feedsByURL[$0]?.title } ?? feedSource(for: entry)?.title
                    var enrichedEntry = entry
                    enrichedEntry.sourceTitle = feedTitle
                    enrichedEntry.feedURL = feedURL
                    NotificationScheduler.shared.scheduleArticleNotification(for: enrichedEntry, feedTitle: feedTitle)
                }
            }
        }

        isLoading = false
        Task { @MainActor in
            refreshBookmarkedLinks()
        }
    }

    func fetchFeed(_ feed: FeedSource) async -> [FeedEntry] {
        guard let url = URL(string: feed.url) else { return [] }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12 // Sekunden
            let (data, _) = try await URLSession.shared.data(for: request)
            let parser = RSSParser()
            return parser.parse(data: data)
        } catch {
            print("Fehler beim Laden: \(error)")
            return []
        }
    }

    @MainActor
    func applySorting() {
        switch sortOption {
        case "Neueste zuerst":
            entries.sort { lhs, rhs in
                let ld = lhs.pubDateString.flatMap { DateFormatter.rfc822.date(from: $0) }
                let rd = rhs.pubDateString.flatMap { DateFormatter.rfc822.date(from: $0) }
                switch (ld, rd) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
                }
            }
        default: // Älteste zuerst
            entries.sort { lhs, rhs in
                let ld = lhs.pubDateString.flatMap { DateFormatter.rfc822.date(from: $0) }
                let rd = rhs.pubDateString.flatMap { DateFormatter.rfc822.date(from: $0) }
                switch (ld, rd) {
                case let (l?, r?): return l < r
                case (_?, nil): return false
                case (nil, _?): return true
                default:
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
        }
    }

    private func enforceArticleLimit(feedURLByLink: [String: String]) {
        guard maxArticlesPerFeed > 0 else {
            applySorting()
            return
        }

        var grouped: [String: [FeedEntry]] = [:]
        for entry in entries {
            let feedURL = entry.feedURL
                ?? feedURLByLink[entry.link]
                ?? feedSource(for: entry)?.url
                ?? entry.link
            grouped[feedURL, default: []].append(entry)
        }

        var trimmed: [FeedEntry] = []
        for (_, items) in grouped {
            let sorted = items.sorted { entryDate(for: $0) > entryDate(for: $1) }
            trimmed.append(contentsOf: sorted.prefix(maxArticlesPerFeed))
        }

        entries = trimmed
        applySorting()
    }

    private func entryDate(for entry: FeedEntry) -> Date {
        entry.pubDateString
            .flatMap { DateFormatter.rfc822.date(from: $0) }
            ?? Date.distantPast
    }

    private func persistEntriesCache() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            cachedEntriesData = data
        }
    }

    private func restoreCachedEntries() {
        guard !cachedEntriesData.isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if var cached = try? decoder.decode([FeedEntry].self, from: cachedEntriesData) {
            for index in cached.indices {
                cached[index].isRead = store.isRead(articleID: cached[index].link)
            }
            entries = cached
            enforceArticleLimit(feedURLByLink: [:])
        }
    }

    var filteredEntries: [FeedEntry] {
        showReadEntries ? entries : entries.filter { !$0.isRead }
    }

    private var hasUnread: Bool {
        entries.contains { !$0.isRead }
    }

    func markAsRead(_ entry: FeedEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            withAnimation(.easeInOut(duration: 0.18)) {
                entries[index].isRead = true
            }
            store.setRead(true, articleID: entry.link)

            persistEntriesCache()
        }
    }

    func markAsUnread(_ entry: FeedEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            withAnimation(.easeInOut(duration: 0.18)) {
                entries[index].isRead = false
            }
            store.setRead(false, articleID: entry.link)
            persistEntriesCache()
        }
    }

    func markAllAsRead() {
        let unreadLinks = entries.filter { !$0.isRead }.map { $0.link }
        guard !unreadLinks.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            for index in entries.indices {
                entries[index].isRead = true
            }
        }
        for link in unreadLinks {
            store.setRead(true, articleID: link)
        }
        persistEntriesCache()
    }
    
    func toggleBookmark(for entry: FeedEntry, isCurrentlyBookmarked: Bool) {
        BookmarkService.toggleBookmark(for: entry, context: modelContext)
        if isCurrentlyBookmarked {
            bookmarkedLinks.remove(entry.link)
        } else {
            bookmarkedLinks.insert(entry.link)
        }
    }
    
    @MainActor
    func refreshBookmarkedLinks() {
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.isBookmarked })
        if let results = try? modelContext.fetch(descriptor) {
            bookmarkedLinks = Set(results.map { $0.link })
        }
    }


    func feedTitle(for entry: FeedEntry) -> String {
        feedSource(for: entry)?.title ?? "Unbekannte Quelle"
    }

    func feedSource(for entry: FeedEntry) -> FeedSource? {
        guard
            let articleHost = URL(string: entry.link)?.host,
            let articleDomain = baseDomain(from: articleHost)
        else { return nil }

        for feed in feeds {
            let feedHost = URL(string: feed.url)?.host
            if let feedDomain = baseDomain(from: feedHost), feedDomain == articleDomain {
                return feed
            }
        }
        return nil
    }

    func baseDomain(from host: String?) -> String? {
        guard var h = host?.lowercased() else { return nil }
        let prefixes = ["www.", "feeds.", "feed.", "rss."]
        for p in prefixes {
            if h.hasPrefix(p) { h.removeFirst(p.count); break }
        }
        let parts = h.split(separator: ".")
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: ".")
        } else {
            return h
        }
    }
    
    private func enabledNotificationFeedURLs() -> Set<String> {
        NotificationPreferenceStore.allowedFeedURLs(from: notificationFeedPreferencesData, availableFeeds: feeds)
    }
}

struct EmptyFeedView: View {
    @EnvironmentObject private var theme: ThemeSettings

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(theme.uiAccentColor)
            Text("Keine Artikel verfügbar")
                .font(.headline)
                .foregroundStyle(theme.uiAccentColor)
            Text("Ziehe nach unten, um Feeds zu aktualisieren.")
                .font(.subheadline)
                .foregroundStyle(Color(.tertiaryLabel))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 32)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
        //.background(
        //    RoundedRectangle(cornerRadius: 22, style: .continuous)
         //       .fill(theme.uiAccentColor.opacity(0.12))
        //)
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeSettings())
        .environmentObject(ArticleStore.shared)
}
