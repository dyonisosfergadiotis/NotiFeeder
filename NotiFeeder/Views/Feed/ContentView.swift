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
        .tint(theme.uiAccentColor)
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
            FeedStorage.migrateIfNeeded()
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
                .presentationDetents([.fraction(0.45)])
        }
        .sheet(isPresented: $showPersonalizationSheet) {
            PersonalizationViewPlaceholder()
                .environmentObject(theme)
                .presentationDetents([.fraction(0.5)])
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
    
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var lastRefreshDate: Date? = nil
    @State private var bookmarkedLinks: Set<String> = []
    @State private var recentlyReadLinks: Set<String> = [] // Tracks items opened this session; items are READ + RECENT, visible until next refresh/app open
    @State private var listAppearToken = UUID()
    @State private var lastScrollOffset: CGFloat = 0
    @State private var lastScrollTime: TimeInterval = 0
    @State private var scrollSpeed: Double = 0
    @State private var lastHapticTime: TimeInterval = 0
    
    private let maxArticlesPerFeed = 100
    private let feedPillRowHeight: CGFloat = 34
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
            //.background(Color(.systemGroupedBackground))
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
    
    private struct FeedPageTab: Identifiable {
        let id: String
        let title: String
        let systemImage: String
    }

    private var feedPageTabs: [FeedPageTab] {
        var tabs: [FeedPageTab] = [
            FeedPageTab(id: FeedFilterSelection.all, title: "Alle", systemImage: "square.grid.2x2")
        ]
        tabs.append(contentsOf: feeds.map { feed in
            FeedPageTab(
                id: feed.id,
                title: feedDisplayTitle(for: feed),
                systemImage: feedInitialSymbolName(for: feed)
            )
        })
        return tabs
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AccentBackground(accent: theme.uiAccentColor)
                    .ignoresSafeArea()
                
                feedListView(for: activeFeedTabID)
                
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar{ feedToolbar }.tint(theme.uiAccentColor)
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(item: $feedToEdit, onDismiss: {
                feedToEdit = nil
            }) { feed in
                EditSingleFeedView(feed: feed, initialColor: theme.color(for: feed.url)) { updated in
                    guard let updated = updated else { return }
                    updateFeed(original: feed, updated: updated)
                }
                .environmentObject(theme)
                .presentationDetents([.fraction(0.45)])
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
            showBookmarkFilterPill = !bookmarkedLinks.isEmpty
            triggerInitialLoadIfPossible()
            pruneEntriesForRemovedFeeds()
            Task { @MainActor in
                refreshBookmarkedLinks()
            }
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
                bumpListAppearToken()
            }
        }
        .onChange(of: feeds) { oldValue, newValue in
            let validIDs = Set(newValue.map { $0.id })
            if activeFeedTabID != FeedFilterSelection.all && !validIDs.contains(activeFeedTabID) {
                activeFeedTabID = FeedFilterSelection.all
            }
            pruneEntriesForRemovedFeeds()
            Task { @MainActor in
                await loadRSSFeed()
            }
        }
        .onChange(of: activeFeedTabID) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                // Trigger list diffing animation on filteredEntries changes
                bumpListAppearToken()
            }
        }
        .onChange(of: showUnreadOnly) { oldValue, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                // Trigger list diffing animation on filteredEntries changes
                bumpListAppearToken()
            }
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
        .onChange(of: searchText) { oldValue, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                bumpListAppearToken()
            }
        }
        .onChange(of: path) { oldValue, newValue in
            // When navigating back from detail, resync read flags from the store so filters update immediately
            for idx in entries.indices {
                entries[idx].isRead = store.isRead(articleID: entries[idx].link)
            }
            persistEntriesCache()
        }
        .onOpenURL { url in
            Task { @MainActor in
                handleDeepLink(url)
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

    private var topChromeOverlay: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let chromeHeight = safeTop + 10
            let blurHeight: CGFloat = 24
            
            ZStack(alignment: .top) {
                TopChromeBackground(accent: theme.uiAccentColor)
                    .frame(height: chromeHeight)
                    .frame(maxWidth: .infinity,maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .overlay {
                        // iOS-like top blur: strongest at the top, fades out towards the pills.
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .frame(height: blurHeight)
                            .mask(
                                LinearGradient(
                                    colors: [Color.black, Color.black.opacity(0.0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .allowsHitTesting(false)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .ignoresSafeArea(.container, edges: .top)
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
                        .foregroundStyle(theme.uiAccentColor)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            if showBookmarkFilterPill {
                ToolbarSpacer(.fixed, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    bookmarkFilterPill(size: 36)
                        .transition(
                            .asymmetric(
                                insertion: .offset(x: 8).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                }
            }
        } else {
            ToolbarItem(placement: .bottomBar) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.uiAccentColor)
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
                                .foregroundStyle(.secondary)
                                .tint(theme.uiAccentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    closeSearchFromToolbar()
                } label: {
                    Image(systemName: "xmark")
                }
                .tint(theme.uiAccentColor)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
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
        ToolbarSpacer(.fixed,placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showUnreadOnly.toggle()
                }
            } label: {
                ZStack {
                    VStack(spacing: 2.5) {
                        Capsule().frame(width: 14, height: 2)
                        Capsule().frame(width: 10, height: 2)
                        Capsule().frame(width: 6, height: 2)
                    }
                    .foregroundStyle(theme.uiAccentColor.opacity(0.28))
                    
                    VStack(spacing: 2.5) {
                        Capsule().frame(width: 14, height: 2)
                        Capsule().frame(width: 10, height: 2)
                        Capsule().frame(width: 6, height: 2)
                    }
                    .foregroundStyle(theme.uiAccentColor)
                    .mask(
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .frame(height: showUnreadOnly ? 12 : 0)
                        }
                    )
                    .animation(.easeInOut(duration: 0.2), value: showUnreadOnly)
                }
                .frame(width: 23, height: 18)
            }
            .accessibilityLabel(showUnreadOnly ? "Nur ungelesene" : "Alle Artikel")
            .tint(theme.uiAccentColor)
        }
        ToolbarItem(placement: .topBarTrailing){
            Menu {
                Text("Sortieren nach:")
                Button {
                    guard sortOption != "Neueste zuerst" else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sortOption = "Neueste zuerst"
                    }
                } label: {
                    Label("Neueste zuerst", systemImage: "arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                
                Button {
                    guard sortOption != "Älteste zuerst" else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        sortOption = "Älteste zuerst"
                    }
                } label: {
                    Label("Älteste zuerst", systemImage: "arrow.up")
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
    
    private var totalUnreadCount: Int {
        unreadCountsByFeedID.values.reduce(0, +)
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
                        yOffset: 6,
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
            colors: [
                accent.opacity(colorScheme == .dark ? 0.22 : 0.16),
                accent.opacity(colorScheme == .dark ? 0.12 : 0.08),
                Color(.systemBackground)
            ],
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
            colors: [
                accent.opacity(colorScheme == .dark ? 0.22 : 0.16),
                accent.opacity(colorScheme == .dark ? 0.01 : 0.01),
                accent.opacity(colorScheme == .dark ? 0.01 : 0.01),
                accent.opacity(colorScheme == .dark ? 0.01 : 0.01),
            ],
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
    @MainActor
    func loadRSSFeed() async {
        isLoading = true
        
        let feedsSnapshot = feeds
        let loadingIDs = Set(feedsSnapshot.map { $0.id })
        loadingFeedIDs = loadingIDs
        var newEntries: [FeedEntry] = []
        
        await withTaskGroup(of: (FeedSource, [FeedEntry]).self) { group in
            for feed in feedsSnapshot {
                group.addTask {
                    let entries = await fetchFeed(feed)
                    return (feed, entries)
                }
            }
            
            for await (feed, result) in group {
                await MainActor.run {
                    loadingFeedIDs.remove(feed.id)
                }
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
                            summary: entry.content,
                            feedTitle: feed.title
                        )
                    }
                    store.mergeArticles(storedArticles, for: feed.url)
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
        bumpListAppearToken()
        
        loadingFeedIDs.removeAll()
        isLoading = false
        Task { @MainActor in
            refreshBookmarkedLinks()
        }
    }
    
    private func bumpListAppearToken() {
        listAppearToken = UUID()
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
    
    private func persistEntriesCache() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        
        // 1) Persist locally (keeps existing behavior)
        cachedEntriesData = data
        
        // 2) Also persist to App Group so the widget can read it
        if let defaults = UserDefaults(suiteName: "group.notiFeeder") {
            defaults.set(data, forKey: "cachedEntries")
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
    
    private func filteredEntries(for selectedFeedID: String) -> [FeedEntry] {
        let feedFilteredEntries = entries.filter { entry in
            guard selectedFeedID != FeedFilterSelection.all else { return true }
            guard let id = feedSource(for: entry)?.id else { return false }
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cached = try? decoder.decode([FeedEntry].self, from: cachedEntriesData) {
            return cached.first(where: { $0.link == link })
        }
        return nil
    }
    
    private func feedFilterButton(
        title: String,
        id: String,
        color: Color,
        unreadCount: Int,
        isLoading: Bool,
        systemIconName: String? = nil,
        onLongPress: (() -> Void)?
    ) -> some View {
        let isAllSelected = !feeds.isEmpty && selectedFeedIDs.count == feeds.count
        let isSelected = id == FeedFilterSelection.all ? isAllSelected : selectedFeedIDs.contains(id)
        let textOpacity = isSelected ? 1.0 : 0.5
        let fillOpacity = isSelected ? 0.2 : 0.08
        let strokeOpacity = isSelected ? 0.1 : 0.05
        let saturation = isSelected ? 1.0 : 0.25
        return Button {
            triggerLightHaptic()
            withAnimation(.easeInOut(duration: 0.2)) {
                if id == FeedFilterSelection.all {
                    selectedFeedIDs = Set(feeds.map { $0.id })
                } else {
                    if selectedFeedIDs.contains(id) {
                        selectedFeedIDs.remove(id)
                    } else {
                        selectedFeedIDs.insert(id)
                    }
                    if selectedFeedIDs.isEmpty {
                        selectedFeedIDs = Set(feeds.map { $0.id })
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let systemIconName {
                    Image(systemName: systemIconName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color.opacity(textOpacity))
                        .frame(width: 18, height: 18)
                } else {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color.opacity(textOpacity))
                }
                if isLoading {
                    ZStack {
                        Capsule()
                            .fill(color.opacity(isSelected ? 0.22 : 0.12))
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(color.opacity(textOpacity))
                            .scaleEffect(0.72)
                    }
                    .frame(width: 22, height: 18)
                    .overlay(
                        Capsule()
                            .stroke(color.opacity(isSelected ? 0.16 : 0.08), lineWidth: 0.8)
                    )
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                } else if unreadCount > 0 {
                    Text("\(unreadCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color.opacity(textOpacity))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(color.opacity(isSelected ? 0.22 : 0.12))
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isLoading)
            .animation(.easeInOut(duration: 0.18), value: unreadCount)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(color.opacity(fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(color.opacity(strokeOpacity), lineWidth: 1)
            )
            .glassEffect()
            .saturation(saturation)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Feed: \(title)")
        .onLongPressGesture(minimumDuration: 0.35) {
            triggerLightHaptic()
            onLongPress?()
        }
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

    private func bookmarkFilterPill(size: CGFloat) -> some View {
        let isActive = showOnlyBookmarks
        let iconSize = max(14, size * 0.4)
        return Button {
            triggerLightHaptic()
            withAnimation(.easeInOut(duration: 0.2)) {
                showOnlyBookmarks.toggle()
            }
        } label: {
            ZStack {
                Image(systemName: "bookmark")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(theme.uiAccentColor.opacity(isActive ? 0.7 : 0.6))
                Image(systemName: "bookmark.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(theme.uiAccentColor)
                    .mask(
                        VStack(spacing: 0) {
                            Rectangle()
                                .frame(height: isActive ? size : 0)
                            Spacer(minLength: 0)
                        }
                        .frame(width: size, height: size)
                    )
                    .animation(.easeInOut(duration: 0.22), value: isActive)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "Nur Lesezeichen" : "Alle Artikel")
    }

    private func readFilterPill(size: CGFloat) -> some View {
        return Button {
            triggerLightHaptic()
            withAnimation(.easeInOut(duration: 0.2)) {
                showUnreadOnly.toggle()
            }
        } label: {
            let delays: [Double] = showUnreadOnly ? [0.12, 0.06, 0.0] : [0.0, 0.06, 0.12]
            VStack(spacing: 3) {
                Capsule()
                    .frame(width: 20, height: 3)
                    .opacity(showUnreadOnly ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.16).delay(delays[0]), value: showUnreadOnly)
                Capsule()
                    .frame(width: 16, height: 3)
                    .opacity(showUnreadOnly ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.16).delay(delays[1]), value: showUnreadOnly)
                Capsule()
                    .frame(width: 12, height: 3)
                    .opacity(showUnreadOnly ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.16).delay(delays[2]), value: showUnreadOnly)
            }
            .foregroundStyle(theme.uiAccentColor.opacity(showUnreadOnly ? 1.0 : 0.6))
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showUnreadOnly ? "Nur ungelesene" : "Alle Artikel")
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

    private func feedInitialLetter(for feed: FeedSource) -> String {
        let title = feed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = title.first(where: { $0.isLetter || $0.isNumber }) {
            return String(first).uppercased()
        }
        if let host = URL(string: feed.url)?.host,
           let first = host.first(where: { $0.isLetter || $0.isNumber }) {
            return String(first).uppercased()
        }
        return "•"
    }

    private func feedInitialSymbolName(for feed: FeedSource) -> String {
        let letter = feedInitialLetter(for: feed).lowercased()
        if let scalar = letter.unicodeScalars.first,
           scalar.value >= 97, scalar.value <= 122 {
            return "\(letter).circle"
        }
        if let scalar = letter.unicodeScalars.first,
           scalar.value >= 48, scalar.value <= 57 {
            return "\(letter).circle"
        }
        return "circle"
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
                .environmentObject(theme)
                .presentationDetents([.fraction(0.5)])
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
                .presentationDetents([.fraction(0.45)])
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
                        if let hex = selectedColor.toHex() {
                            theme.setColorHex(hex, for: url.absoluteString)
                        }
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
    private var colors: [Color] {
        var base = FeedColorOption.defaultPalette.map { $0.color }
        // Ensure white is available in the accent palette as well
        base.append(Color.white)
        return base
    }
    
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
