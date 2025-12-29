import SwiftUI
import Foundation
import FoundationModels
import SwiftData
import Network

struct ContentView: View {
    @AppStorage("savedFeeds") private var savedFeedsData: Data = Data()
    @AppStorage("cachedEntries") private var cachedEntriesData: Data = Data()
    @State private var feeds: [FeedSource] = []
    @EnvironmentObject private var theme: ThemeSettings
    @State private var showOnboarding: Bool = false
    @AppStorage("didRunOnboarding") private var didRunOnboarding: Bool = false
    
    @State private var showFeedsSettingsSheet: Bool = false
    @State private var showPersonalizationSheet: Bool = false
    @State private var showInfoSheet: Bool = false
    
    @State private var searchText: String = ""
    
    
    @StateObject private var networkState = NetworkState()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "NetworkPathMonitorQueue")
    

    var body: some View {
        VStack {
            FeedListView(
                feeds: $feeds,
                savedFeedsData: $savedFeedsData,
                showFeedsSettingsSheet: $showFeedsSettingsSheet,
                showPersonalizationSheet: $showPersonalizationSheet,
                showInfoSheet: $showInfoSheet,
                searchText: $searchText
            )
        }
        .environmentObject(networkState)
        .tint(theme.uiAccentColor)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Artikel suchen")
        .sheet(isPresented: $showOnboarding) {
            let vm = OnboardingViewModel()
            OnboardingFlowView(viewModel: vm) { produced in
                if let produced = produced {
                    // Save produced feed to savedFeedsData
                    var current = (try? JSONDecoder().decode([FeedSource].self, from: savedFeedsData)) ?? []
                    current.append(produced)
                    if let data = try? JSONEncoder().encode(current) {
                        savedFeedsData = data
                        feeds = current
                    }
                }
                showOnboarding = false
                didRunOnboarding = true
            }
            .environmentObject(theme)
            .presentationDetents([.large])
        }
        .onAppear {
            didRunOnboarding = false
            loadFeeds()
            if !didRunOnboarding && feeds.isEmpty {
                showOnboarding = true
            }
            // Start network monitoring
            pathMonitor.pathUpdateHandler = { path in
                DispatchQueue.main.async {
                    networkState.isOffline = (path.status != .satisfied)
                }
            }
            pathMonitor.start(queue: pathQueue)
        }
        .onDisappear {
            pathMonitor.cancel()
        }
        .sheet(isPresented: $showFeedsSettingsSheet) {
            FeedsSettingsViewPlaceholder()
                .presentationDetents([.fraction(0.45)])
        }
        .sheet(isPresented: $showPersonalizationSheet) {
            PersonalizationViewPlaceholder()
                .environmentObject(theme)
                .presentationDetents([.fraction(0.45)])
        }
        .sheet(isPresented: $showInfoSheet) {
            InfoViewPlaceholder()
                .presentationDetents([.fraction(0.45)])
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
    @Binding var showFeedsSettingsSheet: Bool
    @Binding var showPersonalizationSheet: Bool
    @Binding var showInfoSheet: Bool
    @Binding var searchText: String
    @EnvironmentObject private var store: ArticleStore
    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var networkState: NetworkState
    @Environment(\.modelContext) private var modelContext
    @AppStorage("cachedEntries") private var cachedEntriesData: Data = Data()
    
    @AppStorage("ui.cards.previewLines") private var previewLines: Int = 3
    @AppStorage("ui.cards.style.fullColor") private var fullColorCards: Bool = false
    
    @State private var entries: [FeedEntry] = []
    @State private var isLoading = false
    @State private var sortOption = "Neueste zuerst"
    @State private var showReadEntries = false
    @State private var didTriggerInitialLoad = false
    @State private var path: [FeedEntry] = []
    @State private var didRestoreCachedEntries = false
    
    @State private var showBookmarksSheet: Bool = false

    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var lastRefreshDate: Date? = nil
    @State private var bookmarkedLinks: Set<String> = []
    @State private var recentlyReadLinks: Set<String> = [] // Tracks items opened this session; items are READ + RECENT, visible until next refresh/app open
    
    @State private var showSearchSheet: Bool = false
    

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
            ForEach(filteredEntries, id: \.id) { entry in
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
                .if(networkState.isOffline) { view in
                    view.navigationSubtitle("Offline")
                }
                .toolbar(content: { feedToolbar })
                .sheet(isPresented: $showBookmarksSheet) {
                    BookmarksView()
                }
                //.sheet for other sheets moved to ContentView to avoid multiple sheets on same view
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
            // When feeds are added or removed, ensure UI updates immediately
            pruneEntriesForRemovedFeeds()
            Task { @MainActor in
                await loadRSSFeed()
            }
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
    
    @ToolbarContentBuilder
    private var feedToolbar: some ToolbarContent {
                DefaultToolbarItem(
                    kind: .search,
                    placement: .bottomBar
                )

                ToolbarSpacer(
                    .flexible,
                    placement: .bottomBar
                )
            
            // Gruppe 1: Ungelesen-Button
            ToolbarItemGroup(placement: .bottomBar) {
                
                    Button {
                        showBookmarksSheet = true
                    } label: {
                        Image(systemName: "bookmark")
                    }
                    .tint(theme.uiAccentColor)
                }
        
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                Button {
                    showFeedsSettingsSheet = true
                } label: {
                    Label("Feeds", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    showPersonalizationSheet = true
                } label: {
                    Label("Personalisierung", systemImage: "paintbrush")
                }
                Button {
                    showInfoSheet = true
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
            } label: {
                Image(systemName: "gear")
                    .symbolRenderingMode(.hierarchical)
            }
            .tint(theme.uiAccentColor)
        }
        
        

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
                Text("Sortieren nach:")
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
        } // <- Ende ToolbarItemGroup topBarTrailing
    } // <- Ende feedToolbar
    
    private var unreadCount: Int {
        // Summe aller ungelesenen Artikel in allen Feeds
        // Wir holen die gecachten Einträge und zählen die ungelesenen
        if let decoded = try? JSONDecoder().decode([FeedEntry].self, from: cachedEntriesData) {
            return decoded.filter { !$0.isRead }.count
        }
        return 0
    }
    
    @ViewBuilder
    private func navigationDestinationView(_ entry: FeedEntry) -> some View {
        FeedDetailView(
            entry: entry,
            feedColor: feedColor(for: feedSource(for: entry)?.url),
            entriesProvider: { filteredEntries },
            onNavigateToEntry: { newEntry, _ in
                withAnimation(.smooth(duration: 0.22)) {
                    var newDetail = newEntry
                    // Derive feed info for consistency
                    newDetail.sourceTitle = feedTitle(for: newEntry)
                    newDetail.feedURL = feedSource(for: newEntry)?.url

                    if !newEntry.isRead {
                        recentlyReadLinks.insert(newDetail.link)
                        store.setRead(true, articleID: newDetail.link)
                        if let idx = entries.firstIndex(where: { $0.link == newDetail.link }) {
                            entries[idx].isRead = true
                            persistEntriesCache()
                        }
                    }

                    if !path.isEmpty {
                        path[path.count - 1] = newDetail
                    } else {
                        path.append(newDetail)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func entryRow(for entry: FeedEntry) -> some View {
        let matchedFeed = feedSource(for: entry)
        let feedName = feedTitle(for: entry)
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
            // Opening an unread item -> becomes read + recently; if already read, never becomes recently again
            if !entry.isRead {
                recentlyReadLinks.insert(detailEntry.link)
                store.setRead(true, articleID: detailEntry.link)
                if let idx = entries.firstIndex(where: { $0.link == detailEntry.link }) {
                    entries[idx].isRead = true
                    persistEntriesCache()
                }
            }
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
                highlightTerm: searchText.isEmpty ? nil : searchText,
                highlightColor: rowFeedColor,
                previewLineCount: previewLines,
                useFullColorBackground: fullColorCards
            )
            .background(Color(.systemBackground))
            .overlay(
                Group {
                    if !fullColorCards {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(
                                (entry.isRead || isRecentlyRead)
                                    ? rowFeedColor.opacity(0.2)
                                    : rowFeedColor.opacity(0.6),
                                lineWidth: 1
                            )
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .listRowBackground(Color(.systemBackground))
        .background(Color(.systemBackground))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        
        //.listRowBackground(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if entry.isRead || recentlyReadLinks.contains(entry.link) {
                Button {
                    markAsUnread(entry)
                } label: {
                    Image(systemName: "eye.slash")
                }
                .accessibilityLabel("Als ungelesen markieren")
                .tint(theme.uiSwipeColor)
            } else {
                Button {
                    markAsRead(entry)
                } label: {
                    Image(systemName: "eye")
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
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            return entries.filter { entry in
                let title = entry.title.lowercased()
                let summary = HTMLText.stripHTML(entry.content).lowercased()
                let author = (entry.author ?? "").lowercased()
                return title.contains(q) || summary.contains(q) || author.contains(q)
            }
        } else if showReadEntries {
            return entries
        } else {
            return entries.filter { !$0.isRead || recentlyReadLinks.contains($0.link) }
        }
    }

    private var hasUnread: Bool {
        entries.contains { !$0.isRead && !recentlyReadLinks.contains($0.link) }
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
            // Remove from recently read if present
            if recentlyReadLinks.contains(entry.link) {
                recentlyReadLinks.remove(entry.link)
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
        if let explicit = entry.sourceTitle, !explicit.isEmpty {
            return explicit
        }
        return feedSource(for: entry)?.title ?? "Unbekannte Quelle"
    }

    func feedSource(for entry: FeedEntry) -> FeedSource? {
        // 1) If the entry already carries its feedURL, try to match directly
        if let entryFeedURL = entry.feedURL, let entryFeedHost = URL(string: entryFeedURL)?.host?.lowercased() {
            if let direct = feeds.first(where: { URL(string: $0.url)?.host?.lowercased() == entryFeedHost }) {
                return direct
            }
        }

        // 2) Try to match by the article link's base domain against the feed's base domain
        guard
            let articleHost = URL(string: entry.link)?.host,
            let articleDomain = baseDomain(from: articleHost)
        else {
            // 3) As a last resort, try strict host equality between article link and feed url
            for feed in feeds {
                if let fHost = URL(string: feed.url)?.host?.lowercased(),
                   let aHost = URL(string: entry.link)?.host?.lowercased(),
                   fHost == aHost {
                    return feed
                }
            }
            return nil
        }

        for feed in feeds {
            let feedHost = URL(string: feed.url)?.host
            if let feedDomain = baseDomain(from: feedHost), feedDomain == articleDomain {
                return feed
            }
        }

        // 3) As a final fallback, attempt strict host equality
        for feed in feeds {
            if let fHost = URL(string: feed.url)?.host?.lowercased(),
               let aHost = URL(string: entry.link)?.host?.lowercased(),
               fHost == aHost {
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

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// REPLACED FeedsSettingsViewPlaceholder with enhanced version
struct FeedsSettingsViewPlaceholder: View {
    @AppStorage("savedFeeds") private var savedFeedsData: Data = Data()
    @State private var feeds: [FeedSource] = []
    @State private var isEditing: Bool = false
    @State private var showAddFeedSheet: Bool = false
    
    @State private var showEditFeedSheet: Bool = false
    @State private var editingIndex: Int? = nil

    var body: some View {
        NavigationStack {
            List {
                Section("") {
                    if feeds.isEmpty {
                        Label("Noch keine Feeds hinzugefügt", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(feeds, id: \.url) { feed in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feed.title).font(.body)
                                    Text(feed.url).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    if let idx = feeds.firstIndex(where: { $0.url == feed.url }) {
                                        editingIndex = idx
                                        showEditFeedSheet = true
                                    }
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .tint(Color.accentColor)
                                .accessibilityLabel("Feed bearbeiten")
                            }
                        }
                        .onDelete(perform: deleteFeeds)
                        .onMove(perform: moveFeeds)
                    }
                    Button {
                        showAddFeedSheet = true
                    } label: {
                        Label("Feed hinzufügen", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Feeds")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAddFeedSheet) {
                AddSingleFeedView { newItem in
                    guard let item = newItem else { return }
                    feeds.append(item)
                    persistFeeds()
                }
                .presentationDetents([.fraction(0.5)])
            }
            .sheet(isPresented: $showEditFeedSheet, onDismiss: {
                // Clear selection after dismiss to avoid stale indices
                editingIndex = nil
            }) {
                if let idx = editingIndex, feeds.indices.contains(idx) {
                    EditSingleFeedView(feed: feeds[idx]) { updated in
                        guard let updated = updated else { return }
                        feeds[idx] = updated
                        persistFeeds()
                    }
                    .presentationDetents([.fraction(0.45)])
                    .interactiveDismissDisabled(false)
                } else {
                    // Fallback in case index is no longer valid
                    Text("Kein Feed ausgewählt")
                        .padding()
                        .presentationDetents([.fraction(0.3)])
                }
            }
            .onAppear { restoreFeeds() }
            .onChange(of: savedFeedsData) { _, _ in
                // Keep in sync with external changes (e.g., onboarding added a feed)
                restoreFeeds()
            }
        }
    }

    private func restoreFeeds() {
        guard !savedFeedsData.isEmpty else {
            feeds = []
            return
        }
        if let decoded = try? JSONDecoder().decode([FeedSource].self, from: savedFeedsData) {
            feeds = decoded
        } else {
            feeds = []
        }
    }

    private func persistFeeds() {
        if let data = try? JSONEncoder().encode(feeds) {
            savedFeedsData = data
        }
    }

    private func deleteFeeds(at offsets: IndexSet) {
        feeds.remove(atOffsets: offsets)
        persistFeeds()
    }

    private func moveFeeds(from source: IndexSet, to destination: Int) {
        feeds.move(fromOffsets: source, toOffset: destination)
        persistFeeds()
    }
}

// New helper view for adding a single feed
struct AddSingleFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var urlString: String = ""
    @State private var selectedColor: Color = Color(red: 0.78, green: 0.88, blue: 0.97)
    let onAdd: (FeedSource?) -> Void

    private let presetColors: [Color] = [
        Color(red: 0.98, green: 0.80, blue: 0.80), // pastel red
        Color(red: 0.99, green: 0.88, blue: 0.73), // pastel orange
        Color(red: 0.99, green: 0.97, blue: 0.76), // pastel yellow
        Color(red: 0.80, green: 0.93, blue: 0.82), // pastel green
        Color(red: 0.78, green: 0.88, blue: 0.97), // pastel blue
        Color(red: 0.86, green: 0.80, blue: 0.96)  // pastel purple
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $title)
                        .textInputAutocapitalization(.words)
                    TextField("Feed URL", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                }

                Section("Farbe") {
                    // Preset colors and ColorPicker inline horizontally, spaced from edges with Spacer
                    HStack(spacing: 12) { // Einheitlicher Abstand für alle Elemente
                        Spacer(minLength: 0)

                        // Preset Farben
                        ForEach(presetColors, id: \.self) { color in
                            ZStack {
                                Circle()
                                    .fill(color)
                                    .frame(width: 28, height: 28)
                                
                                if color.description == selectedColor.description {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.bold()) // Etwas fetter wirkt oft hochwertiger
                                        .foregroundStyle(.black.opacity(0.7))
                                }
                            }
                            .contentShape(Circle()) // Verbessert die Treffzone für Taps
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedColor = color
                                }
                            }
                        }

                        // Der ColorPicker direkt daneben
                        ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                            .labelsHidden()
                            .fixedSize() // Verhindert, dass der Picker unnötig Platz einnimmt

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Feed hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() }label:{Image(systemName: "xmark")}
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: trimmedURL), !trimmedURL.isEmpty else {
                            onAdd(nil)
                            dismiss()
                            return
                        }
                        let name = title.isEmpty ? trimmedURL : title
                        // NOTE: Persisting color per feed requires ThemeSettings support; here we just emit the feed.
                        let feed = FeedSource(title: name, url: url.absoluteString)
                        onAdd(feed)
                        dismiss()
                    }label:{Image(systemName: "checkmark")}
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct EditSingleFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var urlString: String
    let onSave: (FeedSource?) -> Void

    init(feed: FeedSource, onSave: @escaping (FeedSource?) -> Void) {
        _title = State(initialValue: feed.title)
        _urlString = State(initialValue: feed.url)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $title)
                        .textInputAutocapitalization(.words)
                    TextField("Feed URL", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled(true)
                }
            }
            .navigationTitle("Feed bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: trimmedURL), !trimmedURL.isEmpty else {
                            onSave(nil)
                            dismiss()
                            return
                        }
                        let name = title.isEmpty ? trimmedURL : title
                        let updated = FeedSource(title: name, url: url.absoluteString)
                        onSave(updated)
                        dismiss()
                    } label: { Image(systemName: "checkmark") }
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// REPLACED PersonalizationViewPlaceholder with richer settings form
struct PersonalizationViewPlaceholder: View {
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage("ui.font.size") private var fontSize: Double = 16
    @AppStorage("ui.cards.previewLines") private var previewLines: Int = 3
    @AppStorage("ui.cards.style.fullColor") private var fullColorCards: Bool = false

    // Bind directly to theme color so updates propagate immediately via EnvironmentObject
    @State private var selectedColor: Color = .green

    var body: some View {
        NavigationStack {
            Form {
                Section("Kacheln") {
                    Stepper(value: $previewLines, in: 0...6) {
                        Label("Anzahl Vorschauzeilen: \(previewLines)", systemImage: "text.justify.left")
                    }
                    Toggle(isOn: $fullColorCards) {
                        Label("Vollflächige Kacheln", systemImage: fullColorCards ? "rectangle.inset.filled" :"rectangle")
                    }
                }

                Section("Akzentferbe") {
                    ColorGridPicker(selected: $selectedColor)
                }
            }
            .navigationTitle("Personalisierung")
            .navigationBarTitleDisplayMode(.inline)
            .navigationLinkIndicatorVisibility(.visible)
            .onAppear {
                // Initialize from theme so UI reflects current accent
                selectedColor = theme.uiAccentColor
            }
            .onChange(of: selectedColor) { _, newValue in
                // Persist to theme immediately so other views update their .tint(theme.uiAccentColor)
                theme.setUIAccentColor(newValue)
            }
        }
    }
}

// New helper view for color selection
struct ColorGridPicker: View {
    @Binding var selected: Color
    private let colors: [Color] = [
        Color(red: 0.98, green: 0.80, blue: 0.80), // pastel red
        Color(red: 0.99, green: 0.88, blue: 0.73), // pastel orange
        Color(red: 0.99, green: 0.97, blue: 0.76), // pastel yellow
        Color(red: 0.80, green: 0.93, blue: 0.82), // pastel green
        Color(red: 0.78, green: 0.88, blue: 0.97), // pastel blue
        Color(red: 0.86, green: 0.80, blue: 0.96), // pastel purple
        Color(red: 0.96, green: 0.80, blue: 0.88)  // pastel pink
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 7), spacing: 12) {
                ForEach(colors.indices, id: \.self) { idx in
                    let color = colors[idx]
                    ZStack {
                        Circle().fill(color)
                        if color.description == selected.description {
                            Image(systemName: "checkmark")
                                .font(.caption2)
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { selected = color } }
                    .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// REPLACED InfoViewPlaceholder with more complete About view
struct InfoViewPlaceholder: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Danksagung") {
                    Text("Vielen Dank an alle Open-Source-Projekte und die Community, die diese App möglich machen.")
                }
                Section("Autor") {
                    LabeledContent("Name") { Text("Dein Name") }
                    LabeledContent("Kontakt") { Text("@deinhandle") }
                }
                Section("App") {
                    LabeledContent("Version") { Text(appVersion) }
                    LabeledContent("Build") { Text(appBuild) }
                }
                Section("Rechtliches") {
                    LabeledContent("Lizenz") { Text("MIT License") }
                    LabeledContent("Copyright") { Text("© \(Calendar.current.component(.year, from: Date())) Dein Name") }
                }
            }
            .navigationTitle("Info")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeSettings())
        .environmentObject(ArticleStore.shared)
}

