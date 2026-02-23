import SwiftUI
import Foundation
import FoundationModels
import SwiftData
import Network
import QuartzCore
import UIKit

struct ContentView: View {
    @AppStorage("savedFeeds", store: FeedStorage.defaults) private var savedFeedsData: Data = Data()
    @EnvironmentObject private var theme: ThemeSettings
    @State private var feeds: [FeedSource] = []
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
        .background(
            AccentBackground(accent: theme.uiAccentColor)
                .ignoresSafeArea()
        )
        .environmentObject(networkState)
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
            .interactiveDismissDisabled(true)
        }
        .onAppear {
            FeedStorage.migrateIfNeeded()
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.savedFeeds)
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.cachedEntries)
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
        .onChange(of: savedFeedsData) { _, _ in
            loadFeeds()
        }
        .sheet(isPresented: $showFeedsSettingsSheet) {
            FeedsSettingsViewPlaceholder()
                .presentationDetents([UIStylePolicy.Sheet.compactDetent])
        }
        .sheet(isPresented: $showPersonalizationSheet) {
            PersonalizationViewPlaceholder()
                .environmentObject(theme)
                .presentationDetents([UIStylePolicy.Sheet.mediumDetent])
        }
        .sheet(isPresented: $showInfoSheet) {
            InfoViewPlaceholder()
                .presentationDetents([UIStylePolicy.Sheet.compactDetent])
        }
    }
    
    func loadFeeds() {
        let effectiveData = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.savedFeeds) ?? savedFeedsData
        if effectiveData != savedFeedsData {
            savedFeedsData = effectiveData
        }
        if let decoded = try? JSONDecoder().decode([FeedSource].self, from: effectiveData) {
            feeds = decoded
        } else {
            // Keine Default-Feeds laden. Nur vom Nutzer gespeicherte Feeds verwenden.
            feeds = []
        }
    }
}

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @AppStorage("cachedEntries") private var cachedEntriesData: Data = Data()
    
    @AppStorage("ui.cards.previewLines") private var previewLines: Int = 3
    @AppStorage("ui.cards.style.fullColor") private var fullColorCards: Bool = false
    
    @State var isSearching: Bool = false;
    @FocusState private var isToolbarSearchFocused: Bool
    @State private var isClosingSearch = false
    
    @State private var entries: [FeedEntry] = []
    @State private var isLoading = false
    @State private var sortOption = "Neueste zuerst"
    @AppStorage("feed.filter.unreadOnly", store: FeedStorage.defaults) private var showUnreadOnly: Bool = false
    @State private var didTriggerInitialLoad = false
    @State private var path: [FeedEntry] = []
    @State private var didRestoreCachedEntries = false
    @State private var selectedFeedIDs: Set<String> = []
    @State private var activeFeedTabID: String = FeedFilterSelection.all
    
    @State private var feedToEdit: FeedSource? = nil
    @State private var loadingFeedIDs: Set<String> = []
    @State private var showOnlyBookmarks: Bool = false
    @State private var showBookmarkFilterPill: Bool = false
    @State private var showDummyFilterTwo: Bool = false
    
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var feedsReloadTask: Task<Void, Never>? = nil
    @State private var statusBarRefreshTask: Task<Void, Never>? = nil
    @State private var lastRefreshDate: Date? = nil
    @State private var bookmarkedLinks: Set<String> = []
    @State private var recentlyReadLinks: Set<String> = [] // Tracks items opened this session; items are READ + RECENT, visible until next refresh/app open
    @State private var listAppearToken = UUID()
    @State private var lastScrollOffset: CGFloat = 0
    @State private var lastScrollTime: TimeInterval = 0
    @State private var scrollSpeed: Double = 0
    @State private var lastHapticTime: TimeInterval = 0
    @State private var feedLoadErrorsByID: [String: FeedFetchError] = [:]

    private let feedClient = FeedNetworkClient()
    private static let cacheEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let cacheDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    
    private let maxArticlesPerFeed = 100
    private let automaticForegroundRefreshInterval: TimeInterval = 120
    private var sortIconName: String {
        sortOption == "Neueste zuerst" ? "arrow.down" : "arrow.up"
    }
    private var animationSpeedFactor: Double {
        let normalized = 1.0 / (1.0 + (scrollSpeed / 600.0))
        return max(0.2, min(1.0, normalized))
    }
    private var animationDelayBoost: Double {
        // Start earlier only when scrolling fast; keep slow-scroll timing unchanged.
        guard scrollSpeed > 420 else { return 0 }
        let t = min(1.0, (scrollSpeed - 420.0) / 1200.0)
        return 0.02 + (0.06 * t)
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
    
    private enum FeedFilterSelection {
        static let all = "__all__"
    }
    
    private func feedListView(for selectedFeedID: String) -> some View {
        let visibleEntries = filteredEntries(for: selectedFeedID)
        return ZStack(alignment: .top) {
            List {
                ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                    entryRow(for: entry, index: index)
                }
            }
            .coordinateSpace(name: "feedScroll")
            .scrollIndicators(.hidden)
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
                        // Keep the existing animation boundary, but await the actual refresh task.
                    }
                    await loadRSSFeed()
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
                    pushSnapshotToWatch()
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .listRowSpacing(6)
            .animation(.easeInOut(duration: 0.2), value: visibleEntries.map(\.id))
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: ScrollOffsetPreferenceKey.self,
                            value: proxy.frame(in: .named("feedScroll")).minY
                        )
                }
            )
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { newOffset in
                let now = CACurrentMediaTime()
                if lastScrollTime > 0 {
                    let delta = newOffset - lastScrollOffset
                    let dt = max(now - lastScrollTime, 0.016)
                    let speed = abs(Double(delta)) / dt
                    scrollSpeed = (scrollSpeed * 0.7) + (speed * 0.3)
                }
                lastScrollOffset = newOffset
                lastScrollTime = now
            }
            .overlay {
                if visibleEntries.isEmpty {
                    VStack(spacing: 16) {
                        EmptyFeedView()
                            .environmentObject(theme)
                    }
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .animation(.easeInOut(duration: 0.2), value: visibleEntries.isEmpty)
                }
            }
        }
    }
    
    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AccentBackground(accent: theme.uiAccentColor)
                    .ignoresSafeArea()
                
                feedListView(for: activeFeedTabID)
                
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar{ feedToolbar }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(item: $feedToEdit, onDismiss: {
                feedToEdit = nil
            }) { feed in
                EditSingleFeedView(feed: feed, initialColor: theme.color(for: feed.url)) { updated in
                    guard let updated = updated else { return }
                    updateFeed(original: feed, updated: updated)
                }
                .environmentObject(theme)
                .presentationDetents([UIStylePolicy.Sheet.compactDetent])
            }
            .navigationDestination(for: FeedEntry.self) { entry in
                navigationDestinationView(entry)
            }
        }
        .onAppear {
            if !didRestoreCachedEntries {
                didRestoreCachedEntries = true
                restoreCachedEntries()
            }
            if selectedFeedIDs.isEmpty {
                selectedFeedIDs = Set(feeds.map { $0.id })
            }
            showBookmarkFilterPill = !bookmarkedLinks.isEmpty
            triggerInitialLoadIfPossible()
            pruneEntriesForRemovedFeeds()
            Task { @MainActor in
                refreshBookmarkedLinks()
            }
            pushSnapshotToWatch()
        }
        .onChange(of: isSearching) { _, newValue in
            if newValue {
                isClosingSearch = false
                DispatchQueue.main.async {
                    isToolbarSearchFocused = true
                }
            }
        }
        .onChange(of: isToolbarSearchFocused) { _, newValue in
            if !newValue && isSearching && !isClosingSearch {
                isSearching = false
            }
        }
        .onChange(of: sortOption) { oldValue, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                sortAllEntriesGlobally()
            }
        }
        .onChange(of: feeds) { oldValue, newValue in
            let validIDs = Set(newValue.map { $0.id })
            if activeFeedTabID != FeedFilterSelection.all && !validIDs.contains(activeFeedTabID) {
                activeFeedTabID = FeedFilterSelection.all
            }
            selectedFeedIDs = selectedFeedIDs.intersection(validIDs)
            if selectedFeedIDs.isEmpty {
                selectedFeedIDs = validIDs
            }
            pruneEntriesForRemovedFeeds()
            scheduleFeedsReload()
            pushSnapshotToWatch()
        }
        .onChange(of: bookmarkedLinks) { _, newValue in
            let hasBookmarks = !newValue.isEmpty
            if !hasBookmarks && showOnlyBookmarks {
                showOnlyBookmarks = false
            }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                showBookmarkFilterPill = hasBookmarks
            }
        }
        .onChange(of: path) { oldValue, newValue in
            // When navigating back from detail, resync read flags from the store so filters update immediately
            for idx in entries.indices {
                entries[idx].isRead = store.isRead(articleID: entries[idx].link)
            }
            persistEntriesCache()
            pushSnapshotToWatch()
        }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { @MainActor in
                    await refreshOnAppActivationIfNeeded()
                }
            }
            .onOpenURL { url in
                Task { @MainActor in
                    handleDeepLink(url)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchRefreshRequested)) { _ in
                Task { @MainActor in
                    await handleWatchRefreshRequest()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .watchOpenArticleRequested)) { notification in
                guard let link = notification.userInfo?["link"] as? String, !link.isEmpty else { return }
                Task { @MainActor in
                    openArticle(link: link)
                }
            }
            .onAppear {
                statusBarRefreshTask?.cancel()
                statusBarRefreshTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s delay nötig, sonst zu früh
                    UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .forEach { scene in
                        scene.windows.first?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
                    }
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            feedsReloadTask?.cancel()
            statusBarRefreshTask?.cancel()
        }
    }

    @ToolbarContentBuilder
    private var feedToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text("Feed")
                    .font(.headline)
                if networkState.isOffline {
                    Text("Offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        
        
        if !isSearching {
            ToolbarItem(placement: .bottomBar) {
                Button(action: {
                    withAnimation {
                        isClosingSearch = false
                        isSearching = true
                    }
                }) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(UIStylePolicy.neutralIcon)
                }
                .minimumHitTarget()
                .accessibilityLabel("Suche öffnen")
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                filterMenuButton(size: 36)
                    .transition(
                        .asymmetric(
                            insertion: .offset(x: 8).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        } else {
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(UIStylePolicy.neutralIcon)
                    TextField("Artikel suchen", text: $searchText)
                        .focused($isToolbarSearchFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .tint(theme.uiAccentColor)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(iconTint(active: true))
                        }
                        .minimumHitTarget()
                        .accessibilityLabel("Suche leeren")
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    closeSearchFromToolbar()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(UIStylePolicy.neutralIcon)
                }
                .minimumHitTarget()
                .accessibilityLabel("Suche schließen")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    
        
        ToolbarItemGroup(placement: .topBarLeading) {
            Menu {
                Section("Einstellungen"){
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
                }
            } label: {
                Image(systemName: "gear")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UIStylePolicy.neutralIcon)
            }
            .minimumHitTarget()
            .accessibilityLabel("Menü")
        }
        
        
        
        // Gruppe 2: Filter + Menü
        ToolbarSpacer(.fixed,placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing){
            Menu {
                Section ("Sortierung"){
                    Button {
                        guard sortOption != "Neueste zuerst" else { return }
                        withAnimation(UIStylePolicy.Motion.standardEase) {
                            sortOption = "Neueste zuerst"
                        }
                    } label: {
                        Label("Neueste zuerst", systemImage: "arrow.down")
                            .labelStyle(.titleAndIcon)
                    }
                    
                    Button {
                        guard sortOption != "Älteste zuerst" else { return }
                        withAnimation(UIStylePolicy.Motion.standardEase) {
                            sortOption = "Älteste zuerst"
                        }
                    } label: {
                        Label("Älteste zuerst", systemImage: "arrow.up")
                            .labelStyle(.titleAndIcon)
                    }
                }
                } label: {
                    Image(systemName: sortIconName)
                        .foregroundStyle(UIStylePolicy.neutralIcon)
                }
                .minimumHitTarget()
                .accessibilityLabel("Sortierung")
            } // <- Ende ToolbarItemGroup topBarTrailing
    } // <- Ende feedToolbar
    
    private var unreadCountsByFeedID: [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries {
            let isUnread = !entry.isRead
            guard isUnread else { continue }
            if let id = feedSource(for: entry)?.id {
                counts[id, default: 0] += 1
            }
        }
        return counts
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
            },
            onToggleRead: { isRead in
                withAnimation(.easeInOut(duration: 0.18)) {
                    if let idx = entries.firstIndex(where: { $0.link == entry.link }) {
                        entries[idx].isRead = isRead
                    }
                    if isRead {
                        recentlyReadLinks.insert(entry.link)
                    } else {
                        recentlyReadLinks.remove(entry.link)
                    }
                }
                persistEntriesCache()
            }
        )
    }
    
    @ViewBuilder
    private func entryRow(for entry: FeedEntry, index: Int) -> some View {
        let matchedFeed = feedSource(for: entry)
        let feedName = feedTitle(for: entry)
        let rowFeedColor = feedColor(for: matchedFeed?.url)
        let baseDelay = min(Double(index) * 0.015, 0.12)
        let appearDelay = max(0, (baseDelay * animationSpeedFactor) - animationDelayBoost)
        let entryDateValue = entryDate(for: entry)
        let strippedSummary = entry.content
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
            let card = ArticleCardView(
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
                .background(Color(.systemBackground).opacity(0.0))
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
            
            card
                .articleCardAppear(trigger: listAppearToken,
                                   delay: appearDelay,
                                   glowColor: rowFeedColor,
                                   speedFactor: animationSpeedFactor)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entryRowAccessibilityValue(feedName: feedName,
                                                       isRead: entry.isRead || isRecentlyRead,
                                                       isBookmarked: isBookmarked,
                                                       date: entryDateValue))
        .accessibilityHint("Öffnet Artikel")
        .listRowBackground(Color(.systemBackground).opacity(0.0))
        .background(Color(.systemBackground).opacity(0.0))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .transition(
            .asymmetric(
                insertion: .identity,
                removal: .modifier(
                    active: ArticleRowPopTransitionModifier(
                        scale: 0.975,
                        yOffset: -6,
                        blur: 4,
                        opacity: 0.0,
                        glowColor: rowFeedColor,
                        glowOpacity: 0.0,
                        glowRadius: 0,
                        glowYOffset: 0
                    ),
                    identity: ArticleRowPopTransitionModifier(
                        scale: 1.0,
                        yOffset: 0,
                        blur: 0,
                        opacity: 1.0,
                        glowColor: rowFeedColor,
                        glowOpacity: 0.08,
                        glowRadius: 16,
                        glowYOffset: 5
                    )
                )
            )
        )
        .onDisappear {
            triggerLightestScrollHapticIfNeeded()
        }
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

    @MainActor
    private func refreshOnAppActivationIfNeeded() async {
        guard !feeds.isEmpty else { return }
        guard !isLoading else { return }
        guard !networkState.isOffline else { return }

        if let lastRefreshDate {
            let age = Date().timeIntervalSince(lastRefreshDate)
            guard age >= automaticForegroundRefreshInterval else { return }
        }

        await loadRSSFeed()
    }

    private func triggerLightestScrollHapticIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastScrollTime < 0.2 else { return }
        guard scrollSpeed > 60 else { return }
        guard now - lastHapticTime > 0.04 else { return }
        lastHapticTime = now
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.prepare()
        generator.impactOccurred(intensity: 0.2)
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

private struct ArticleRowPopTransitionModifier: ViewModifier {
    let scale: CGFloat
    let yOffset: CGFloat
    let blur: CGFloat
    let opacity: Double
    let glowColor: Color
    let glowOpacity: Double
    let glowRadius: CGFloat
    let glowYOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(y: yOffset)
            .blur(radius: blur)
            .opacity(opacity)
            .shadow(color: glowColor.opacity(glowOpacity), radius: glowRadius, x: 0, y: glowYOffset)
    }
}

