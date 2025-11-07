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
    @AppStorage("notificationFeedPreferences") private var notificationFeedPreferencesData: Data = Data()
    @AppStorage("notificationsEnabledPreference") private var notificationsEnabledPreference: Bool = true
    
    @State private var entries: [FeedEntry] = []
    @State private var isLoading = false
    @State private var sortOption = "Neueste zuerst"
    @State private var showReadEntries = false
    @State private var hasLoadedOnce = false
    @State private var path: [FeedEntry] = []

    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var lastRefreshDate: Date? = nil
    @State private var bookmarkedLinks: Set<String> = []
    
    var sortOptions = ["Neueste zuerst", "Älteste zuerst", "Alphabetisch"]
    private var sortIconName: String {
        switch sortOption {
        case "Neueste zuerst":
            return "arrow.down"
        case "Älteste zuerst":
            return "arrow.up"
        default:
            return "textformat.abc"
        }
    }

    private func sortIcon(for option: String) -> String {
        switch option {
        case "Neueste zuerst":
            return "arrow.down"
        case "Älteste zuerst":
            return "arrow.up"
        default:
            return "textformat.abc"
        }
    }
    
    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(filteredEntries) { entry in
                    let matchedFeed = feedSource(for: entry)
                    let feedName = matchedFeed?.title ?? feedTitle(for: entry)
                    let feedColor = feedColor(for: matchedFeed?.url)
                    let detailEntry: FeedEntry = {
                        var updated = entry
                        updated.sourceTitle = feedName
                        return updated
                    }()
                    let isBookmarked = bookmarkedLinks.contains(detailEntry.link)
                    
                    Button {
                        path.append(detailEntry)
                    } label: {
                        FeedRowView(
                            entry: entry,
                            feedTitle: feedName,
                            feedColor: feedColor,
                            isBookmarked: isBookmarked
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
                                Label("Als ungelesen", systemImage: "xmark")
                            }
                            .tint(.orange)
                        } else {
                            Button {
                                markAsRead(entry)
                            } label: {
                                Label("Als gelesen", systemImage: "checkmark")
                            }
                            .tint(theme.uiAccentColor)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            toggleBookmark(for: detailEntry, isCurrentlyBookmarked: isBookmarked)
                        } label: {
                            Label(isBookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen",
                                  systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
                        }
                        .tint(isBookmarked ? .red : theme.uiAccentColor)
                    }
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
                    withTransaction(Transaction(animation: .easeInOut(duration: 0.22))) {
                        Task { await loadRSSFeed() }
                    }
                }
                await refreshTask?.value
            }
            .navigationTitle("Feed")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
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
                        Picker("Sortieren nach", selection: $sortOption) {
                            ForEach(sortOptions, id: \.self) { option in
                                Label(option, systemImage: sortIcon(for: option))
                                    .labelStyle(.titleAndIcon)
                                    .tag(option)
                            }
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
            if !hasLoadedOnce {
                hasLoadedOnce = true
                Task {
                    await loadRSSFeed()
                }
            }
            Task { @MainActor in
                refreshBookmarkedLinks()
            }
        }
        .onChange(of: sortOption) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                applySorting()
            }
        }
        .onChange(of: showReadEntries) { _ in
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

        let existingLinksBefore = Set(entries.map { $0.link })
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
                if !result.isEmpty {
                    let storedArticles = result.map { entry in
                        StoredFeedArticle(
                            title: entry.title,
                            link: entry.link,
                            publishedAt: entry.pubDateString.flatMap { DateFormatter.rfc822.date(from: $0) },
                            summary: HTMLText.stripHTML(entry.content)
                        )
                    }
                    store.mergeArticles(storedArticles, for: feed.url)
                }

                for entry in result {
                    feedURLByLink[entry.link] = feed.url
                }

                newEntries.append(contentsOf: result)
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
                    entries[existingIndex] = existing
                    entries[existingIndex].isRead = store.isRead(articleID: entries[existingIndex].link)
                } else {
                    var fresh = newEntry
                    fresh.isRead = store.isRead(articleID: fresh.link)
                    entries.append(fresh)
                }
            }

            entries.removeAll { oldEntry in
                !newEntries.contains(where: { $0.link == oldEntry.link })
            }

            applySorting()
        }

        let newUnique = newEntries.filter { !existingLinksBefore.contains($0.link) }
        let enabledFeeds = enabledNotificationFeedURLs()
        let eligibleEntries = newUnique.filter { entry in
            guard !enabledFeeds.isEmpty else { return false }
            let feedURL = feedURLByLink[entry.link] ?? feedSource(for: entry)?.url
            guard let feedURL else { return true }
            return enabledFeeds.contains(feedURL)
        }
        let newUnreadCount = eligibleEntries.filter { !$0.isRead }.count
        if notificationsEnabledPreference && newUnreadCount > 0 {
            NotificationScheduler.shared.requestAuthorizationIfNeeded { granted in
                guard granted else { return }
                let feedURLs = Set(eligibleEntries.compactMap { feedURLByLink[$0.link] ?? feedSource(for: $0)?.url })
                let feedTitle: String?
                if feedURLs.count == 1, let onlyURL = feedURLs.first,
                   let match = feeds.first(where: { $0.url == onlyURL }) {
                    feedTitle = match.title
                } else {
                    feedTitle = nil
                }
                NotificationScheduler.shared.scheduleNewArticlesNotification(count: newUnreadCount, feedTitle: feedTitle)
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
        case "Alphabetisch":
            entries.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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

    var filteredEntries: [FeedEntry] {
        showReadEntries ? entries : entries.filter { !$0.isRead }
    }

    func markAsRead(_ entry: FeedEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            withAnimation(.easeInOut(duration: 0.18)) {
                entries[index].isRead = true
            }
            store.setRead(true, articleID: entry.link)

            // Gentle fade and removal to allow the eye to follow
            if !showReadEntries {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        entries.removeAll { $0.id == entry.id && store.isRead(articleID: entry.link) }
                    }
                }
            }
        }
    }

    func markAsUnread(_ entry: FeedEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            withAnimation(.easeInOut(duration: 0.18)) {
                entries[index].isRead = false
            }
            store.setRead(false, articleID: entry.link)
        }
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
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.uiAccentColor.opacity(0.12))
        )
    }
}

struct FeedRowView: View {
    let entry: FeedEntry
    let feedTitle: String
    let feedColor: Color
    let isBookmarked: Bool

    private var entryDate: Date? {
        entry.pubDateString.flatMap { DateFormatter.rfc822.date(from: $0) }
    }

    var body: some View {
        ArticleCardView(
            feedTitle: feedTitle,
            feedColor: feedColor,
            title: entry.title,
            summary: HTMLText.stripHTML(entry.content),
            isRead: entry.isRead,
            date: entryDate,
            isBookmarked: isBookmarked
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeSettings())
        .environmentObject(ArticleStore.shared)
}
