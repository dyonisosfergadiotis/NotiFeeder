import SwiftUI
import Foundation
import FoundationModels
import SwiftData

// Annahme: Die DateParser- und DateFormatter-Extension aus der vorherigen Antwort
// ist in einer separaten Datei (z.B. DateUtils.swift) vorhanden.

// ----------------------------------------------------------------------
// WICHTIG: Ersetze die DateParser.parse(from:) durch Deine tatsächliche Funktion.
// HIER WIRD DIE ERSETZTE DATEUTILS-LOGIK ALS PLAUSIBEL ANGENOMMEN.
// ----------------------------------------------------------------------
// Hier ist ein Platzhalter für DateParser, falls er nicht im gleichen File ist.
// Wenn DateParser im selben File wie die Extension ist, ignoriere diesen Block.
/*
struct DateParser {
    static func parse(_ dateString: String?) -> Date {
        guard let s = dateString else { return Date.distantPast }
        // 1. ISO8601 Check
        if s.contains("-") && s.contains(":") {
            if let isoDate = ISO8601DateFormatter().date(from: s) {
                return isoDate
            }
        }
        // 2. YYYY Check
        if s.range(of: "\\s\\d{4}", options: .regularExpression) != nil {
            if let date = DateFormatter.rfc822.date(from: s) {
                return date
            }
        }
        // 3. YY Fallback
        if let date = DateFormatter.rfc822TwoDigitYear.date(from: s) {
            return date
        }
        return Date.distantPast
    }
}
*/
// ----------------------------------------------------------------------


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
            feeds = [FeedSource(title: "MacRumors", url: "https://feeds.macrumors.com/MacRumors-All")]
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
    @State private var recentlyReadLinks: Set<String> = []

    private let maxArticlesPerFeed = 100
    private var sortIconName: String {
        sortOption == "Neueste zuerst" ? "arrow.down.circle" : "arrow.up.circle"
    }
    
    // 🥇 KORRIGIERTE FUNKTION 1: Verwendet DateParser.parse()
    private func sortAllEntriesGlobally() {
        // 1. Alle Einträge global nach Datum sortieren
        let sortedEntries: [FeedEntry] = entries.sorted { lhs, rhs in
            let ld = DateParser.parse(lhs.pubDateString)
            let rd = DateParser.parse(rhs.pubDateString)
            switch sortOption {
            case "Neueste zuerst":
                return ld > rd
            default:
                return ld < rd
            }
        }

        // 2. MaxArticlesPerFeed nach globaler Sortierung anwenden
        guard maxArticlesPerFeed > 0 else {
            entries = sortedEntries
            return
        }

        var feedCount: [String: Int] = [:]
        var limitedEntries: [FeedEntry] = []
        for entry in sortedEntries {
            let feedURL = entry.feedURL ?? "unknown"
            let count = feedCount[feedURL] ?? 0
            if count < maxArticlesPerFeed {
                limitedEntries.append(entry)
                feedCount[feedURL] = count + 1
            }
        }

        entries = limitedEntries
    }
    
    private var feedListView: some View {
        List {
            ForEach(filteredEntries) { entry in
                entryRow(for: entry)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .listRowSpacing(6)
        //.background(Color(.systemGroupedBackground))
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
    }
    
    var body: some View {
        NavigationStack(path: $path) {
            feedListView
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

                    // Promote recently-read to fully read on refresh
                    if !recentlyReadLinks.isEmpty {
                        let links = Array(recentlyReadLinks)
                        for link in links {
                            store.setRead(true, articleID: link)
                            if let idx = entries.firstIndex(where: { $0.link == link }) {
                                entries[idx].isRead = true
                            }
                        }
                        recentlyReadLinks.removeAll()
                        persistEntriesCache()
                    }
                }
                .navigationTitle("Feed")
                .toolbar(content: { feedToolbar })
                .navigationDestination(for: FeedEntry.self) { entry in
                    navigationDestinationView(entry)
                }
        }
        .onAppear {
            if !didRestoreCachedEntries {
                didRestoreCachedEntries = true
                restoreCachedEntries()
            }
            triggerInitialLoadIfPossible()
            pruneEntriesForRemovedFeeds()
            Task { @MainActor in
                refreshBookmarkedLinks()
            }
        }
        .onChange(of: sortOption) { oldValue, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                sortAllEntriesGlobally()
            }
        }
        .onChange(of: feeds) { oldValue, newValue in
            triggerInitialLoadIfPossible()
            pruneEntriesForRemovedFeeds()
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
    
    private var feedToolbar: some ToolbarContent {
        Group {
            
            // Gruppe 1: Ungelesen-Button
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
            }

            // Echter ToolbarSpacer auf Top-Level
            ToolbarSpacer(.fixed, placement: .topBarTrailing)

            // Gruppe 2: Filter + Menü
            ToolbarItemGroup(placement: .topBarTrailing) {

                Button {
                    showReadEntries.toggle()
                } label: {
                    Image(systemName: showReadEntries
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
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
    }
    
    @ViewBuilder
    private func navigationDestinationView(_ entry: FeedEntry) -> some View {
        FeedDetailView(entry: entry,
                       feedColor: feedColor(for: feedSource(for: entry)?.url))
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
        let isRecentlyRead = recentlyReadLinks.contains(detailEntry.link)

        Button {
            recentlyReadLinks.insert(detailEntry.link)
            path.append(detailEntry)
        } label: {
            ArticleCardView(
                feedTitle: feedName,
                feedColor: rowFeedColor,
                title: entry.title,
                summary: strippedSummary,
                isRead: entry.isRead || isRecentlyRead,
                date: entryDateValue,
                isBookmarked: isBookmarked,
                highlightColor: rowFeedColor
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(Color(.systemBackground))
        .background(Color(.systemBackground))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        //.listRowBackground(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if entry.isRead {
                Button {
                    markAsUnread(entry)
                    recentlyReadLinks.remove(entry.link)
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

    // 🥇 KORRIGIERTE FUNKTION 3: Verwendet DateParser.parse()
    private func entryDate(for entry: FeedEntry) -> Date {
        DateParser.parse(entry.pubDateString)
    }
    
    private func pruneEntriesForRemovedFeeds() {
        let activeURLs = Set(feeds.map { $0.url })
        let beforeCount = entries.count
        entries.removeAll { entry in
            guard let url = entry.feedURL else { return true }
            return !activeURLs.contains(url)
        }
        if entries.count != beforeCount {
            persistEntriesCache()
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
                            // 🥇 KORRIGIERTE FUNKTION 2: Verwendet DateParser.parse()
                            publishedAt: entry.pubDateString.flatMap { DateParser.parse($0) },
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

        sortAllEntriesGlobally()
        persistEntriesCache()

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
        // Diese Funktion ist redundant, da sortAllEntriesGlobally() die globale Sortierung übernimmt.
        // Es ist besser, sie auf DateParser umzustellen oder zu entfernen, falls nur
        // sortAllEntriesGlobally() verwendet wird. Wir stellen sie auf den robusten Parser um.
        
        switch sortOption {
        case "Neueste zuerst":
            entries.sort { lhs, rhs in
                let ld = DateParser.parse(lhs.pubDateString)
                let rd = DateParser.parse(rhs.pubDateString)
                
                switch (ld, rd) {
                case let (l, r) where l != Date.distantPast && r != Date.distantPast: return l > r
                case (let l, _) where l != Date.distantPast: return true
                case (_, let r) where r != Date.distantPast: return false
                default:
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
                }
            }
        default: // Älteste zuerst
            entries.sort { lhs, rhs in
                let ld = DateParser.parse(lhs.pubDateString)
                let rd = DateParser.parse(rhs.pubDateString)
                
                switch (ld, rd) {
                case let (l, r) where l != Date.distantPast && r != Date.distantPast: return l < r
                case (let l, _) where l != Date.distantPast: return false
                case (_, let r) where r != Date.distantPast: return true
                default:
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
        }
    }

    private func enforceArticleLimit(feedURLByLink: [String: String]) {
        // Diese Funktion enthält die Begrenzungslogik jetzt in sortAllEntriesGlobally().
        // Hier wird die Sortierung trotzdem mit dem korrekten Parser durchgeführt.
        let sortedEntries: [FeedEntry]
        switch sortOption {
        case "Neueste zuerst":
            sortedEntries = entries.sorted {
                let ld = entryDate(for: $0)
                let rd = entryDate(for: $1)
                return ld > rd
            }
        default:
            sortedEntries = entries.sorted {
                let ld = entryDate(for: $0)
                let rd = entryDate(for: $1)
                return ld < rd
            }
        }
        entries = sortedEntries
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
            recentlyReadLinks.removeAll()
            sortAllEntriesGlobally()
            pruneEntriesForRemovedFeeds()
        }
    }

    var filteredEntries: [FeedEntry] {
        showReadEntries ? entries : entries.filter { !$0.isRead || recentlyReadLinks.contains($0.link) }
    }

    private var hasUnread: Bool {
        entries.contains { !$0.isRead || recentlyReadLinks.contains($0.link) }
    }

    func markAsRead(_ entry: FeedEntry) {
        recentlyReadLinks.remove(entry.link)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            withAnimation(.easeInOut(duration: 0.18)) {
                entries[index].isRead = true
            }
            store.setRead(true, articleID: entry.link)

            persistEntriesCache()
        }
    }

    func markAsUnread(_ entry: FeedEntry) {
        recentlyReadLinks.remove(entry.link)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            withAnimation(.easeInOut(duration: 0.18)) {
                entries[index].isRead = false
            }
            store.setRead(false, articleID: entry.link)
            persistEntriesCache()
        }
    }

    func markAllAsRead() {
        let unreadLinks = entries.filter { !$0.isRead }.map { $0.link } + Array(recentlyReadLinks)
        guard !unreadLinks.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            for index in entries.indices {
                entries[index].isRead = true
            }
        }
        for link in unreadLinks {
            store.setRead(true, articleID: link)
        }
        recentlyReadLinks.removeAll()
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
        //        .fill(theme.uiAccentColor.opacity(0.12))
        //)
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeSettings())
        .environmentObject(ArticleStore.shared)
}