private struct AccentBackground: View {
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        LinearGradient(
            colors: UIStylePolicy.accentBackgroundColors(accent: accent, colorScheme: colorScheme),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct TopChromeBackground: View {
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        LinearGradient(
            colors: UIStylePolicy.topChromeColors(accent: accent, colorScheme: colorScheme),
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct TopChromePreview: View {
    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let pillRowHeight: CGFloat = 48
            let pillsTopPadding: CGFloat = 6
            let chromeHeight = safeTop + pillRowHeight + pillsTopPadding
            
            ZStack(alignment: .top) {
                TopChromeBackground(accent: Color(red: 0.72, green: 0.78, blue: 0.38))
                    .frame(height: chromeHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .overlay {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .mask(
                                LinearGradient(
                                    colors: [Color.black, Color.black.opacity(0.0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                
                HStack(spacing: 10) {
                    chromePill("Alle", active: true)
                    chromePill("Spotify", active: false)
                    chromePill("MacRumours", active: false)
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.top, safeTop + pillsTopPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))
        }
    }
    
    private func chromePill(_ title: String, active: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(active ? Color.black.opacity(0.18) : Color.white.opacity(0.08))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(active ? 0.35 : 0.18), lineWidth: 1)
            )
            .foregroundStyle(Color.white.opacity(active ? 0.95 : 0.8))
    }
}

#Preview("Top Chrome") {
    TopChromePreview()
        .frame(height: 180)
        .preferredColorScheme(.dark)
}


// MARK: - Feed Management Logic

extension FeedListView {
    private func scheduleFeedsReload() {
        feedsReloadTask?.cancel()
        feedsReloadTask = Task { @MainActor in
            // Coalesce rapid feed list mutations (add/edit/delete in quick succession).
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await loadRSSFeed()
        }
    }

    @MainActor
    func loadRSSFeed() async {
        isLoading = true
        feedLoadErrorsByID = [:]
        
        let feedsSnapshot = feeds
        let loadingIDs = Set(feedsSnapshot.map { $0.id })
        loadingFeedIDs = loadingIDs
        var newEntries: [FeedEntry] = []
        
        await withTaskGroup(of: (FeedSource, FeedFetchStatus).self) { group in
            for feed in feedsSnapshot {
                group.addTask {
                    let status = await fetchFeed(feed)
                    return (feed, status)
                }
            }
            
            for await (feed, status) in group {
                await MainActor.run {
                    _ = loadingFeedIDs.remove(feed.id)
                }
                if let error = status.error {
                    feedLoadErrorsByID[feed.id] = error
                }
                let enrichedEntries: [FeedEntry] = status.entries.map { entry in
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
                            summary: entry.content,
                            feedTitle: feed.title
                        )
                    }
                    store.mergeArticles(storedArticles, for: feed.url)
                }
                
                newEntries.append(contentsOf: enrichedEntries)
            }
        }
        
        let readIDs = store.readArticleIDs
        var existingIndexByLink: [String: Int] = Dictionary(
            uniqueKeysWithValues: entries.enumerated().map { ($0.element.link, $0.offset) }
        )

        withTransaction(Transaction(animation: .easeInOut(duration: 0.2))) {
            for newEntry in newEntries {
                if let existingIndex = existingIndexByLink[newEntry.link] {
                    var existing = entries[existingIndex]
                    existing.title = newEntry.title
                    existing.content = newEntry.content
                    existing.imageURL = newEntry.imageURL
                    existing.author = newEntry.author
                    existing.pubDateString = newEntry.pubDateString
                    existing.feedURL = newEntry.feedURL ?? existing.feedURL
                    existing.sourceTitle = newEntry.sourceTitle ?? existing.sourceTitle
                    existing.isRead = readIDs.contains(existing.link)
                    entries[existingIndex] = existing
                } else {
                    var fresh = newEntry
                    fresh.isRead = readIDs.contains(fresh.link)
                    existingIndexByLink[fresh.link] = entries.count
                    entries.append(fresh)
                }
            }
        }
        
        sortAllEntriesGlobally()
        persistEntriesCache()
        bumpListAppearToken()
        
        loadingFeedIDs.removeAll()
        isLoading = false
        lastRefreshDate = Date()
        pushSnapshotToWatch()
        Task { @MainActor in
            refreshBookmarkedLinks()
        }
    }
    
    private func bumpListAppearToken() {
        listAppearToken = UUID()
    }
    
    func fetchFeed(_ feed: FeedSource) async -> FeedFetchStatus {
        await feedClient.fetch(feed: feed)
    }
    
    private func persistEntriesCache() {
        guard let data = try? Self.cacheEncoder.encode(entries) else { return }

        FeedCacheSync.write(data, for: FeedStorage.Keys.cachedEntries)
        cachedEntriesData = data
    }
    
    private func restoreCachedEntries() {
        if let bestData = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.cachedEntries),
           bestData != cachedEntriesData {
            cachedEntriesData = bestData
        }
        guard !cachedEntriesData.isEmpty else { return }
        if var cached = try? Self.cacheDecoder.decode([FeedEntry].self, from: cachedEntriesData) {
            for index in cached.indices {
                cached[index].isRead = store.isRead(articleID: cached[index].link)
            }
            entries = cached
            recentlyReadLinks.removeAll()
            sortAllEntriesGlobally()
            pruneEntriesForRemovedFeeds()
            pushSnapshotToWatch()
        }
    }
    
    private func filteredEntries(for selectedFeedID: String) -> [FeedEntry] {
        let activeFeedIDs = selectedFeedIDs.isEmpty ? Set(feeds.map { $0.id }) : selectedFeedIDs
        let feedFilteredEntries = entries.filter { entry in
            guard let id = feedSource(for: entry)?.id else { return false }
            guard activeFeedIDs.contains(id) else { return false }
            guard selectedFeedID != FeedFilterSelection.all else { return true }
            return id == selectedFeedID
        }
        let bookmarkFilteredEntries = showOnlyBookmarks
        ? feedFilteredEntries.filter { bookmarkedLinks.contains($0.link) }
        : feedFilteredEntries
        
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            return bookmarkFilteredEntries.filter { entry in
                let title = entry.title.lowercased()
                let summary = entry.content.lowercased()
                let author = (entry.author ?? "").lowercased()
                return title.contains(q) || summary.contains(q) || author.contains(q)
            }
        } else if showUnreadOnly {
            return bookmarkFilteredEntries.filter { !$0.isRead || recentlyReadLinks.contains($0.link) }
        } else {
            return bookmarkFilteredEntries
        }
    }

    var filteredEntries: [FeedEntry] {
        filteredEntries(for: activeFeedTabID)
    }
    
    @MainActor
    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "notifeeder" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        guard host == "article" || path == "/article" else { return }
        let linkValue = components?.queryItems?.first(where: { $0.name == "link" || $0.name == "url" })?.value
        guard let rawLink = linkValue, !rawLink.isEmpty else { return }
        openArticle(link: rawLink)
    }
    
    @MainActor
    private func openArticle(link: String) {
        guard var entry = resolveEntry(by: link) else { return }
        entry.sourceTitle = feedTitle(for: entry)
        entry.feedURL = feedSource(for: entry)?.url
        
        if !entry.isRead {
            recentlyReadLinks.insert(entry.link)
            store.setRead(true, articleID: entry.link)
            if let idx = entries.firstIndex(where: { $0.link == entry.link }) {
                entries[idx].isRead = true
                persistEntriesCache()
                pushSnapshotToWatch()
            }
        }
        
        if path.isEmpty {
            path.append(entry)
        } else {
            path[path.count - 1] = entry
        }
    }
    
    private func resolveEntry(by link: String) -> FeedEntry? {
        if let entry = entries.first(where: { $0.link == link }) {
            return entry
        }
        guard !cachedEntriesData.isEmpty else { return nil }
        if let cached = try? Self.cacheDecoder.decode([FeedEntry].self, from: cachedEntriesData) {
            return cached.first(where: { $0.link == link })
        }
        return nil
    }
    
    private func triggerLightHaptic() {
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
#endif
    }

    private func closeSearchFromToolbar() {
        guard !isClosingSearch else { return }
        isClosingSearch = true
        withAnimation(.easeInOut(duration: 0.14)) {
            isToolbarSearchFocused = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.easeInOut(duration: 0.2)) {
                searchText = ""
                isSearching = false
            }
            isClosingSearch = false
        }
    }

    @MainActor
    private func handleWatchRefreshRequest() async {
        guard !isLoading else { return }
        await loadRSSFeed()
    }

    @MainActor
    private func pushSnapshotToWatch() {
        PhoneWatchSyncManager.shared.pushSnapshot(
            feeds: feeds,
            entries: entries,
            readIDs: store.readArticleIDs,
            lastRefreshDate: lastRefreshDate
        )
    }

    private func filterMenuButton(size: CGFloat) -> some View {
        let iconSize = max(14, size * 0.45)
        let hasActiveQuickFilter = showOnlyBookmarks || showUnreadOnly || showDummyFilterTwo
        return Menu {
            ControlGroup {
                Button {
                    triggerLightHaptic()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if showOnlyBookmarks {
                            setQuickFilterMode(bookmarks: false, unreadOnly: false, dummyTwo: false)
                        } else {
                            setQuickFilterMode(bookmarks: true, unreadOnly: false, dummyTwo: false)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showOnlyBookmarks ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(iconTint(active: showOnlyBookmarks))
                        Text("Lesezeichen")
                    }
                }

                Button {
                    triggerLightHaptic()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if showUnreadOnly {
                            setQuickFilterMode(bookmarks: false, unreadOnly: false, dummyTwo: false)
                        } else {
                            setQuickFilterMode(bookmarks: false, unreadOnly: true, dummyTwo: false)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showUnreadOnly ? "eye.fill" : "eye")
                            .foregroundStyle(iconTint(active: showUnreadOnly))
                        Text("Ungelesen")
                    }
                }

                Button {
                    triggerLightHaptic()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if showDummyFilterTwo {
                            setQuickFilterMode(bookmarks: false, unreadOnly: false, dummyTwo: false)
                        } else {
                            setQuickFilterMode(bookmarks: false, unreadOnly: false, dummyTwo: true)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showDummyFilterTwo ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(iconTint(active: showDummyFilterTwo))
                        Text("Dummy 2")
                    }
                }
            }

            Divider()

            Section("Feeds"){
                ForEach(feeds) { feed in
                    let isSelected = selectedFeedIDs.contains(feed.id)
                    Button {
                        triggerLightHaptic()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if selectedFeedIDs.contains(feed.id) {
                                selectedFeedIDs.remove(feed.id)
                            } else {
                                selectedFeedIDs.insert(feed.id)
                            }
                            if selectedFeedIDs.isEmpty {
                                selectedFeedIDs = Set(feeds.map { $0.id })
                            }
                        }
                    } label: {
                        HStack {
                            Text(feedDisplayTitle(for: feed))
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: activeFilterIconName)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(iconTint(active: hasActiveQuickFilter))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .minimumHitTarget(size)
        .accessibilityLabel("Filtermenü")
        .accessibilityHint("Filter nach Feed oder Zustand auswählen")
    }

    private var activeFilterIconName: String {
        if showOnlyBookmarks { return "bookmark.fill" }
        if showUnreadOnly { return "eye.fill" }
        if showDummyFilterTwo { return "2.circle.fill" }
        return "line.3.horizontal.decrease"
    }

    private func iconTint(active: Bool) -> Color {
        UIStylePolicy.iconTint(isActive: active, accent: theme.uiAccentColor)
    }

    private func setQuickFilterMode(bookmarks: Bool, unreadOnly: Bool, dummyTwo: Bool) {
        showOnlyBookmarks = bookmarks
        showUnreadOnly = unreadOnly
        showDummyFilterTwo = dummyTwo
    }

    private func updateFeed(original: FeedSource, updated: FeedSource) {
        guard let idx = feeds.firstIndex(where: { $0.url == original.url }) else { return }
        if original.url != updated.url {
            theme.resetColor(for: original.url)
        }
        feeds[idx] = updated
        if let data = try? JSONEncoder().encode(feeds) {
            savedFeedsData = data
        }
    }
    
    private func feedDisplayTitle(for feed: FeedSource) -> String {
        let trimmed = feed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let host = URL(string: feed.url)?.host {
            return host
        }
        return feed.url
    }

    private func entryRowAccessibilityValue(feedName: String,
                                            isRead: Bool,
                                            isBookmarked: Bool,
                                            date: Date) -> String {
        var parts: [String] = [feedName, isRead ? "gelesen" : "ungelesen"]
        if isBookmarked {
            parts.append("Lesezeichen")
        }
        if date != Date.distantPast {
            parts.append(DateFormatter.localized.string(from: date))
        }
        return parts.joined(separator: ", ")
    }

    func markAsRead(_ entry: FeedEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            withAnimation(.easeInOut(duration: 0.18)) {
                entries[index].isRead = true
                recentlyReadLinks.insert(entry.link)
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
    }
}

struct FeedsSettingsViewPlaceholder: View {
    @AppStorage("savedFeeds", store: FeedStorage.defaults) private var savedFeedsData: Data = Data()
    @State private var feeds: [FeedSource] = []
    @State private var showAddFeedSheet: Bool = false
    
    @State private var selectedFeed: FeedSource? = nil
    @State private var selectedIndex: Int? = nil
    
    @EnvironmentObject private var theme: ThemeSettings
    
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
                                CachedFeedFaviconView(feedURLString: feed.url)
                                    .frame(width: 32, height: 32)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feed.title).font(.body)
                                    Text(feed.url).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    if let idx = feeds.firstIndex(where: { $0.url == feed.url }) {
                                        selectedIndex = idx
                                        selectedFeed = feed
                                    }
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .tint(theme.uiAccentColor)
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
            .sheetCornerAlignedScrollContent()
            .sheet(isPresented: $showAddFeedSheet) {
                AddSingleFeedView { newItem in
                    guard let item = newItem else { return }
                    feeds.append(item)
                    persistFeeds()
                }
                .environmentObject(theme)
                .presentationDetents([UIStylePolicy.Sheet.mediumDetent])
            }
            .sheet(item: $selectedFeed, onDismiss: {
                selectedFeed = nil
                selectedIndex = nil
            }) { feedToEdit in
                let currentColor = theme.color(for: feedToEdit.url)
                EditSingleFeedView(feed: feedToEdit, initialColor: currentColor) { updated in
                    guard let updated = updated else { return }
                    if let idx = selectedIndex {
                        feeds[idx] = updated
                        persistFeeds()
                    }
                }
                .environmentObject(theme)
                .presentationDetents([UIStylePolicy.Sheet.compactDetent])
                .interactiveDismissDisabled(false)
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

private struct CachedFeedFaviconView: View {
    let feedURLString: String
    @State private var image: Image? = nil
    @State private var isLoading = false
    
    var body: some View {
        Group {
            if let image = image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                Circle()
                    .fill(Color.gray.opacity(0.25))
                    .overlay {
                        Text(initialLetter)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    .onAppear {
                        loadFavicon()
                    }
            }
        }
    }
    
    private var initialLetter: String {
        let trimmed = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URL(string: trimmed)?.host, let first = host.first {
            return String(first).uppercased()
        }
        return "•"
    }
    
    private func loadFavicon() {
        guard !isLoading else { return }
        guard let feedURL = URL(string: feedURLString) else { return }
        isLoading = true
        
        if let cached = FaviconCache.cachedImageAllowingStale(for: feedURL) {
            image = Image(uiImage: cached)
        }
        
        let needsRefresh: Bool = {
            guard let modified = FaviconCache.cachedModificationDate(for: feedURL) else { return true }
            return FaviconCache.needsRefresh(since: modified, threshold: FaviconCache.refreshInterval)
        }()
        
        guard needsRefresh else { return }
        
        Task {
            if let uiImage = await FaviconCache.downloadAndCacheFavicon(from: feedURL) {
                await MainActor.run {
                    image = Image(uiImage: uiImage)
                }
            }
        }
    }
}

// New helper view for adding a single feed
struct AddSingleFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeSettings
    @State private var title: String = ""
    @State private var urlString: String = ""
    @State private var selectedColor: Color = FeedColorOption.palette.first?.color ?? Color(red: 0.78, green: 0.88, blue: 0.97)
    @State private var selectedOption: FeedColorOption? = FeedColorOption.palette.first
    let onAdd: (FeedSource?) -> Void
    
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
                        ForEach(FeedColorOption.palette) { option in
                            ZStack {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 28, height: 28)
                                
                                if selectedOption == option {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.bold()) // Etwas fetter wirkt oft hochwertiger
                                        .foregroundStyle(.black.opacity(0.7))
                                }
                            }
                            .contentShape(Circle()) // Verbessert die Treffzone für Taps
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedOption = option
                                    selectedColor = option.color
                                }
                            }
                        }
                        
                        // Der ColorPicker direkt daneben
                        ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                            .labelsHidden()
                            .fixedSize() // Verhindert, dass der Picker unnötig Platz einnimmt
                            .onChange(of: selectedColor) { _, newValue in
                                let hex = newValue.toHex()?.lowercased()
                                if let hex, let match = FeedColorOption.palette.first(where: { $0.hex.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#")) == hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }) {
                                    selectedOption = match
                                } else {
                                    selectedOption = nil
                                }
                            }
                        
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Feed hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .tint(theme.uiAccentColor)
            .sheetCornerAlignedScrollContent()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() }label:{Image(systemName: "xmark")}
                }
                
                
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let draft = FeedDraft(title: title, url: urlString)
                        guard let feed = draft.makeFeedSource(requireValidURL: true, fallbackTitleToURL: true) else {
                            onAdd(nil)
                            dismiss()
                            return
                        }
                        if let hex = selectedColor.toHex() {
                            theme.setColorHex(hex, for: feed.url)
                        }
                        onAdd(feed)
                        dismiss()
                    }label:{Image(systemName: "checkmark")}
                        .disabled(FeedDraft(title: title, url: urlString).trimmedURL.isEmpty)
                }
            }
        }
    }
}


struct EditSingleFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeSettings
    @State private var title: String
    @State private var urlString: String
    @State private var selectedColor: Color
    @State private var selectedOption: FeedColorOption? = nil
    
    let onSave: (FeedSource?) -> Void
    
    init(feed: FeedSource, initialColor: Color, onSave: @escaping (FeedSource?) -> Void) {
        _title = State(initialValue: feed.title)
        _urlString = State(initialValue: feed.url)
        _selectedColor = State(initialValue: initialColor)
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
                Section("Farbe") {
                    let options = FeedColorOption.defaultPalette
                    
                    HStack(spacing: 12) {
                        ForEach(options) { option in
                            ZStack {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if selectedOption == option {
                                            Circle().stroke(theme.uiAccentColor, lineWidth: 3)
                                        }
                                    }
                                
                                if selectedOption == option {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.black.opacity(0.7))
                                }
                            }
                            .contentShape(Circle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedOption = option
                                    selectedColor = option.color
                                }
                                let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                                if let url = URL(string: trimmedURL), !trimmedURL.isEmpty {
                                    theme.setColor(option, for: url.absoluteString)
                                }
                            }
                            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                        }
                    }
                }
            }
            .navigationTitle("Feed bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .tint(theme.uiAccentColor)
            .sheetCornerAlignedScrollContent()
            .onAppear {
                let mapping = FeedColorOption.defaultPalette
                if let match = mapping.first(where: { $0.hex.lowercased() == selectedColor.toHex()?.lowercased() }) {
                    selectedOption = match
                } else {
                    selectedOption = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let draft = FeedDraft(title: title, url: urlString)
                        guard let updated = draft.makeFeedSource(requireValidURL: true, fallbackTitleToURL: true) else {
                            onSave(nil)
                            dismiss()
                            return
                        }
                        onSave(updated)
                        dismiss()
                    } label: { Image(systemName: "checkmark") }
                        .disabled(FeedDraft(title: title, url: urlString).trimmedURL.isEmpty)
                }
            }
        }
    }
}

struct PersonalizationViewPlaceholder: View {
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage("ui.cards.previewLines") private var previewLines: Int = 3
    @AppStorage("ui.cards.style.fullColor") private var fullColorCards: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Widgets") {
                    NavigationLink {
                        WidgetSettingsView()
                            .environmentObject(theme)
                    } label: {
                        Label("Hintergrund & Transparenz", systemImage: "square.grid.2x2")
                    }
                }
                
                Section("Kacheln") {
                    Stepper(value: $previewLines, in: 0...6) {
                        Label("Anzahl Vorschauzeilen: \(previewLines)", systemImage: "text.justify.left")
                    }
                    Toggle(isOn: $fullColorCards) {
                        Label("Vollflächige Kacheln", systemImage: fullColorCards ? "rectangle.inset.filled" :"rectangle")
                    }
                }
            }
            .navigationTitle("Personalisierung")
            .navigationBarTitleDisplayMode(.inline)
            .navigationLinkIndicatorVisibility(.visible)
            .sheetCornerAlignedScrollContent()
        }
    }
}

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
            .sheetCornerAlignedScrollContent()
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
