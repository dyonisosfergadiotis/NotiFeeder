import SwiftUI
import Foundation
import SwiftData
import Network
import QuartzCore
import UIKit
#if canImport(WidgetKit)
import WidgetKit
#endif

struct ContentView: View {
    @AppStorage("savedFeeds", store: FeedStorage.defaults) private var savedFeedsData: Data = Data()
    @EnvironmentObject private var theme: ThemeSettings
    @State private var feeds: [FeedSource] = []
    @State private var showOnboarding: Bool = false
    @AppStorage("didRunOnboarding") private var didRunOnboarding: Bool = false
    @AppStorage(UserProfileStore.displayNameKey) private var profileDisplayName: String = ""
    @State private var showSettingsSheet: Bool = false
    @State private var showProfileSetupSheet: Bool = false
    @State private var feedSettingsRefreshToken: Int = 0
    @State private var didRunStartupStorageSync: Bool = false

    @State private var searchText: String = ""


    @StateObject private var networkState = NetworkState()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "NetworkPathMonitorQueue")
    
    
    var body: some View {
        VStack {
            FeedListView(
                feeds: $feeds,
                savedFeedsData: $savedFeedsData,
                showSettingsSheet: $showSettingsSheet,
                searchText: $searchText,
                feedSettingsRefreshToken: feedSettingsRefreshToken
            )
        }
        .background(
            AccentBackground(accent: theme.uiAccentColor)
                .ignoresSafeArea()
        )
        .environmentObject(networkState)
        .sheet(isPresented: $showOnboarding) {
            let vm = OnboardingViewModel()
            OnboardingFlowView(viewModel: vm) { produced, colorHex in
                finishOnboarding(with: produced, colorHex: colorHex)
                showOnboarding = false
                didRunOnboarding = true
            }
            .environmentObject(theme)
            .presentationDetents([.large])
            .interactiveDismissDisabled(true)
        }
        .onAppear {
            loadFeeds(preferFastAppStorage: true)
            runStartupStorageSyncIfNeeded()
            if !didRunOnboarding && feeds.isEmpty {
                showOnboarding = true
            }
            evaluateProfileSetupPresentation()
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
        .onChange(of: savedFeedsData) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalSavedFeeds(newValue)
            loadFeeds()
        }
        .onChange(of: showOnboarding) { _, _ in
            evaluateProfileSetupPresentation()
        }
        .onChange(of: profileDisplayName) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(
                UserProfileStore.sanitizedDisplayName(newValue),
                for: FeedStorage.Keys.profileDisplayName
            )
            evaluateProfileSetupPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedSavedFeedsDidSyncFromICloud)) { _ in
            loadFeeds()
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(
                feeds: $feeds,
                savedFeedsData: $savedFeedsData,
                onFeedsDidChange: {
                    feedSettingsRefreshToken += 1
                }
            )
                .environmentObject(theme)
                .presentationDetents([.large])
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showProfileSetupSheet) {
            FirstLaunchProfileSetupView(initialName: profileDisplayName) { displayName in
                profileDisplayName = displayName
                showProfileSetupSheet = false
            }
            .presentationDetents([.fraction(0.42), .medium])
            .interactiveDismissDisabled(true)
        }
    }
    
    func loadFeeds(preferFastAppStorage: Bool = false) {
        let effectiveData: Data
        if preferFastAppStorage, !savedFeedsData.isEmpty {
            effectiveData = savedFeedsData
        } else {
            effectiveData = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.savedFeeds) ?? savedFeedsData
        }
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

    private func runStartupStorageSyncIfNeeded() {
        guard !didRunStartupStorageSync else { return }
        didRunStartupStorageSync = true

        Task.detached(priority: .utility) {
            FeedStorage.migrateIfNeeded()
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.savedFeeds)
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.cachedEntries)
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.feedColorMap)
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.savedArticles)
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.readArticleIDs)
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.bookmarkedArticleIDs)

            await MainActor.run {
                loadFeeds()
            }
        }
    }

    private func finishOnboarding(with produced: FeedSource?, colorHex: String?) {
        guard let produced else { return }

        if let colorHex {
            theme.setColorHex(colorHex, for: produced.url)
        }

        let sourceData = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.savedFeeds) ?? savedFeedsData
        var current = (try? JSONDecoder().decode([FeedSource].self, from: sourceData)) ?? []
        if let existingIndex = current.firstIndex(where: { $0.url == produced.url }) {
            current[existingIndex] = produced
        } else {
            current.append(produced)
            FeedStorage.includeFeedInWidgetSelection(produced.url)
        }

        guard let data = try? JSONEncoder().encode(current) else { return }
        let token = FeedCacheSync.write(data, for: FeedStorage.Keys.savedFeeds)
        savedFeedsData = data
        feeds = current
        FeedICloudSyncManager.shared.pushLocalData(data, token: token, for: FeedStorage.Keys.savedFeeds)
    }

    private var requiresProfileSetup: Bool {
        UserProfileStore.sanitizedDisplayName(profileDisplayName).isEmpty
    }

    private func evaluateProfileSetupPresentation() {
        showProfileSetupSheet = requiresProfileSetup && !showOnboarding
    }
}

struct FeedListView: View {
    private struct DaySectionEntry: Identifiable {
        let entry: FeedEntry
        let index: Int

        var id: String { entry.id }
    }

    private struct DaySection: Identifiable {
        let id: String
        let title: String
        let entries: [DaySectionEntry]
    }

    private struct FeedShortcutCounts {
        var total: Int = 0
        var unread: Int = 0
        var today: Int = 0
        var bookmarks: Int = 0
        var offline: Int = 0
    }

    private static let daySectionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    @Binding var feeds: [FeedSource]
    @Binding var savedFeedsData: Data
    @Binding var showSettingsSheet: Bool
    @Binding var searchText: String
    let feedSettingsRefreshToken: Int
    
    @EnvironmentObject private var store: ArticleStore
    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var networkState: NetworkState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @State private var cachedEntriesData: Data = Data()
    @State private var cachedEntriesSyncToken: Double = 0
    @AppStorage(UserProfileStore.avatarImageDataKey) private var profileAvatarData: Data = Data()
    
    @AppStorage("ui.cards.style.fullColor") private var fullColorCards: Bool = false
    
    @FocusState private var isToolbarSearchFocused: Bool
    
    @State private var entries: [FeedEntry] = []
    @State private var isLoading = false
    @State private var sortOption = "Neueste zuerst"
    @AppStorage("feed.filter.unreadOnly", store: FeedStorage.defaults) private var showUnreadOnly: Bool = false
    @AppStorage(FeedStorage.Keys.offlineRetainedFetchedArticleLimit, store: FeedStorage.defaults)
    private var offlineRetainedFetchedArticleLimitRaw: Int = OfflineArticleRetentionLimit.defaultValue.rawValue
    @State private var didTriggerInitialLoad = false
    @State private var activeArticle: FeedEntry?
    @State private var articleViewerAvailableWidth: CGFloat = 390
    @State private var didRestoreCachedEntries = false
    @State private var selectedFeedIDs: Set<String> = []
    @State private var didInitializeFeedSelection = false
    @State private var knownAvailableFeedIDs: Set<String> = []
    @State private var activeFeedTabID: String = FeedFilterSelection.all
    
    @State private var feedToEdit: FeedSource? = nil
    @State private var showOnlyBookmarks: Bool = false
    @State private var showTodayOnly: Bool = false
    @State private var showOfflineOnly: Bool = false
    
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var feedsReloadTask: Task<Void, Never>? = nil
    @State private var statusBarRefreshTask: Task<Void, Never>? = nil
    @State private var cloudStateSyncTask: Task<Void, Never>? = nil
    @State private var activationMaintenanceTask: Task<Void, Never>? = nil
    @State private var widgetTimelineReloadTask: Task<Void, Never>? = nil
    @State private var entriesCachePersistTask: Task<Void, Never>? = nil
    @State private var lastRefreshDate: Date? = nil
    @State private var lastSceneInactiveDate: Date? = nil
    @State private var lastActivationMaintenanceDate: Date? = nil
    @State private var bookmarkedLinks: Set<String> = []
    @State private var showBackToTopButton = false
    @State private var scrollToTopRequestToken = 0
    @State private var articleViewerDetent: PresentationDetent = .large
    @State private var isArticleViewerExpanded = false
    @State private var didRequestArticleMinimize = false
    @State private var activeArticleReadingProgress: CGFloat = 0
    @State private var isFeedPillOverlayPresented = false
    @State private var isSearchBarExpanded = false
    @State private var shouldFocusSearchOnExpand = false
    @State private var renderedEntryLimit: Int = 0
    @State private var lastRenderContextKey: String = ""
    @State private var didPrepareDerivedFeedState = false
    @State private var cachedFeedLookupMaps = FeedLookupMaps.empty
    @State private var cachedVisibleEntries: [FeedEntry] = []
    @State private var cachedFeedPillFeeds: [FeedSource] = []
    @State private var didInitialFeedLoad: Bool = false
    @State private var showAddFeedSheet: Bool = false
    @State private var didAttemptMinimizedArticleRestore: Bool = false
    @Namespace private var articleViewerMorphNamespace

    private let feedClient = FeedNetworkClient(maxRetries: 1, timeout: 8)
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
    private let initialRenderBatchSize: Int = 32
    private let renderBatchSize: Int = 24
    private let renderPrefetchThreshold: Int = 10
    private let entriesCachePersistDelayNanoseconds: UInt64 = 180_000_000
    private let minimumResumeMaintenanceInactiveAge: TimeInterval = 45
    private let minimumResumeMaintenanceInterval: TimeInterval = 5 * 60
    private let minimumActivationRefreshAge: TimeInterval = 10 * 60
    private let activationMaintenanceDelayNanoseconds: UInt64 = 1_200_000_000
    private let feedListTopAnchorID = "feed-list-top-anchor"

    private var recentlyReadLinks: Set<String> {
        store.recentlyReadArticleIDs
    }

    private func sortAllEntriesGlobally() {
        let sortedEntries = sortedAndLimitedEntries(entries)
        guard sortedEntries != entries else { return }
        entries = sortedEntries
    }

    private func sortedAndLimitedEntries(_ sourceEntries: [FeedEntry]) -> [FeedEntry] {
        var dateByLink: [String: Date] = [:]
        dateByLink.reserveCapacity(sourceEntries.count)
        for entry in sourceEntries {
            dateByLink[entry.link] = entry.parsedPubDate ?? .distantPast
        }

        let sortedEntries: [FeedEntry] = sourceEntries.sorted { lhs, rhs in
            let ld = dateByLink[lhs.link] ?? .distantPast
            let rd = dateByLink[rhs.link] ?? .distantPast
            switch sortOption {
            case "Neueste zuerst":
                return ld > rd
            default:
                return ld < rd
            }
        }

        guard maxArticlesPerFeed > 0 else {
            return sortedEntries
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
        
        return limitedEntries
    }
    
    private enum FeedFilterSelection {
        static let all = "__all__"
    }

    private var orderedFeedIDs: [String] {
        feeds.map(\.id)
    }

    private var validFeedIDs: Set<String> {
        Set(orderedFeedIDs)
    }

    private var resolvedSelectedFeedIDs: Set<String> {
        let availableIDs = validFeedIDs
        guard !availableIDs.isEmpty else { return [] }

        let currentSelection = selectedFeedIDs.intersection(availableIDs)
        if !didInitializeFeedSelection && currentSelection.isEmpty {
            return availableIDs
        }
        return currentSelection
    }

    private var feedPillFeeds: [FeedSource] {
        if didPrepareDerivedFeedState {
            return cachedFeedPillFeeds
        }
        return computeFeedPillFeeds(using: effectiveFeedLookupMaps)
    }
    
    private func feedListView(for selectedFeedID: String) -> some View {
        let lookup = effectiveFeedLookupMaps
        let visibleEntries = visibleEntriesForDisplay(selectedFeedID: selectedFeedID, lookup: lookup)
        let renderContextKey = renderContextKey(for: selectedFeedID)
        let effectiveLimit = effectiveRenderedEntryLimit(totalVisibleCount: visibleEntries.count)
        let displayedEntries = Array(visibleEntries.prefix(effectiveLimit))
        let hasMoreEntries = effectiveLimit < visibleEntries.count
        let prefetchIndex = max(0, effectiveLimit - renderPrefetchThreshold)
        let daySections = daySections(for: displayedEntries)
        let shortcutCounts = feedShortcutCounts(using: lookup)

        return ScrollViewReader { scrollProxy in
            ZStack(alignment: .top) {
                List {
                    Color.clear
                        .frame(height: 0)
                        .id(feedListTopAnchorID)
                        .feedListChromeRow()
                        .accessibilityHidden(true)

                    topVisibilitySentinel
                        .feedListChromeRow()

                    activeFilterStatusCard(counts: shortcutCounts, visibleCount: visibleEntries.count)
                        .feedListChromeRow()

                    ForEach(daySections) { section in
                        if section.title != "Heute" {
                            daySectionDividerRow(title: section.title)
                                .feedListChromeRow()
                        }

                        ForEach(section.entries) { dayEntry in
                            trackedEntryRow(
                                for: dayEntry.entry,
                                index: dayEntry.index,
                                lookup: lookup,
                                shouldLoadMore: hasMoreEntries && dayEntry.index == prefetchIndex,
                                totalVisibleCount: visibleEntries.count
                            )
                            .feedListArticleRow()
                        }
                    }

                    if visibleEntries.isEmpty {
                        Color.clear
                            .frame(height: 140)
                            .feedListChromeRow()
                            .accessibilityHidden(true)
                    }

                    if hasMoreEntries {
                        feedListLoadingRow
                            .feedListChromeRow()
                            .onAppear {
                                loadMoreEntriesIfNeeded(
                                    currentIndex: max(0, effectiveLimit - 1),
                                    totalVisibleCount: visibleEntries.count
                                )
                            }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .all)
                .environment(\.defaultMinListRowHeight, 0)
                .refreshable {
                    restoreSavedFeedsFromStorage()
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
                        guard !Task.isCancelled else { return }
                        withTransaction(Transaction(animation: .easeInOut(duration: 0.22))) {
                            // Keep the existing animation boundary, but await the actual refresh task.
                        }
                        await loadRSSFeed()
                        AppHaptics.success()
                    }
                    await refreshTask?.value
                    
                    // Promote recently-read to fully read on refresh
                    if !recentlyReadLinks.isEmpty {
                        let links = Array(recentlyReadLinks)
                        for link in links {
                            store.setRead(true, articleID: link)
                            if let idx = entries.firstIndex(where: { $0.link == link }) {
                                entries[idx].isRead = true
                                entries[idx].isNew = false
                            }
                        }
                        store.clearRecentlyRead()
                        persistEntriesCache()
                        pushSnapshotToWatch()
                    }
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 2, for: .scrollContent)
                .listStyle(.plain)
                .onAppear {
                    refreshRenderedEntryLimitIfNeeded(
                        contextKey: renderContextKey,
                        totalVisibleCount: visibleEntries.count
                    )
                }
                .onChange(of: renderContextKey) { _, newContextKey in
                    resetRenderedEntryLimit(
                        contextKey: newContextKey,
                        totalVisibleCount: visibleEntries.count
                    )
                }
                .onChange(of: visibleEntries.count) { _, newCount in
                    clampRenderedEntryLimit(totalVisibleCount: newCount)
                }
                .onChange(of: activeFeedTabID) { _, _ in
                    showBackToTopButton = false
                    syncSearchBarExpansionWithBackToTop(isBackToTopVisible: false)
                }
                .onChange(of: scrollToTopRequestToken) { _, _ in
                    showBackToTopButton = false
                    syncSearchBarExpansionWithBackToTop(isBackToTopVisible: false)
                    withAnimation(.easeInOut(duration: 0.22)) {
                        scrollProxy.scrollTo(feedListTopAnchorID, anchor: .top)
                    }
                }
                .onChange(of: visibleEntries.isEmpty) { _, isEmpty in
                    if isEmpty {
                        showBackToTopButton = false
                        syncSearchBarExpansionWithBackToTop(isBackToTopVisible: false)
                    }
                }
            }
        }
    }

    private func activeFilterStatusCard(counts: FeedShortcutCounts, visibleCount: Int) -> some View {
        let content = activeFilterStatusContent(counts: counts, visibleCount: visibleCount)

        return HStack(spacing: 12) {
            Image(systemName: content.iconName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.uiAccentColor)
                .frame(width: 34, height: 34)
                .background(theme.uiAccentColor.opacity(0.13), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(content.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(visibleCount)")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(theme.uiAccentColor)
                }

                Text(content.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.uiAccentColor.opacity(0.10), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .combine)
    }

    private func activeFilterStatusContent(counts: FeedShortcutCounts,
                                           visibleCount: Int) -> (title: String, subtitle: String, iconName: String) {
        if visibleCount == 0 {
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ("Keine Treffer", "Passe Suche oder aktiven Filter an, um wieder Artikel zu sehen.", "magnifyingglass")
            }

            switch activeQuickFilter {
            case .unread:
                return ("Alles gelesen", "Keine ungelesenen Artikel in der aktuellen Feed-Auswahl.", "checkmark.circle")
            case .bookmarks:
                return ("Nichts gespeichert", "Setze ein Lesezeichen per Swipe oder im Reader, dann erscheint es hier.", "bookmark")
            case .offline:
                return ("Nichts offline", "Öffne oder lade Artikel, damit NotiFeeder lokale Offline-Inhalte vorbereiten kann.", "arrow.down.circle")
            case .today:
                return ("Heute ruhig", "Für heute gibt es in deiner Auswahl keine passenden Artikel.", "calendar")
            case .none:
                return ("Keine Artikel", "Aktualisiere deine Feeds oder füge neue Quellen hinzu.", "tray")
            }
        }

        switch activeQuickFilter {
        case .unread:
            return ("Ungelesen", "\(counts.total) Artikel insgesamt, \(counts.bookmarks) gespeichert, \(counts.offline) offline verfügbar.", "eye")
        case .bookmarks:
            return ("Gespeichert", "\(counts.unread) davon ungelesen, \(counts.offline) offline verfügbar.", "bookmark")
        case .offline:
            return ("Offline", "\(counts.unread) ungelesen und \(counts.bookmarks) gespeichert sind lokal verfügbar.", "arrow.down.circle")
        case .today:
            return ("Heute", "\(counts.unread) ungelesen, \(counts.bookmarks) gespeichert, \(counts.offline) offline verfügbar.", "calendar")
        case .none:
            return ("Alle Artikel", "\(counts.unread) ungelesen, \(counts.bookmarks) gespeichert, \(counts.offline) offline verfügbar.", "line.3.horizontal.decrease")
        }
    }

    private func feedShortcutCounts(using lookup: FeedLookupMaps) -> FeedShortcutCounts {
        let sourceEntries = entriesMatchingSelection(
            for: FeedFilterSelection.all,
            includeSearch: false,
            lookup: lookup
        )

        var counts = FeedShortcutCounts()
        counts.total = sourceEntries.count
        for entry in sourceEntries {
            if matchesQuickFilter(entry, filter: .unread) {
                counts.unread += 1
            }
            if matchesQuickFilter(entry, filter: .today) {
                counts.today += 1
            }
            if matchesQuickFilter(entry, filter: .bookmarks) {
                counts.bookmarks += 1
            }
            if matchesQuickFilter(entry, filter: .offline) {
                counts.offline += 1
            }
        }

        return counts
    }

    private func daySections(for entries: [FeedEntry]) -> [DaySection] {
        guard !entries.isEmpty else { return [] }

        var sections: [DaySection] = []
        var currentKey: String?
        var currentTitle = ""
        var currentEntries: [DaySectionEntry] = []

        for (index, entry) in entries.enumerated() {
            let sectionEntry = DaySectionEntry(entry: entry, index: index)
            let keyDate = dayBucketDate(for: entry)
            let key = keyDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "__no_date__"
            let title = daySectionTitle(for: keyDate)

            if currentKey != key {
                if let currentKey {
                    sections.append(DaySection(id: currentKey, title: currentTitle, entries: currentEntries))
                }
                currentKey = key
                currentTitle = title
                currentEntries = [sectionEntry]
            } else {
                currentEntries.append(sectionEntry)
            }
        }

        if let currentKey {
            sections.append(DaySection(id: currentKey, title: currentTitle, entries: currentEntries))
        }

        return sections
    }

    private var topVisibilitySentinel: some View {
        Color.clear
            .frame(height: 1)
            .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                handleTopVisibilityChange(isVisible)
            }
            .accessibilityHidden(true)
    }

    private func dayBucketDate(for entry: FeedEntry) -> Date? {
        let date = entryDate(for: entry)
        guard date != .distantPast else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    private func daySectionTitle(for day: Date?) -> String {
        guard let day else { return "Ohne Datum" }
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            return "Heute"
        }
        if calendar.isDateInYesterday(day) {
            return "Gestern"
        }
        return Self.daySectionDateFormatter.string(from: day)
    }

    @ViewBuilder
    private func daySectionDividerRow(title: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(theme.uiAccentColor.opacity(0.3))
                    .frame(height: 1)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.uiAccentColor.opacity(0.3))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Rectangle()
                    .fill(theme.uiAccentColor.opacity(0.3))
                    .frame(height: 1)
            }
            .padding(.horizontal, 8)
        }
        .frame(minHeight: 32)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(.systemBackground))
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color(.systemBackground))
    }

    private var feedListLoadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Weitere Artikel werden geladen …")
                .font(.caption)
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func trackedEntryRow(for entry: FeedEntry,
                                 index: Int,
                                 lookup: FeedLookupMaps,
                                 shouldLoadMore: Bool,
                                 totalVisibleCount: Int) -> some View {
        if shouldLoadMore {
            entryRow(for: entry, index: index, lookup: lookup)
                .onAppear {
                    loadMoreEntriesIfNeeded(
                        currentIndex: index,
                        totalVisibleCount: totalVisibleCount
                    )
                }
        } else {
            entryRow(for: entry, index: index, lookup: lookup)
        }
    }

    private func handleTopVisibilityChange(_ isTopVisible: Bool) {
        let shouldShowButton = !isTopVisible
        if shouldShowButton != showBackToTopButton {
            withAnimation(.easeInOut(duration: 0.18)) {
                showBackToTopButton = shouldShowButton
            }
            syncSearchBarExpansionWithBackToTop(isBackToTopVisible: shouldShowButton)
        }
    }

    private func syncSearchBarExpansionWithBackToTop(isBackToTopVisible: Bool) {
        if isBackToTopVisible {
            guard isSearchBarExpanded, !isToolbarSearchFocused else { return }
            shouldFocusSearchOnExpand = false
            withAnimation(UIStylePolicy.Motion.standardEase) {
                isSearchBarExpanded = false
            }
        }
    }

    private func renderContextKey(for selectedFeedID: String) -> String {
        let feedSelectionKey = resolvedSelectedFeedIDs.sorted().joined(separator: ",")
        let quickFilterKey = activeQuickFilter?.rawValue ?? "all"
        let searchKey = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [selectedFeedID, feedSelectionKey, quickFilterKey, searchKey].joined(separator: "|")
    }

    private func effectiveRenderedEntryLimit(totalVisibleCount: Int) -> Int {
        guard totalVisibleCount > 0 else { return 0 }
        let seededLimit = renderedEntryLimit <= 0 ? initialRenderBatchSize : renderedEntryLimit
        return min(totalVisibleCount, max(1, seededLimit))
    }

    private func refreshRenderedEntryLimitIfNeeded(contextKey: String, totalVisibleCount: Int) {
        if lastRenderContextKey != contextKey {
            resetRenderedEntryLimit(contextKey: contextKey, totalVisibleCount: totalVisibleCount)
            return
        }
        clampRenderedEntryLimit(totalVisibleCount: totalVisibleCount)
    }

    private func resetRenderedEntryLimit(contextKey: String, totalVisibleCount: Int) {
        lastRenderContextKey = contextKey
        renderedEntryLimit = min(totalVisibleCount, initialRenderBatchSize)
    }

    private func clampRenderedEntryLimit(totalVisibleCount: Int) {
        if totalVisibleCount <= 0 {
            renderedEntryLimit = 0
            return
        }

        if renderedEntryLimit <= 0 {
            renderedEntryLimit = min(totalVisibleCount, initialRenderBatchSize)
            return
        }

        if renderedEntryLimit > totalVisibleCount {
            renderedEntryLimit = totalVisibleCount
        }
    }

    private var activeBottomBarFilterTitle: String {
        activeQuickFilter?.segmentTitle ?? "Alle"
    }

    private var shouldCollapseBottomFilterControl: Bool {
        showBackToTopButton || isSearchBarExpanded || isToolbarSearchFocused
    }

    private var feedFilterBottomBarControl: some View {
        HStack(spacing: 4) {
            ForEach(QuickFilterKind.visibleBottomBarFilters, id: \.self) { filter in
                bottomBarFilterButton(for: filter)
            }
        }
        .padding(4)
        .background(.thinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(theme.uiAccentColor.opacity(0.12), lineWidth: 1)
        }
        .simultaneousGesture(feedFilterSwipeGesture)
        .frame(maxWidth: 300, alignment: .trailing)
        .animation(.easeInOut(duration: 0.18), value: activeBottomBarFilterTitle)
        .accessibilityLabel("Artikelfilter")
        .accessibilityValue(activeBottomBarFilterTitle)
        .accessibilityHint("Nach links oder rechts wischen, um den Filter zu wechseln")
    }

    private func bottomBarFilterButton(for filter: QuickFilterKind?) -> some View {
        let isActive = activeQuickFilter == filter
        let title = filter?.segmentTitle ?? "Alle"
        let iconName = filter?.iconName ?? "line.3.horizontal.decrease"

        return Button {
            setBottomBarFilter(filter)
        } label: {
            HStack(spacing: isActive ? 6 : 0) {
                Image(systemName: iconName)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 18, height: 18)

                if isActive {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundStyle(isActive ? theme.uiAccentColor : Color.secondary)
            .padding(.horizontal, isActive ? 12 : 8)
            .frame(minWidth: isActive ? 104 : 34, minHeight: 34)
            .background {
                if isActive {
                    Capsule(style: .continuous)
                        .fill(theme.uiAccentColor.opacity(colorScheme == .dark ? 0.26 : 0.17))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(theme.uiAccentColor.opacity(0.30), lineWidth: 1)
                        }
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func setBottomBarFilter(_ filter: QuickFilterKind?) {
        guard activeQuickFilter != filter else { return }
        AppHaptics.selection()
        withAnimation(UIStylePolicy.Motion.standardEase) {
            setQuickFilter(filter)
        }
    }

    private var feedFilterSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical), abs(horizontal) > 24 else { return }
                stepQuickFilter(direction: horizontal < 0 ? 1 : -1)
            }
    }

    private func stepQuickFilter(direction: Int) {
        let filters = QuickFilterKind.visibleBottomBarFilters
        guard !filters.isEmpty,
              let currentIndex = filters.firstIndex(of: activeQuickFilter) else {
            return
        }

        let nextIndex = (currentIndex + direction + filters.count) % filters.count
        AppHaptics.selection()
        withAnimation(UIStylePolicy.Motion.standardEase) {
            setQuickFilter(filters[nextIndex])
        }
    }

    private func loadMoreEntriesIfNeeded(currentIndex: Int, totalVisibleCount: Int) {
        guard totalVisibleCount > 0 else { return }

        let currentLimit = effectiveRenderedEntryLimit(totalVisibleCount: totalVisibleCount)
        guard currentLimit < totalVisibleCount else { return }

        let triggerIndex = max(0, currentLimit - renderPrefetchThreshold)
        guard currentIndex >= triggerIndex else { return }

        let expandedLimit = min(totalVisibleCount, currentLimit + renderBatchSize)
        guard expandedLimit != renderedEntryLimit else { return }

        prefetchUpcomingThumbnails(
            from: currentLimit,
            through: expandedLimit
        )

        withTransaction(Transaction(animation: nil)) {
            renderedEntryLimit = expandedLimit
        }
    }

    private func prefetchUpcomingThumbnails(from startIndex: Int, through endIndex: Int) {
        guard startIndex < endIndex,
              startIndex < cachedVisibleEntries.count else {
            return
        }

        let upperBound = min(cachedVisibleEntries.count, endIndex)
        let urls = cachedVisibleEntries[startIndex..<upperBound].compactMap { entry in
            ArticleImagePipeline.resolvedThumbnailURL(
                imageURL: entry.imageURL,
                articleLink: entry.link
            )
        }
        guard !urls.isEmpty else { return }

        Task(priority: .utility) {
            await ArticleImagePipeline.shared.prefetchThumbnailImages(
                for: urls,
                maxPixelSize: 270
            )
        }
    }
    
    private func EmptyEntriesOverlay(isEmpty: Bool) -> some View {
        Group {
            if isEmpty {
                VStack(spacing: 16) {
                    EmptyFeedView()
                        .environmentObject(theme)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .animation(.easeInOut(duration: 0.2), value: isEmpty)
            } else {
                EmptyView()
            }
        }
    }
    
    var body: some View {
        mainContentView
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                articleViewerAvailableWidth = max(1, newWidth)
            }
    }

    private var mainContentView: some View {
        let navigationView = AnyView(NavigationStack {
            feedListView(for: activeFeedTabID)
                .navigationTitle("NewsFeeder")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { feedToolbar }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    activeReadingMiniBarInset
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .sheet(item: $feedToEdit, onDismiss: {
                    feedToEdit = nil
                }) { feed in
                    EditSingleFeedView(feed: feed, initialColor: theme.color(for: feed.url)) { updated in
                        guard let updated = updated else { return }
                        updateFeed(original: feed, updated: updated)
                    }
                    .environmentObject(theme)
                    .presentationDetents([.large])
                    .presentationBackground(.clear)
                }
                .sheet(isPresented: $showAddFeedSheet) {
                    AddSingleFeedView { newItem in
                        guard let newItem else { return }
                        upsertFeed(newItem)
                    }
                    .environmentObject(theme)
                    .presentationDetents([.large])
                    .presentationBackground(.clear)
                }
        }
        .sheet(isPresented: articleViewerPresentedBinding) {
            articleViewerCover
                .presentationDetents(
                    [.large],
                    selection: $articleViewerDetent
                )
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(34)
                .presentationBackground(Color(.systemBackground))
        }
        .overlay(alignment: .bottom) {
            if showBackToTopButton && activeArticle == nil {
                backToTopCenterButton
                    .padding(.bottom, 4)
                    .offset(y: 10)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.92)),
                            removal: .move(edge: .bottom)
                                .combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showBackToTopButton)
        .animation(.smooth(duration: 0.34, extraBounce: 0.08), value: isFeedPillOverlayPresented))

        let contentWithLifecycleObservers = attachLifecycleObservers(to: navigationView)
        let contentWithStateObservers = attachStateObservers(to: contentWithLifecycleObservers)

        return attachExternalObservers(to: contentWithStateObservers)
    }

    private func attachLifecycleObservers(to content: AnyView) -> AnyView {
        var observed = AnyView(content.onAppear { handleContentAppear() })
        observed = AnyView(observed.onChange(of: feeds) { _, newValue in handleFeedsDidChange(newValue) })
        observed = AnyView(observed.onChange(of: selectedFeedIDs) { _, _ in handleWidgetRelevantFilterDidChange() })
        observed = AnyView(observed.onChange(of: networkState.isOffline) { _, isOffline in
            if isOffline {
                completeInitialFeedLoad()
            } else {
                scheduleCloudStateSync(delayNanoseconds: 700_000_000)
            }
        })
        observed = AnyView(observed.onChange(of: showOnlyBookmarks) { _, _ in handleWidgetRelevantFilterDidChange() })
        return observed
    }

    private func attachStateObservers(to content: AnyView) -> AnyView {
        var observed = AnyView(content.onChange(of: store.readArticleIDs) { oldValue, newValue in
            handleReadArticleIDsDidChange(from: oldValue, to: newValue)
        })
        observed = AnyView(observed.onChange(of: showUnreadOnly) { _, _ in handleWidgetRelevantFilterDidChange() })
        observed = AnyView(observed.onChange(of: showTodayOnly) { _, _ in handleWidgetRelevantFilterDidChange() })
        observed = AnyView(observed.onChange(of: showOfflineOnly) { _, _ in handleWidgetRelevantFilterDidChange() })
        observed = AnyView(observed.onChange(of: offlineRetainedFetchedArticleLimitRaw) { _, _ in refreshOfflineArchiveRetention() })
        observed = AnyView(observed.onChange(of: entries) { _, _ in
            refreshDerivedFeedState()
            restoreMinimizedArticleIfNeeded()
        })
        observed = AnyView(observed.onChange(of: searchText) { _, _ in refreshDerivedFeedState() })
        observed = AnyView(observed.onChange(of: activeFeedTabID) { _, _ in refreshDerivedFeedState() })
        observed = AnyView(observed.onChange(of: feedSettingsRefreshToken) { _, _ in handleFeedSettingsRefreshTokenDidChange() })
        observed = AnyView(observed.onChange(of: bookmarkedLinks) { _, _ in handleBookmarkedLinksDidChange() })
        observed = AnyView(observed.onChange(of: store.recentlyReadArticleIDs) { _, _ in refreshDerivedFeedState() })
        return observed
    }

    private func attachExternalObservers(to content: AnyView) -> AnyView {
        let bookmarkPublisher = NotificationCenter.default.publisher(for: .feedBookmarkedArticleIDsDidSyncFromICloud)
        let cachedEntriesPublisher = NotificationCenter.default.publisher(for: .feedCachedEntriesDidRefresh)
        var observed = AnyView(content.onReceive(bookmarkPublisher, perform: { _ in
            Task { @MainActor in
                await BookmarkService.syncBookmarksFromCloudIfNeeded(context: modelContext)
                refreshBookmarkedLinks()
            }
        }))
        observed = AnyView(observed.onReceive(cachedEntriesPublisher, perform: { _ in
            restoreCachedEntries()
        }))
        observed = AnyView(observed.onChange(of: scenePhase) { _, newPhase in handleScenePhaseChange(newPhase) })
        observed = AnyView(observed.onChange(of: articleViewerDetent) { _, _ in syncMinimizedArticleStateForCurrentDetent() })
        observed = AnyView(observed.onOpenURL { url in
            Task { @MainActor in
                handleDeepLink(url)
            }
        })
        observed = AnyView(observed.onDisappear { cancelContentTasks() })
        return observed
    }

    private var showsFeedSegmentedPicker: Bool {
        feedSelectionFeeds.count > 1
    }

    private var feedSelectionFeeds: [FeedSource] {
        feeds
    }

    private var segmentedPickerFeeds: some View {
        let visibleFeeds = feedSelectionFeeds
        let visibleFeedIDs = Set(visibleFeeds.map(\.id))
        let allFeedTints = visibleFeeds.map { theme.color(for: $0.url) }
        let shouldShowAllPill = visibleFeeds.count >= 2
        let allPillIsActive = !visibleFeedIDs.isEmpty && resolvedSelectedFeedIDs.isSuperset(of: visibleFeedIDs)

        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 8) {
                        if shouldShowAllPill {
                            FeedSegmentPill(
                                title: "Alle",
                                tints: allFeedTints.isEmpty ? [theme.uiAccentColor] : allFeedTints,
                                isActive: allPillIsActive,
                                useFullColorBackground: fullColorCards,
                                usesLiquidGlass: false,
                                titleOpacity: 1
                            ) {
                                AppHaptics.selection()
                                withAnimation(UIStylePolicy.Motion.standardEase) {
                                    toggleAllFeedSelection(for: visibleFeedIDs)
                                    isFeedPillOverlayPresented = false
                                }
                            }

                            FeedPillDivider(height: 18)
                        }

                        ForEach(visibleFeeds) { feed in
                            FeedSegmentPill(
                                title: feedDisplayTitle(for: feed),
                                tints: [theme.color(for: feed.url)],
                                isActive: resolvedSelectedFeedIDs.contains(feed.id),
                                useFullColorBackground: fullColorCards,
                                usesLiquidGlass: false,
                                titleOpacity: 1
                            ) {
                                AppHaptics.selection()
                                withAnimation(UIStylePolicy.Motion.standardEase) {
                                    toggleFeedSelection(for: feed.id)
                                    isFeedPillOverlayPresented = false
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .frame(height: FeedPillMetrics.rowHeight, alignment: .top)
        .clipped()
        /*.background {
            TopChromeBackground(accent: theme.uiAccentColor)
                .overlay {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask(
                            LinearGradient(
                                colors: [Color.black, Color.black.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
        }*/
    }

    private var feedSelectionPopover: some View {
        let visibleFeeds = feedSelectionFeeds
        let visibleFeedIDs = Set(visibleFeeds.map(\.id))
        let allFeedTints = visibleFeeds.map { theme.color(for: $0.url) }
        let shouldShowAllPill = visibleFeeds.count >= 2
        let allPillIsActive = !visibleFeedIDs.isEmpty && resolvedSelectedFeedIDs.isSuperset(of: visibleFeedIDs)

        return VStack(alignment: .leading, spacing: 4) {
            if shouldShowAllPill {
                FeedPopoverSelectionRow(
                    title: "Alle Feeds",
                    tints: allFeedTints.isEmpty ? [theme.uiAccentColor] : allFeedTints,
                    isActive: allPillIsActive
                ) {
                    AppHaptics.selection()
                    withAnimation(UIStylePolicy.Motion.standardEase) {
                        toggleAllFeedSelection(for: visibleFeedIDs)
                    }
                }

                Divider()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .opacity(0.45)
            }

            ForEach(visibleFeeds) { feed in
                FeedPopoverSelectionRow(
                    title: feedDisplayTitle(for: feed),
                    tints: [theme.color(for: feed.url)],
                    isActive: resolvedSelectedFeedIDs.contains(feed.id)
                ) {
                    AppHaptics.selection()
                    withAnimation(UIStylePolicy.Motion.standardEase) {
                        toggleFeedSelection(for: feed.id)
                    }
                }
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .opacity(0.45)

            FeedPopoverActionRow(
                title: "Feed hinzufügen",
                systemImage: "plus.circle",
                tint: theme.uiAccentColor
            ) {
                AppHaptics.selection()
                isFeedPillOverlayPresented = false
                showAddFeedSheet = true
            }
        }
        .padding(10)
        .frame(width: 272, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    @ToolbarContentBuilder
    private var feedToolbar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Group {
                if isSearchBarExpanded {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .fontWeight(.light)
                            .foregroundStyle(theme.uiAccentColor)
                            .padding(.leading, 10)

                        TextField("Artikel suchen", text: $searchText)
                            .focused($isToolbarSearchFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .tint(theme.uiAccentColor)

                        if !searchText.isEmpty {
                            Button {
                                AppHaptics.lightImpact()
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .fontWeight(.light)
                                    .foregroundStyle(iconTint(active: true))
                            }
                            .padding(.trailing, 10)
                            .minimumHitTarget()
                            .accessibilityLabel("Suche leeren")
                            .buttonStyle(.plain)
                        }

                        Button {
                            AppHaptics.lightImpact()
                            isToolbarSearchFocused = false
                            shouldFocusSearchOnExpand = false
                            withAnimation(UIStylePolicy.Motion.standardEase) {
                                isSearchBarExpanded = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .fontWeight(.light)
                                .foregroundStyle(theme.uiAccentColor)
                        }
                        .padding(.trailing, 10)
                        .minimumHitTarget()
                        .accessibilityLabel("Suche schließen")
                        .buttonStyle(.plain)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .onAppear {
                        if shouldFocusSearchOnExpand {
                            isToolbarSearchFocused = true
                            shouldFocusSearchOnExpand = false
                        }
                    }
                } else {
                    Button {
                        AppHaptics.selection()
                        shouldFocusSearchOnExpand = true
                        withAnimation(UIStylePolicy.Motion.standardEase) {
                            isSearchBarExpanded = true
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body)
                            .fontWeight(.light)
                            .foregroundStyle(theme.uiAccentColor)
                    }
                    .buttonStyle(.plain)
                    .minimumHitTarget()
                    .accessibilityLabel("Suche öffnen")
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isSearchBarExpanded)
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            Group {
                if shouldCollapseBottomFilterControl {
                    filterAndSortMenuButton()
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                } else {
                    feedFilterBottomBarControl
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: shouldCollapseBottomFilterControl)
            .animation(.easeInOut(duration: 0.2), value: isToolbarSearchFocused)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                AppHaptics.selection()
                showSettingsSheet = true
            } label: {
                if let avatarImage = settingsAvatarImage {
                    Image(uiImage: avatarImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36 , height: 36)
                        .clipShape(Circle())
                        //.overlay {
                        //    Circle()
                       //         .stroke(theme.uiAccentColor.opacity(0.35), lineWidth: 1)
                       // }
                } else {
                    Image(systemName: "gear")
                        .fontWeight(.light)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.uiAccentColor)
                }
            }
            .buttonStyle(.plain)
            //.minimumHitTarget()
            .accessibilityLabel("Einstellungen")
        }
    } // <- Ende feedToolbar

    private var navigationSubtitleFeedDots: some View {
        let visibleFeeds = feedPillFeeds

        return HStack(spacing: FeedPillMetrics.subtitleDotSpacing) {
            ForEach(visibleFeeds) { feed in
                FeedPillTintDot(
                    tints: [theme.color(for: feed.url)],
                    isActive: resolvedSelectedFeedIDs.contains(feed.id),
                    usesFilledSymbolWhenActive: true,
                    letter: feed.title.isEmpty ? "Y" : .init(feed.title.first ?? "Y"),
                    size: FeedPillMetrics.subtitleDotSize
                )
            }

            if networkState.isOffline {
                Text("Offline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
        .frame(height: 11)
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private var backToTopCenterButton: some View {
        Button {
            AppHaptics.lightImpact()
            scrollToTopRequestToken += 1
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.uiAccentColor)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(theme.uiAccentColor.opacity(0.24), lineWidth: 0.8)
                }
                .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .minimumHitTarget()
        .accessibilityLabel("Nach oben")
        .accessibilityHint("Scrollt zurück zum Listenanfang")
    }

    private var articleViewerPresentedBinding: Binding<Bool> {
        Binding(
            get: { activeArticle != nil && isArticleViewerExpanded },
            set: { isPresented in
                if !isPresented {
                    if didRequestArticleMinimize {
                        didRequestArticleMinimize = false
                    } else {
                        clearMinimizedArticleState()
                        activeArticle = nil
                        activeArticleReadingProgress = 0
                    }
                    isArticleViewerExpanded = false
                    articleViewerDetent = .large
                }
            }
        )
    }

    private func compactPresentationHeight(for entry: FeedEntry) -> CGFloat {
        let textWidth = max(1, articleViewerAvailableWidth - 40 - 44 - 10)
        return FeedDetailView.compactPresentationHeight(
            for: entry.displayTitle,
            availableWidth: textWidth
        )
    }

    private var activeArticleCompactHeight: CGFloat {
        guard let activeArticle else {
            return FeedDetailView.compactPresentationHeight(
                for: "",
                availableWidth: 1
            )
        }
        return compactPresentationHeight(for: activeArticle)
    }

    private var isArticleViewerMinimized: Bool {
        activeArticle != nil && !isArticleViewerExpanded
    }

    @ViewBuilder
    private var activeReadingMiniBarInset: some View {
        if let activeArticle, isArticleViewerMinimized {
            activeReadingMiniBar(entry: activeArticle)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.98)),
                        removal: .move(edge: .bottom)
                            .combined(with: .opacity)
                    )
                )
        }
    }

    private func activeReadingMiniBar(entry: FeedEntry) -> some View {
        let tint = feedColor(for: entry.feedURL)
        let thumbnailURL = ArticleImagePipeline.resolvedThumbnailURL(
            imageURL: entry.imageURL,
            articleLink: entry.link
        )

        return HStack(spacing: 12) {
            Button {
                AppHaptics.selection()
                expandActiveArticle()
            } label: {
                HStack(spacing: 12) {
                    ActiveReadingThumbnail(url: thumbnailURL, tint: tint)

                    VStack(alignment: .leading, spacing: 9) {
                        Text(entry.displayTitle)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.22 : 0.14))

                                Capsule()
                                    .fill(tint)
                                    .frame(
                                        width: max(
                                            6,
                                            proxy.size.width * min(1, max(0, activeArticleReadingProgress))
                                        )
                                    )
                            }
                        }
                        .frame(height: 5)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                AppHaptics.lightImpact()
                clearMinimizedArticleState()
                withAnimation(.smooth(duration: 0.22)) {
                    activeArticle = nil
                    isArticleViewerExpanded = false
                    didRequestArticleMinimize = false
                    activeArticleReadingProgress = 0
                    articleViewerDetent = .large
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Gerade gelesenen Artikel schließen")
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .matchedGeometryEffect(id: "active-reading-surface", in: articleViewerMorphNamespace)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.36 : 0.24), lineWidth: 0.8)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.14), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Gerade am Lesen, \(entry.displayTitle)")
        .accessibilityHint("Öffnet den Reader")
    }

    private func expandActiveArticle() {
        guard activeArticle != nil else { return }
        clearMinimizedArticleState()
        withAnimation(.smooth(duration: 0.28)) {
            articleViewerDetent = .large
            isArticleViewerExpanded = true
            didRequestArticleMinimize = false
        }
    }

    @ViewBuilder
    private var articleViewerCover: some View {
        if let entry = activeArticle {
            NavigationStack {
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
                                store.markRecentlyRead(articleID: newDetail.link)
                                store.setRead(true, articleID: newDetail.link)
                                newDetail.isRead = true
                                newDetail.isNew = false
                                if let idx = entries.firstIndex(where: { $0.link == newDetail.link }) {
                                    entries[idx].isRead = true
                                    entries[idx].isNew = false
                                    persistEntriesCache()
                                }
                            }

                            activeArticleReadingProgress = 0
                            activeArticle = newDetail
                        }
                    },
                    onToggleRead: { isRead in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if let idx = entries.firstIndex(where: { $0.link == entry.link }) {
                                entries[idx].isRead = isRead
                                if isRead {
                                    entries[idx].isNew = false
                                }
                            }
                            store.unmarkRecentlyRead(articleID: entry.link)
                        }
                        scheduleEntriesCachePersist()
                    },
                    onToggleBookmark: { isBookmarked in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if isBookmarked {
                                bookmarkedLinks.insert(entry.link)
                            } else {
                                bookmarkedLinks.remove(entry.link)
                            }
                        }
                    },
                    isCompactPresentation: false,
                    compactPresentationHeight: activeArticleCompactHeight,
                    onExpandPresentation: {
                        expandActiveArticle()
                    },
                    onMinimizePresentation: {
                        didRequestArticleMinimize = true
                        persistMinimizedArticleState(for: entry)
                        withAnimation(.smooth(duration: 0.28)) {
                            isArticleViewerExpanded = false
                            articleViewerDetent = .large
                        }
                    },
                    onClosePresentation: {
                        clearMinimizedArticleState()
                        activeArticle = nil
                        isArticleViewerExpanded = false
                        didRequestArticleMinimize = false
                        activeArticleReadingProgress = 0
                        articleViewerDetent = .large
                    },
                    onReadingProgressChange: { progress in
                        activeArticleReadingProgress = min(1, max(0, progress))
                    }
                )
                .navigationBarBackButtonHidden(true)
                .matchedGeometryEffect(id: "active-reading-surface", in: articleViewerMorphNamespace)
            }
        } else {
            Color.clear
        }
    }
    
    @ViewBuilder
    private func entryRow(for entry: FeedEntry, index _: Int, lookup: FeedLookupMaps) -> some View {
        let matchedFeed = resolveFeed(for: entry, lookup: lookup)
        let feedName = {
            if let explicit = entry.sourceTitle, !explicit.isEmpty {
                return explicit
            }
            return matchedFeed?.title ?? "Unbekannte Quelle"
        }()
        let rowFeedColor = feedColor(for: matchedFeed?.url)
        let entryDateValue = entryDate(for: entry)
        let detailEntry: FeedEntry = {
            var updated = entry
            updated.sourceTitle = feedName
            updated.feedURL = matchedFeed?.url
            return updated
        }()
        let isBookmarked = bookmarkedLinks.contains(detailEntry.link)
        let isActiveArticle = isArticleViewerMinimized
            && activeArticle?.link == detailEntry.link
        
        Button {
            AppHaptics.selection()
            var navigationEntry = detailEntry
            if !entry.isRead {
                store.markRecentlyRead(articleID: detailEntry.link)
                store.setRead(true, articleID: detailEntry.link)
                navigationEntry.isRead = true
                navigationEntry.isNew = false
                if let idx = entries.firstIndex(where: { $0.link == detailEntry.link }) {
                    entries[idx].isRead = true
                    entries[idx].isNew = false
                    persistEntriesCache()
                }
            }
            let isSwitchingArticle = activeArticle?.link != nil
                && activeArticle?.link != navigationEntry.link
            if isSwitchingArticle {
                clearMinimizedArticleState()
                withAnimation(.smooth(duration: 0.28)) {
                    articleViewerDetent = .large
                    isArticleViewerExpanded = true
                    didRequestArticleMinimize = false
                    activeArticleReadingProgress = 0
                    activeArticle = navigationEntry
                }
            } else {
                clearMinimizedArticleState()
                articleViewerDetent = .large
                isArticleViewerExpanded = true
                didRequestArticleMinimize = false
                activeArticleReadingProgress = 0
                activeArticle = navigationEntry
            }
        } label: {
            ArticleCardView(
                feedTitle: feedName,
                feedColor: rowFeedColor,
                articleLink: entry.link,
                title: entry.displayTitle,
                summary: entry.content,
                imageURL: entry.imageURL,
                isRead: entry.isRead,
                date: entryDateValue,
                isBookmarked: isBookmarked,
                isActiveArticle: isActiveArticle,
                highlightTerm: searchText.isEmpty ? nil : searchText,
                highlightColor: rowFeedColor,
                useFullColorBackground: fullColorCards
            )
        }
        .buttonStyle(.plain)
        .background {
            if isActiveArticle {
                ActiveReadingArticleBackground(tint: rowFeedColor)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -7)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.smooth(duration: 0.32, extraBounce: 0.04), value: isActiveArticle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entryRowAccessibilityValue(feedName: feedName,
                                                       isRead: entry.isRead,
                                                       isBookmarked: isBookmarked,
                                                       date: entryDateValue))
        .accessibilityHint(isActiveArticle ? "Aktiver Artikel. Öffnet den Reader" : "Öffnet Artikel")
        .contentShape(Rectangle())
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            let isReadState = entry.isRead
            Button {
                AppHaptics.selection()
                if isReadState {
                    markAsUnread(entry)
                } else {
                    markAsRead(entry)
                }
            } label: {
                Label(isReadState ? "Als ungelesen markieren" : "Als gelesen markieren",
                      systemImage: isReadState ? "eye.slash" : "eye")
            }
            .tint(theme.uiSwipeColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                AppHaptics.selection()
                toggleBookmark(for: detailEntry, isCurrentlyBookmarked: isBookmarked)
            } label: {
                Label(isBookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen",
                      systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
            }
            .tint(isBookmarked ? .red : theme.uiSwipeColor)
        }
        .contextMenu {
            let isReadState = entry.isRead
            if let articleURL = URL(string: detailEntry.link) {
                ShareLink(item: articleURL) {
                    Label("Teilen", systemImage: "square.and.arrow.up")
                }
            }

            Button {
                AppHaptics.selection()
                copyArticleLink(detailEntry)
            } label: {
                Label("Link kopieren", systemImage: "link")
            }

            Button {
                AppHaptics.selection()
                if isReadState {
                    markAsUnread(entry)
                } else {
                    markAsRead(entry)
                }
            } label: {
                Label(isReadState ? "Als ungelesen markieren" : "Als gelesen markieren",
                      systemImage: isReadState ? "eye.slash" : "eye")
            }

            Button {
                AppHaptics.selection()
                toggleBookmark(for: detailEntry, isCurrentlyBookmarked: isBookmarked)
            } label: {
                Label(isBookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen",
                      systemImage: isBookmarked ? "bookmark.slash" : "bookmark")
            }
        } preview: {
            ArticleContextPreview(
                entry: detailEntry,
                feedTitle: feedName,
                feedColor: rowFeedColor,
                date: entryDateValue
            )
        }
    }

    private func triggerInitialLoadIfPossible() {
        guard !didTriggerInitialLoad else { return }
        didTriggerInitialLoad = true

        guard !feeds.isEmpty else {
            completeInitialFeedLoad()
            return
        }

        // Prefer immediate access to cached/local content when offline.
        if networkState.isOffline {
            completeInitialFeedLoad()
            return
        }

        Task {
            await loadRSSFeed()
        }
    }

    @MainActor
    private func completeInitialFeedLoad() {
        guard !didInitialFeedLoad else { return }
        didInitialFeedLoad = true
    }

    @MainActor
    private func refreshOnAppActivationIfNeeded() async {
        guard !feeds.isEmpty else { return }
        guard !isLoading else { return }
        guard !networkState.isOffline else { return }
        let now = Date()

        if let persistedDate = FeedRefreshState.lastSuccessfulRefreshDate() {
            let persistedAge = now.timeIntervalSince(persistedDate)
            guard persistedAge >= minimumActivationRefreshAge else { return }
        }

        if let lastRefreshDate {
            let age = now.timeIntervalSince(lastRefreshDate)
            guard age >= minimumActivationRefreshAge else { return }
        }

        await loadRSSFeed()
    }

    @MainActor
    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            let now = Date()
            let inactiveAge = lastSceneInactiveDate.map { now.timeIntervalSince($0) } ?? .infinity

            restoreCachedEntries()

            guard inactiveAge >= minimumResumeMaintenanceInactiveAge else {
                activationMaintenanceTask?.cancel()
                activationMaintenanceTask = nil
                return
            }

            if let lastActivationMaintenanceDate,
               now.timeIntervalSince(lastActivationMaintenanceDate) < minimumResumeMaintenanceInterval {
                return
            }

            lastActivationMaintenanceDate = now
            scheduleCloudStateSync(delayNanoseconds: 1_500_000_000)
            activationMaintenanceTask?.cancel()
            activationMaintenanceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: activationMaintenanceDelayNanoseconds)
                guard !Task.isCancelled else { return }
                await refreshOnAppActivationIfNeeded()
                activationMaintenanceTask = nil
            }

        case .inactive, .background:
            lastSceneInactiveDate = Date()
            activationMaintenanceTask?.cancel()
            activationMaintenanceTask = nil

        @unknown default:
            break
        }
    }
    
    private func feedColor(for url: String?) -> Color {
        if let url = url {
            return theme.color(for: url)
        } else {
            return theme.uiAccentColor.opacity(0.35)
        }
    }
    
    private func entryDate(for entry: FeedEntry) -> Date {
        entry.parsedPubDate ?? .distantPast
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

    private func copyArticleLink(_ entry: FeedEntry) {
        UIPasteboard.general.string = entry.link
    }
}

private extension View {
    func feedListChromeRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    func feedListArticleRow() -> some View {
        listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            .listRowSeparator(.visible)
            .listRowSeparatorTint(Color.secondary.opacity(0.18))
            .listRowBackground(Color(.systemBackground))
    }
}

private struct ActiveReadingArticleBackground: View {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: UIStylePolicy.Radius.medium, style: .continuous)
            .fill(tint.opacity(colorScheme == .dark ? 0.14 : 0.08))
            .overlay {
                RoundedRectangle(cornerRadius: UIStylePolicy.Radius.medium, style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.44 : 0.34), lineWidth: 1.4)
            }
    }
}

private struct ActiveReadingThumbnail: View {
    let url: URL?
    let tint: Color

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var imageURL: URL?

    init(url: URL?, tint: Color) {
        self.url = url
        self.tint = tint
        let cachedImage = url.flatMap { ArticleImagePipeline.shared.cachedImage(for: $0) }
        _image = State(initialValue: cachedImage)
        _imageURL = State(initialValue: cachedImage == nil ? nil : url)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.14))
                    Image(systemName: "photo")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(tint.opacity(0.86))
                }
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.26), lineWidth: 0.8)
        }
        .task(id: url, priority: .userInitiated) {
            guard let url else {
                image = nil
                imageURL = nil
                return
            }
            guard imageURL != url || image == nil else { return }
            if let cachedImage = ArticleImagePipeline.shared.cachedImage(for: url) {
                image = cachedImage
                imageURL = url
                return
            }
            guard !ArticleImagePipeline.shared.isTemporarilyMissing(url) else { return }

            image = nil
            imageURL = nil
            let maxPixelSize = max(110, 54 * displayScale)
            let loadedImage = await ArticleImagePipeline.shared.thumbnailImage(
                for: url,
                maxPixelSize: maxPixelSize,
                priority: .userInitiated
            )
            guard !Task.isCancelled else { return }
            image = loadedImage
            imageURL = loadedImage == nil ? nil : url
        }
    }
}

private struct ArticleContextPreview: View {
    let entry: FeedEntry
    let feedTitle: String
    let feedColor: Color
    let date: Date

    @AppStorage("readerFontScale") private var readerFontScale: Double = 1.0
    @AppStorage("readerLineSpacing") private var readerLineSpacing: Double = 1.4
    @AppStorage("readerTextAlignment") private var readerTextAlignmentRaw: String = "left"

    private var thumbnailURL: URL? {
        ArticleImagePipeline.resolvedThumbnailURL(
            imageURL: entry.imageURL,
            articleLink: entry.link
        )
    }

    private var dateText: String? {
        if let pubDateString = entry.pubDateString, !pubDateString.isEmpty {
            let parsedDate = DateParser.parse(pubDateString)
            return parsedDate != .distantPast ? DateFormatter.localized.string(from: parsedDate) : pubDateString
        }
        guard date != .distantPast else { return nil }
        return DateFormatter.localized.string(from: date)
    }

    private var readerBodyText: String {
        let rawBody = entry.contentRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = rawBody?.isEmpty == false ? rawBody! : entry.content
        return HTMLText.normalizePreviewSpacing(in: HTMLText.stripHTML(source))
    }

    private var textAlignment: TextAlignment {
        switch readerTextAlignmentRaw {
        case "center":
            return .center
        case "right":
            return .trailing
        default:
            return .leading
        }
    }

    private var readerFontSize: CGFloat {
        CGFloat(17.0 * max(0.82, min(1.28, readerFontScale)))
    }

    private var readerLineSpacingValue: CGFloat {
        CGFloat(7.0 * max(0.85, min(1.45, readerLineSpacing)))
    }

    private var headerForegroundColor: Color {
        Self.isLight(feedColor) ? .black : .white
    }

    private var headerSecondaryColor: Color {
        headerForegroundColor.opacity(0.72)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            readerHeader
            mediaPreview
            readerBody
        }
        .frame(width: 382, alignment: .top)
        .frame(minHeight: 560, alignment: .top)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var readerHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(headerForegroundColor)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 4) {
                Text(entry.author?.isEmpty == false ? entry.author! : "Unbekannt")
                Text("·")
                Text(feedTitle)
            }
            .font(.subheadline)
            .foregroundStyle(headerSecondaryColor)
            .lineLimit(1)

            HStack(spacing: 8) {
                if let dateText {
                    Text(dateText)
                }
            }
            .font(.footnote)
            .foregroundStyle(headerSecondaryColor)
            .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(feedColor)
    }

    @ViewBuilder
    private var mediaPreview: some View {
        if let thumbnailURL {
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .clipped()
                case .empty:
                    Rectangle()
                        .fill(feedColor.opacity(0.16))
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                case .failure:
                    EmptyView()
                @unknown default:
                    EmptyView()
                }
            }
        }
    }

    private var readerBody: some View {
        Text(readerBodyText)
            .font(.system(size: readerFontSize, weight: .regular, design: .rounded))
            .lineSpacing(readerLineSpacingValue)
            .foregroundStyle(.primary)
            .multilineTextAlignment(textAlignment)
            .lineLimit(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 22)
    }

    private static func isLight(_ color: Color) -> Bool {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection.current)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return false
        }

        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        return luminance > 0.62
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
                
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        FeedSegmentPill(
                            title: "Alle",
                            tints: [
                                Color(red: 0.72, green: 0.78, blue: 0.38),
                                Color(red: 0.33, green: 0.76, blue: 0.71),
                                Color(red: 0.96, green: 0.52, blue: 0.45)
                            ],
                            isActive: true,
                            useFullColorBackground: true,
                            action: {}
                        )
                        FeedSegmentPill(
                            title: "Spotify",
                            tints: [Color(red: 0.33, green: 0.76, blue: 0.71)],
                            isActive: false,
                            useFullColorBackground: true,
                            action: {}
                        )
                        FeedSegmentPill(
                            title: "MacRumours",
                            tints: [Color(red: 0.96, green: 0.52, blue: 0.45)],
                            isActive: false,
                            useFullColorBackground: true,
                            action: {}
                        )
                        Spacer()
                    }
                }
                .padding(.leading, 16)
                .padding(.top, safeTop + pillsTopPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground))
        }
    }
}

private enum FeedPillMetrics {
    static let height: CGFloat = 34
    static let rowHeight: CGFloat = 48
    static let dotSize: CGFloat = 8
    static let subtitleDotSize: CGFloat = 7
    static let subtitleDotSpacing: CGFloat = 9
    static let allDotID = "feed-pill-dot-all"

    static func dotID(for feedID: String) -> String {
        "feed-pill-dot-\(feedID)"
    }
}

private struct FeedPillDivider: View {
    var height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill((colorScheme == .dark ? Color.white : Color.black).opacity(colorScheme == .dark ? 0.18 : 0.14))
            .frame(width: 1, height: height)
            .padding(.horizontal, 2)
            .accessibilityHidden(true)
    }
}

private struct FeedPopoverSelectionRow: View {
    let title: String
    let tints: [Color]
    let isActive: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedTints: [Color] {
        tints.isEmpty ? [.accentColor] : tints
    }

    private var rowFill: Color {
        guard isActive else {
            return Color.primary.opacity(colorScheme == .dark ? 0.045 : 0.035)
        }
        return representativeTint.opacity(colorScheme == .dark ? 0.18 : 0.13)
    }

    private var rowStroke: Color {
        isActive
        ? representativeTint.opacity(colorScheme == .dark ? 0.34 : 0.26)
        : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06)
    }

    private var labelColor: Color {
        isActive ? Color.primary : Color.secondary
    }

    private var representativeTint: Color {
        resolvedTints.first ?? .accentColor
    }

    private var visibleTintCount: Int {
        min(resolvedTints.count, 3)
    }

    private var cornerRadiusFeedPopOver: CGFloat {
        20.0
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                tintMark
                    .frame(width: 22, height: 18, alignment: .center)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(representativeTint)
                    .opacity(isActive ? 1 : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadiusFeedPopOver, style: .continuous)
                    .fill(rowFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadiusFeedPopOver, style: .continuous)
                            .strokeBorder(rowStroke, lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadiusFeedPopOver, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var tintMark: some View {
        ZStack {
            ForEach(Array(resolvedTints.prefix(3).enumerated()), id: \.offset) { index, tint in
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.32 : 0.55), lineWidth: 0.7)
                    }
                    .offset(x: (CGFloat(index) - (CGFloat(visibleTintCount - 1) / 2)) * 6)
            }
        }
        .shadow(color: representativeTint.opacity(isActive ? 0.28 : 0.12), radius: 3, x: 0, y: 0)
    }
}

private struct FeedPopoverActionRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var rowFill: Color {
        tint.opacity(colorScheme == .dark ? 0.12 : 0.08)
    }

    private var rowStroke: Color {
        tint.opacity(colorScheme == .dark ? 0.24 : 0.18)
    }

    private var cornerRadiusFeedPopOver: CGFloat {
        20.0
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 18, alignment: .center)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadiusFeedPopOver, style: .continuous)
                    .fill(rowFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadiusFeedPopOver, style: .continuous)
                            .strokeBorder(rowStroke, lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadiusFeedPopOver, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct FeedSegmentPill: View {
    let title: String
    let tints: [Color]
    let isActive: Bool
    let useFullColorBackground: Bool
    var usesLiquidGlass: Bool = false
    var titleOpacity: Double = 1
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var representativeTint: Color {
        let resolvedTints = tints.isEmpty ? [Color.accentColor] : tints
        let components = resolvedTints.compactMap(Self.rgbaComponents(for:))
        guard !components.isEmpty else { return .accentColor }

        let count = Double(components.count)
        let red = components.reduce(0) { $0 + $1.red } / count
        let green = components.reduce(0) { $0 + $1.green } / count
        let blue = components.reduce(0) { $0 + $1.blue } / count

        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    private var labelColor: Color {
        if isActive {
            if useFullColorBackground && colorScheme == .dark {
                return Color.black.opacity(0.86)
            }
            return colorScheme == .dark
            ? Color.white.opacity(0.96)
            : (Self.isLight(representativeTint) ? Color.black.opacity(0.86) : Color.white.opacity(0.96))
        }
        return colorScheme == .dark
        ? Color.white.opacity(0.42)
        : Color.black.opacity(0.62)
    }

    private var capsuleGlass: Glass {
        let glass = Glass.regular.interactive(true)
        guard useFullColorBackground && isActive else {
            return glass
        }
        return glass.tint(representativeTint)
    }

    private var capsuleFill: AnyShapeStyle {
        let resolvedTints = tints.isEmpty ? [Color.accentColor] : tints
        let contrastBoost = colorSchemeContrast == .increased ? 0.04 : 0
        let activeBaseOpacity: Double = useFullColorBackground
        ? (colorScheme == .dark ? 0.24 : 0.20)
        : (colorScheme == .dark ? 0.12 : 0.09)
        let inactiveBaseOpacity: Double = useFullColorBackground
        ? (colorScheme == .dark ? 0.10 : 0.08)
        : (colorScheme == .dark ? 0.07 : 0.055)
        let baseOpacity = min(1, (isActive ? activeBaseOpacity : inactiveBaseOpacity) + contrastBoost)

        if resolvedTints.count > 1 {
            let colors = resolvedTints.map { $0.opacity(baseOpacity) } + [resolvedTints[0].opacity(baseOpacity)]
            return AnyShapeStyle(
                AngularGradient(
                    colors: colors,
                    center: .center,
                    angle: .degrees(-35)
                )
            )
        }

        let tint = resolvedTints[0]
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    tint.opacity(baseOpacity),
                    tint.opacity(max(0.025, baseOpacity * 0.48)),
                    tint.opacity(max(0.018, baseOpacity * 0.28))
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var capsuleStroke: Color {
        let contrastBoost = colorSchemeContrast == .increased ? 0.10 : 0
        if useFullColorBackground {
            return (isActive ? representativeTint : (colorScheme == .dark ? Color.white : Color.black))
                .opacity(min(1, (isActive ? 0.26 : 0.12) + contrastBoost))
        }

        let strokeBase = isActive ? representativeTint : (colorScheme == .dark ? Color.white : Color.black)
        let baseOpacity = isActive
        ? (colorScheme == .dark ? 0.50 : 0.44)
        : (colorScheme == .dark ? 0.18 : 0.22)
        return strokeBase.opacity(min(1, baseOpacity + contrastBoost))
    }

    @ViewBuilder
    var body: some View {
        let pill = Group {
            if usesLiquidGlass {
                pillButton
                    .glassEffect(capsuleGlass, in: Capsule())
            } else {
                pillButton
            }
        }
        .background {
            capsuleBackground
        }
        .frame(minHeight: FeedPillMetrics.height)
        .accessibilityAddTraits(isActive ? .isSelected : [])

        pill
    }

    private var capsuleBackground: some View {
        Capsule()
            .fill(capsuleFill)
            .overlay {
                Capsule()
                    .strokeBorder(capsuleStroke, lineWidth: 1)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        Color.white.opacity(colorScheme == .dark ? 0.14 : 0.12),
                        lineWidth: 0.7
                    )
                    .blur(radius: 0.2)
            }
    }

    private var pillButton: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(labelColor)
                .opacity(titleOpacity)
                .animation(.smooth(duration: 0.16, extraBounce: 0), value: titleOpacity)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private nonisolated static func rgbaComponents(for color: Color) -> (red: Double, green: Double, blue: Double)? {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }
        return (Double(red), Double(green), Double(blue))
    }

    private nonisolated static func isLight(_ color: Color) -> Bool {
        guard let components = rgbaComponents(for: color) else { return false }
        let red = linearize(components.red)
        let green = linearize(components.green)
        let blue = linearize(components.blue)
        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        return luminance > 0.62
    }

    private nonisolated static func linearize(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

private struct FeedPillTintDot: View {
    let tints: [Color]
    let isActive: Bool
    var usesFilledSymbolWhenActive: Bool = false
    let letter: String
    var size: CGFloat = FeedPillMetrics.dotSize

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedTints: [Color] {
        tints.isEmpty ? [.accentColor] : tints
    }

    private var inactiveDotColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.34) : Color.black.opacity(0.28)
    }

    private var dotShadowColor: Color {
        guard isActive else {
            return Color.black.opacity(colorScheme == .dark ? 0.10 : 0.06)
        }
        return resolvedTints.first?.opacity(0.34) ?? .clear
    }

    private var symbolName: String {
        let normalizedLetter = letter
            .lowercased()
            .unicodeScalars
            .first
            .map(String.init) ?? "y"
        return normalizedLetter + ".circle" + (usesFilledSymbolWhenActive && isActive ? ".fill" : "")
    }

    var body: some View {
        /*Circle()
            .fill(dotFill)
            .frame(width: FeedPillMetrics.dotSize, height: FeedPillMetrics.dotSize)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.34 : 0.42), lineWidth: 0.6)
            }
            .shadow(
                color: dotShadowColor,
                radius: isActive ? 3 : 1.5,
                x: 0,
                y: 0
            )
            .accessibilityHidden(true)*/

        Image(systemName: symbolName)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(dotFill)
            .font(.system(size: size, weight: .regular))
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.34 : 0.42), lineWidth: 0.6)
            }
            .shadow(
                color: dotShadowColor,
                radius: isActive ? 3 : 1.5,
                x: 0,
                y: 0
            )
            .accessibilityHidden(true)
    }

    private var dotFill: some ShapeStyle {
        guard isActive else {
            return AnyShapeStyle(inactiveDotColor)
        }

        if resolvedTints.count > 1 {
            return AnyShapeStyle(
                AngularGradient(
                    colors: resolvedTints + [resolvedTints[0]],
                    center: .center
                )
            )
        }
        return AnyShapeStyle(resolvedTints[0])
    }
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
    private func scheduleCloudStateSync(delayNanoseconds: UInt64) {
        cloudStateSyncTask?.cancel()
        cloudStateSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await syncCloudStateFromICloud()
            cloudStateSyncTask = nil
        }
    }

    @MainActor
    private func syncCloudStateFromICloud() async {
        FeedICloudSyncManager.shared.syncAllFromCloudIfNeeded()
        theme.syncFromCloudIfNeeded()
        await FeedCloudKitSyncManager.shared.syncAllFromCloudIfPossible()
        store.syncFromCloudIfNeeded()
        await BookmarkService.syncBookmarksFromCloudIfNeeded(context: modelContext)
        refreshBookmarkedLinks()
        applyReadStateFromStore()
    }

    private func applyReadStateFromStore() {
        applyReadState(readIDs: store.readArticleIDs)
    }

    private func applyReadStateChange(from oldValue: Set<String>, to newValue: Set<String>) {
        let changedLinks = oldValue.symmetricDifference(newValue)
        guard !changedLinks.isEmpty else { return }
        applyReadState(readIDs: newValue, changedLinks: Set(changedLinks))
    }

    private func applyReadState(readIDs: Set<String>, changedLinks: Set<String>? = nil) {
        guard !entries.isEmpty else { return }

        var updatedEntries = entries
        var didUpdate = false

        for index in updatedEntries.indices {
            let link = updatedEntries[index].link
            if let changedLinks, !changedLinks.contains(link) {
                continue
            }

            let shouldBeRead = readIDs.contains(link)
            if updatedEntries[index].isRead != shouldBeRead {
                updatedEntries[index].isRead = shouldBeRead
                didUpdate = true
            }

            if shouldBeRead, updatedEntries[index].isNew {
                updatedEntries[index].isNew = false
                didUpdate = true
            }
        }

        if didUpdate {
            entries = updatedEntries
        }
    }

    private func normalizedEntry(_ entry: FeedEntry, readIDs: Set<String>) -> FeedEntry {
        var normalized = entry
        normalized.isRead = readIDs.contains(normalized.link)
        if normalized.isRead {
            normalized.isNew = false
        }
        return normalized
    }

    private func mergedEntry(existing: FeedEntry, incoming: FeedEntry, readIDs: Set<String>) -> FeedEntry {
        var merged = existing
        merged.title = incoming.title
        merged.shortTitle = incoming.shortTitle
        merged.content = incoming.content
        merged.contentRaw = incoming.contentRaw
        merged.imageURL = incoming.imageURL
        merged.author = incoming.author
        merged.pubDateString = incoming.pubDateString
        merged.feedURL = incoming.feedURL ?? existing.feedURL
        merged.sourceTitle = incoming.sourceTitle ?? existing.sourceTitle
        merged.isRead = readIDs.contains(merged.link)
        if merged.isRead {
            merged.isNew = false
        }
        return merged
    }

    private func mergeFetchedEntries(_ fetchedEntries: [FeedEntry], readIDs: Set<String>) -> (entries: [FeedEntry], insertedEntryIDs: Set<String>) {
        var mergedByLink: [String: FeedEntry] = [:]
        mergedByLink.reserveCapacity(max(entries.count, fetchedEntries.count))

        for existing in entries {
            mergedByLink[existing.link] = normalizedEntry(existing, readIDs: readIDs)
        }

        var insertedEntryIDs: Set<String> = []
        insertedEntryIDs.reserveCapacity(fetchedEntries.count)

        for incoming in fetchedEntries {
            if let existing = mergedByLink[incoming.link] {
                mergedByLink[incoming.link] = mergedEntry(existing: existing, incoming: incoming, readIDs: readIDs)
            } else {
                let fresh = normalizedEntry(incoming, readIDs: readIDs)
                mergedByLink[incoming.link] = fresh
                insertedEntryIDs.insert(fresh.link)
            }
        }

        return (Array(mergedByLink.values), insertedEntryIDs)
    }

    @MainActor
    private func applyEntriesSnapshot(_ snapshot: [FeedEntry],
                                      insertedEntryIDs _: Set<String> = [],
                                      persistCache: Bool,
                                      uploadCacheToCloud: Bool = false) {
        let normalizedSnapshot = sortedAndLimitedEntries(snapshot)
        withTransaction(Transaction(animation: nil)) {
            entries = normalizedSnapshot
        }

        if persistCache {
            persistEntriesCache(uploadToCloud: uploadCacheToCloud)
        }
    }

    @MainActor
    func loadRSSFeed() async {
        guard !isLoading else { return }
        restoreSavedFeedsFromStorage()
        isLoading = true
        defer {
            isLoading = false
            completeInitialFeedLoad()
        }

        guard !feeds.isEmpty else {
            return
        }

        // Offline fast path: keep cached/local state visible and avoid network waits.
        guard !networkState.isOffline else {
            return
        }

        let feedsSnapshot = feeds
        var newEntries: [FeedEntry] = []
        var feedStatuses: [(FeedSource, FeedFetchStatus)] = []
        
        await withTaskGroup(of: (FeedSource, FeedFetchStatus).self) { group in
            for feed in feedsSnapshot {
                group.addTask {
                    let status = await fetchFeed(feed)
                    return (feed, status)
                }
            }
            
            for await (feed, status) in group {
                feedStatuses.append((feed, status))
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
        let mergeResult = mergeFetchedEntries(newEntries, readIDs: readIDs)
        applyEntriesSnapshot(
            mergeResult.entries,
            insertedEntryIDs: didInitialFeedLoad ? mergeResult.insertedEntryIDs : [],
            persistCache: true,
            uploadCacheToCloud: true
        )
        scheduleOfflinePreload(for: mergeResult.entries)

        let refreshDate = Date()
        let articleCounts = articleCountsByFeedURL(in: mergeResult.entries)
        let nextRefreshAfter = refreshDate.addingTimeInterval(FeedRefreshCadence.backgroundMinimumInterval)
        for (feed, status) in feedStatuses {
            FeedHealthStore.record(
                feed: feed,
                status: status,
                attemptedAt: refreshDate,
                articleCount: articleCounts[feed.url, default: 0],
                nextRefreshAfter: nextRefreshAfter
            )
        }
        lastRefreshDate = refreshDate
        FeedRefreshState.persistLastSuccessfulRefreshDate(refreshDate)
        pushSnapshotToWatch()
        refreshBookmarkedLinks()
    }

    private func articleCountsByFeedURL(in entries: [FeedEntry]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries {
            guard let feedURL = entry.feedURL, !feedURL.isEmpty else { continue }
            counts[feedURL, default: 0] += 1
        }
        return counts
    }
    
    func fetchFeed(_ feed: FeedSource) async -> FeedFetchStatus {
        await feedClient.fetch(feed: feed)
    }
    
    private func scheduleEntriesCachePersist() {
        entriesCachePersistTask?.cancel()
        entriesCachePersistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: entriesCachePersistDelayNanoseconds)
            guard !Task.isCancelled else { return }
            persistEntriesCache()
            entriesCachePersistTask = nil
        }
    }

    private func persistEntriesCache(uploadToCloud: Bool = false) {
        guard let data = try? Self.cacheEncoder.encode(entries) else { return }

        let token = FeedCacheSync.write(data, for: FeedStorage.Keys.cachedEntries)
        cachedEntriesData = data
        cachedEntriesSyncToken = token
        if uploadToCloud {
            FeedCloudKitSyncManager.shared.uploadLocalData(
                data,
                token: token,
                for: FeedStorage.Keys.cachedEntries
            )
        }
    }

    private func scheduleOfflinePreload(for entries: [FeedEntry]) {
        guard !entries.isEmpty else { return }
        let limit = OfflineArticleRetentionLimit(rawValue: offlineRetainedFetchedArticleLimitRaw)
            ?? OfflineArticleRetentionLimit.defaultValue
        let snapshot = OfflineArticleRetentionPolicy.retainedEntries(
            from: entries,
            readIDs: store.readArticleIDs,
            bookmarkedLinks: bookmarkedLinks,
            limit: limit
        )
        guard !snapshot.isEmpty else { return }
        Task.detached(priority: .utility) {
            await OfflineArticleArchive.preloader.preload(entries: snapshot)
        }
    }

    private func refreshOfflineArchiveRetention() {
        scheduleOfflinePreload(for: entries)
    }

    private func restoreCachedEntries() {
        let bestToken = FeedCacheSync.bestAvailableToken(for: FeedStorage.Keys.cachedEntries)
        if bestToken > 0,
           bestToken == cachedEntriesSyncToken,
           !entries.isEmpty {
            if lastRefreshDate == nil {
                lastRefreshDate = FeedRefreshState.lastSuccessfulRefreshDate()
            }
            completeInitialFeedLoad()
            return
        }

        var shouldDecodeCache = entries.isEmpty
        if let bestData = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.cachedEntries),
           bestData != cachedEntriesData {
            cachedEntriesData = bestData
            cachedEntriesSyncToken = bestToken
            shouldDecodeCache = true
        }
        if bestToken > 0 {
            cachedEntriesSyncToken = bestToken
        }
        guard !cachedEntriesData.isEmpty else { return }
        guard shouldDecodeCache else {
            if lastRefreshDate == nil {
                lastRefreshDate = FeedRefreshState.lastSuccessfulRefreshDate()
            }
            completeInitialFeedLoad()
            return
        }

        if var cached = try? Self.cacheDecoder.decode([FeedEntry].self, from: cachedEntriesData) {
            for index in cached.indices {
                cached[index].isRead = store.isRead(articleID: cached[index].link)
                if cached[index].isRead {
                    cached[index].isNew = false
                }
            }
            applyEntriesSnapshot(
                cached,
                insertedEntryIDs: didInitialFeedLoad
                ? Set(cached.map(\.id)).subtracting(Set(entries.map(\.id)))
                : [],
                persistCache: false
            )
            if lastRefreshDate == nil {
                lastRefreshDate = FeedRefreshState.lastSuccessfulRefreshDate()
            }
            pruneEntriesForRemovedFeeds()
            pushSnapshotToWatch()
            scheduleOfflinePreload(for: cached)
            completeInitialFeedLoad()
        }
    }

    private func restoreSavedFeedsFromStorage() {
        let effectiveData = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.savedFeeds) ?? savedFeedsData
        if effectiveData != savedFeedsData {
            savedFeedsData = effectiveData
        }

        guard !effectiveData.isEmpty else {
            if !feeds.isEmpty {
                feeds = []
            }
            return
        }

        guard let decoded = try? JSONDecoder().decode([FeedSource].self, from: effectiveData) else {
            return
        }

        if decoded != feeds {
            feeds = decoded
        }
    }
    
    private struct FeedLookupMaps {
        let byURL: [String: FeedSource]
        let byHost: [String: FeedSource]
        let byDomain: [String: FeedSource]

        static let empty = FeedLookupMaps(byURL: [:], byHost: [:], byDomain: [:])
    }

    private var effectiveFeedLookupMaps: FeedLookupMaps {
        if didPrepareDerivedFeedState {
            return cachedFeedLookupMaps
        }
        return buildFeedLookupMaps()
    }

    private func buildFeedLookupMaps() -> FeedLookupMaps {
        var byURL: [String: FeedSource] = [:]
        byURL.reserveCapacity(feeds.count)
        var byHost: [String: FeedSource] = [:]
        byHost.reserveCapacity(feeds.count)
        var byDomain: [String: FeedSource] = [:]
        byDomain.reserveCapacity(feeds.count)

        for feed in feeds {
            byURL[feed.url] = feed
            guard let host = URL(string: feed.url)?.host?.lowercased() else { continue }
            if byHost[host] == nil {
                byHost[host] = feed
            }
            if let domain = baseDomain(from: host), byDomain[domain] == nil {
                byDomain[domain] = feed
            }
        }

        return FeedLookupMaps(byURL: byURL, byHost: byHost, byDomain: byDomain)
    }

    private func resolveFeed(for entry: FeedEntry, lookup: FeedLookupMaps) -> FeedSource? {
        if let entryFeedURL = entry.feedURL {
            if let exact = lookup.byURL[entryFeedURL] {
                return exact
            }
            if let host = URL(string: entryFeedURL)?.host?.lowercased(),
               let byHost = lookup.byHost[host] {
                return byHost
            }
        }

        guard let articleHost = URL(string: entry.link)?.host?.lowercased() else {
            return nil
        }

        if let articleDomain = baseDomain(from: articleHost),
           let byDomain = lookup.byDomain[articleDomain] {
            return byDomain
        }

        return lookup.byHost[articleHost]
    }

    private enum QuickFilterKind: String, CaseIterable, Identifiable {
        case unread
        case today
        case bookmarks
        case offline

        var id: String { rawValue }

        static var visibleSegmentFilters: [QuickFilterKind] {
            [.unread, .bookmarks, .offline]
        }

        static var visibleBottomBarFilters: [QuickFilterKind?] {
            [nil, .unread, .bookmarks, .offline]
        }

        var title: String {
            switch self {
            case .bookmarks:
                return "Lesezeichen"
            case .offline:
                return "Offline"
            case .unread:
                return "Ungelesen"
            case .today:
                return "Heute"
            }
        }

        var segmentTitle: String {
            switch self {
            case .bookmarks:
                return "Gespeichert"
            default:
                return title
            }
        }

        var iconName: String {
            switch self {
            case .bookmarks:
                return "bookmark"
            case .offline:
                return "arrow.down.circle"
            case .unread:
                return "eye"
            case .today:
                return "calendar"
            }
        }
    }

    private enum WidgetSelectionContextStore {
        static let selectedFeedIDsKey = FeedStorage.Keys.widgetSelectedFeedIDs
        static let quickFilterKey = "nf_widget_quick_filter_v1"
        static let lockScreenCurrentLinkKey = "nf_widget_lockscreen_current_link_v1"
    }

    private func refreshDerivedFeedState() {
        let lookup = buildFeedLookupMaps()
        cachedFeedLookupMaps = lookup
        cachedVisibleEntries = filteredEntries(for: activeFeedTabID, lookup: lookup)
        cachedFeedPillFeeds = computeFeedPillFeeds(using: lookup)
        didPrepareDerivedFeedState = true
    }

    private func visibleEntriesForDisplay(selectedFeedID: String, lookup: FeedLookupMaps) -> [FeedEntry] {
        guard didPrepareDerivedFeedState else {
            return filteredEntries(for: selectedFeedID, lookup: lookup)
        }
        guard selectedFeedID == activeFeedTabID else {
            return filteredEntries(for: selectedFeedID, lookup: lookup)
        }
        return cachedVisibleEntries
    }

    private func computeFeedPillFeeds(using lookup: FeedLookupMaps) -> [FeedSource] {
        var matchingFeedIDs: Set<String> = []
        matchingFeedIDs.reserveCapacity(feeds.count)

        for entry in entries where matchesQuickFilter(entry, filter: activeQuickFilter) {
            guard let feed = resolveFeed(for: entry, lookup: lookup) else { continue }
            matchingFeedIDs.insert(feed.id)
        }

        return feeds.filter { matchingFeedIDs.contains($0.id) }
    }

    private func entriesMatchingSelection(for selectedFeedID: String,
                                          includeSearch: Bool,
                                          lookup: FeedLookupMaps) -> [FeedEntry] {
        let activeFeedIDs = resolvedSelectedFeedIDs
        let query = searchText.lowercased()
        let hasSearch = includeSearch && !searchText.isEmpty

        var result: [FeedEntry] = []
        result.reserveCapacity(entries.count)

        for entry in entries {
            guard let feed = resolveFeed(for: entry, lookup: lookup) else { continue }
            guard activeFeedIDs.contains(feed.id) else { continue }
            if selectedFeedID != FeedFilterSelection.all && selectedFeedID != feed.id {
                continue
            }
            if hasSearch && !matchesSearch(entry, query: query) {
                continue
            }
            result.append(entry)
        }

        return result
    }

    private func matchesSearch(_ entry: FeedEntry, query: String) -> Bool {
        let title = entry.title.lowercased()
        let summary = entry.content.lowercased()
        let author = (entry.author ?? "").lowercased()
        return title.contains(query) || summary.contains(query) || author.contains(query)
    }

    private func filteredEntries(for selectedFeedID: String, lookup: FeedLookupMaps) -> [FeedEntry] {
        var result = entriesMatchingSelection(for: selectedFeedID, includeSearch: true, lookup: lookup)
        result = result.filter { matchesQuickFilter($0, filter: activeQuickFilter) }
        return result
    }

    private func filteredEntries(for selectedFeedID: String) -> [FeedEntry] {
        filteredEntries(for: selectedFeedID, lookup: effectiveFeedLookupMaps)
    }

    private func matchesQuickFilter(_ entry: FeedEntry, filter: QuickFilterKind?) -> Bool {
        switch filter {
        case .bookmarks:
            return bookmarkedLinks.contains(entry.link)
        case .unread:
            return !entry.isRead || recentlyReadLinks.contains(entry.link)
        case .today:
            let publishedDate = entry.parsedPubDate ?? .distantPast
            return publishedDate != .distantPast && Calendar.current.isDateInToday(publishedDate)
        case .offline:
            return isOfflineAvailable(entry)
        case .none:
            return true
        }
    }

    private func isOfflineAvailable(_ entry: FeedEntry) -> Bool {
        guard let fileURL = OfflineArticleArchive.articleHTMLFileURL(forArticleLink: entry.link) else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func normalizeSelectedFeedIDs(using availableFeeds: [FeedSource]? = nil) {
        let availableFeeds = availableFeeds ?? feeds
        let orderedIDs = availableFeeds.map(\.id)
        let availableIDs = Set(orderedIDs)
        let newFeedIDs = availableIDs.subtracting(knownAvailableFeedIDs)
        defer { knownAvailableFeedIDs = availableIDs }

        guard !availableIDs.isEmpty else {
            selectedFeedIDs.removeAll()
            didInitializeFeedSelection = false
            activeFeedTabID = FeedFilterSelection.all
            return
        }

        if !didInitializeFeedSelection {
            selectedFeedIDs = availableIDs
            didInitializeFeedSelection = true
            syncActiveFeedTabID(using: availableFeeds)
            return
        }

        var currentSelection = selectedFeedIDs.intersection(availableIDs)
        currentSelection.formUnion(newFeedIDs)
        if currentSelection != selectedFeedIDs {
            selectedFeedIDs = currentSelection
        }

        syncActiveFeedTabID(using: availableFeeds)
    }

    private func syncActiveFeedTabID(using availableFeeds: [FeedSource]? = nil) {
        let availableFeeds = availableFeeds ?? feeds
        let orderedIDs = availableFeeds.map(\.id)
        let availableIDs = Set(orderedIDs)
        let currentSelection = selectedFeedIDs.intersection(availableIDs)

        guard currentSelection.count == 1,
              let selectedID = orderedIDs.first(where: currentSelection.contains) else {
            activeFeedTabID = FeedFilterSelection.all
            return
        }

        activeFeedTabID = selectedID
    }

    private func toggleAllFeedSelection(for feedIDs: Set<String>? = nil) {
        let targetFeedIDs = (feedIDs ?? validFeedIDs).intersection(validFeedIDs)
        guard !targetFeedIDs.isEmpty else { return }
        didInitializeFeedSelection = true
        selectedFeedIDs = targetFeedIDs

        syncActiveFeedTabID()
    }

    private func toggleFeedSelection(for feedID: String) {
        guard validFeedIDs.contains(feedID) else { return }
        didInitializeFeedSelection = true

        var updatedSelection = resolvedSelectedFeedIDs
        if updatedSelection.contains(feedID) {
            guard updatedSelection.count > 1 else { return }
            updatedSelection.remove(feedID)
        } else {
            updatedSelection.insert(feedID)
        }

        selectedFeedIDs = updatedSelection
        syncActiveFeedTabID()
    }

    var filteredEntries: [FeedEntry] {
        if didPrepareDerivedFeedState {
            return cachedVisibleEntries
        }
        return filteredEntries(for: activeFeedTabID)
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
            store.markRecentlyRead(articleID: entry.link)
            store.setRead(true, articleID: entry.link)
            entry.isRead = true
            entry.isNew = false
            if let idx = entries.firstIndex(where: { $0.link == entry.link }) {
                entries[idx].isRead = true
                entries[idx].isNew = false
                persistEntriesCache()
                pushSnapshotToWatch()
            }
        }

        clearMinimizedArticleState()
        articleViewerDetent = .large
        isArticleViewerExpanded = true
        didRequestArticleMinimize = false
        activeArticleReadingProgress = 0
        activeArticle = entry
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

    @MainActor
    private func restoreMinimizedArticleIfNeeded() {
        guard !didAttemptMinimizedArticleRestore else { return }
        guard activeArticle == nil else { return }
        guard var restored = LastReadingArticleStore.restore() else {
            didAttemptMinimizedArticleRestore = true
            return
        }

        if var latest = resolveEntry(by: restored.link) {
            latest.sourceTitle = feedTitle(for: latest)
            latest.feedURL = feedSource(for: latest)?.url
            restored = latest
        } else {
            restored.sourceTitle = restored.sourceTitle ?? feedTitle(for: restored)
            restored.feedURL = restored.feedURL ?? feedSource(for: restored)?.url
        }

        didAttemptMinimizedArticleRestore = true
        articleViewerDetent = .large
        isArticleViewerExpanded = false
        didRequestArticleMinimize = false
        activeArticleReadingProgress = 0
        activeArticle = restored
        ReadingLiveActivityManager.shared.startOrUpdate(
            entry: restored,
            feedColor: feedColor(for: restored.feedURL)
        )
    }

    @MainActor
    private func syncMinimizedArticleStateForCurrentDetent() {
        guard let activeArticle else {
            clearMinimizedArticleState()
            return
        }

        if isArticleViewerMinimized {
            persistMinimizedArticleState(for: activeArticle)
        } else {
            clearMinimizedArticleState()
        }
    }

    @MainActor
    private func persistMinimizedArticleState(for entry: FeedEntry) {
        LastReadingArticleStore.save(entry)
        ReadingLiveActivityManager.shared.startOrUpdate(
            entry: entry,
            feedColor: feedColor(for: entry.feedURL)
        )
    }

    @MainActor
    private func clearMinimizedArticleState() {
        LastReadingArticleStore.clear()
        ReadingLiveActivityManager.shared.end()
    }

    private var activeQuickFilter: QuickFilterKind? {
        if showOfflineOnly { return .offline }
        if showOnlyBookmarks { return .bookmarks }
        if showUnreadOnly { return .unread }
        if showTodayOnly { return .today }
        return nil
    }

    private var filterToolbarIconMode: FilterToolbarAnimatedIcon.Mode {
        switch activeQuickFilter {
        case .bookmarks:
            return .bookmarks
        case .offline:
            return .offline
        case .unread:
            return .unread
        case .today:
            return .today
        case .none:
            return .none
        }
    }

    private func triggerLightHaptic() {
        AppHaptics.lightImpact()
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

    private func persistWidgetSelectionContext() {
        let defaults = FeedStorage.defaults
        let selectedIDs = Array(resolvedSelectedFeedIDs).sorted()
        if let data = try? JSONEncoder().encode(selectedIDs) {
            defaults.set(data, forKey: WidgetSelectionContextStore.selectedFeedIDsKey)
        } else {
            defaults.removeObject(forKey: WidgetSelectionContextStore.selectedFeedIDsKey)
        }

        let quickFilterValue = activeQuickFilter?.rawValue ?? "all"
        defaults.set(quickFilterValue, forKey: WidgetSelectionContextStore.quickFilterKey)
    }

    private func shouldReloadWidgetForReadStateChange(from oldValue: Set<String>, to newValue: Set<String>) -> Bool {
        let defaults = FeedStorage.defaults
        guard let currentLink = defaults.string(forKey: WidgetSelectionContextStore.lockScreenCurrentLinkKey),
              !currentLink.isEmpty else {
            return false
        }

        let oldIsRead = oldValue.contains(currentLink)
        let newIsRead = newValue.contains(currentLink)
        return oldIsRead != newIsRead
    }

    private func handleContentAppear() {
        refreshDerivedFeedState()
        if !didRestoreCachedEntries {
            didRestoreCachedEntries = true
            restoreCachedEntries()
        }
        restoreMinimizedArticleIfNeeded()
        if lastRefreshDate == nil {
            lastRefreshDate = FeedRefreshState.lastSuccessfulRefreshDate()
        }
        normalizeSelectedFeedIDs()
        persistWidgetSelectionContext()
        triggerInitialLoadIfPossible()
        pruneEntriesForRemovedFeeds()
        scheduleCloudStateSync(delayNanoseconds: 900_000_000)
        pushSnapshotToWatch()
    }

    private func handleFeedsDidChange(_ feeds: [FeedSource]) {
        normalizeSelectedFeedIDs(using: feeds)
        persistWidgetSelectionContext()
        scheduleWidgetTimelineReload()
        refreshDerivedFeedState()
    }

    private func handleWidgetRelevantFilterDidChange() {
        persistWidgetSelectionContext()
        scheduleWidgetTimelineReload()
        refreshDerivedFeedState()
    }

    private func handleFeedSettingsRefreshTokenDidChange() {
        restoreSavedFeedsFromStorage()
        scheduleFeedsReload()
    }

    private func handleReadArticleIDsDidChange(from oldValue: Set<String>, to newValue: Set<String>) {
        applyReadStateChange(from: oldValue, to: newValue)
        scheduleEntriesCachePersist()
        refreshOfflineArchiveRetention()
        pushSnapshotToWatch()
        if shouldReloadWidgetForReadStateChange(from: oldValue, to: newValue) {
            scheduleWidgetTimelineReload()
        }
        refreshDerivedFeedState()
    }

    private func handleBookmarkedLinksDidChange() {
        refreshOfflineArchiveRetention()
        refreshDerivedFeedState()
    }

    private func cancelContentTasks() {
        refreshTask?.cancel()
        feedsReloadTask?.cancel()
        statusBarRefreshTask?.cancel()
        cloudStateSyncTask?.cancel()
        activationMaintenanceTask?.cancel()
        widgetTimelineReloadTask?.cancel()
        entriesCachePersistTask?.cancel()
    }

    private func scheduleWidgetTimelineReload() {
#if canImport(WidgetKit)
        widgetTimelineReloadTask?.cancel()
        widgetTimelineReloadTask = Task { @MainActor in
            // Coalesce rapid read/unread toggles into a single widget reload.
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let center = WidgetCenter.shared
            center.reloadTimelines(ofKind: "NotiFeeder_Widget_LockScreenRectangular")
            center.reloadAllTimelines()
        }
#endif
    }

    private func filterAndSortMenuButton() -> some View {
        Menu {
            Section("Filter") {
                quickFilterMenuButton(title: "Heute", iconName: "calendar", selection: .today)
            }

            Section("Sortierung") {
                sortMenuButton(title: "Neueste zuerst", iconName: "arrow.down")
                sortMenuButton(title: "Älteste zuerst", iconName: "arrow.up")
            }
        } label: {
            FilterToolbarAnimatedIcon(mode: filterToolbarIconMode, tint: theme.uiAccentColor)
                .font(.body)
                .fontWeight(.light)
        }
        .buttonStyle(.plain)
        .minimumHitTarget()
        .accessibilityLabel("Filter und Sortierung")
        .accessibilityHint("Öffnet die Filter- und Sortierauswahl")
    }

    private func quickFilterMenuButton(title: String, iconName: String, selection: QuickFilterKind?) -> some View {
        let isSelected = activeQuickFilter == selection
        return Button {
            triggerLightHaptic()
            withAnimation(UIStylePolicy.Motion.standardEase) {
                setQuickFilter(isSelected ? nil : selection)
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: isSelected ? "checkmark" : iconName)
                    .fontWeight(.light)
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private var settingsAvatarImage: UIImage? {
        guard !profileAvatarData.isEmpty else { return nil }
        return UIImage(data: profileAvatarData)
    }

    private func sortMenuButton(title: String, iconName: String) -> some View {
        let isSelected = sortOption == title
        return Button {
            triggerLightHaptic()
            withAnimation(UIStylePolicy.Motion.standardEase) {
                guard sortOption != title else { return }
                sortOption = title
                sortAllEntriesGlobally()
                persistEntriesCache()
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: isSelected ? "checkmark" : iconName)
                    .fontWeight(.light)
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private func iconTint(active: Bool) -> Color {
        UIStylePolicy.iconTint(isActive: active, accent: theme.uiAccentColor)
    }

    private func setQuickFilter(_ filter: QuickFilterKind?) {
        showOfflineOnly = filter == .offline
        showOnlyBookmarks = filter == .bookmarks
        showUnreadOnly = filter == .unread
        showTodayOnly = filter == .today
    }

    private func updateFeed(original: FeedSource, updated: FeedSource) {
        guard let idx = feeds.firstIndex(where: { $0.url == original.url }) else { return }
        if original.url != updated.url {
            FeedStorage.rememberDeletedFeedURLs([original.url])
            theme.resetColor(for: original.url)
        }
        FeedStorage.forgetDeletedFeedURL(updated.url)
        feeds[idx] = updated
        if let data = try? JSONEncoder().encode(feeds) {
            let token = FeedCacheSync.write(data, for: FeedStorage.Keys.savedFeeds)
            savedFeedsData = data
            FeedICloudSyncManager.shared.pushLocalData(data, token: token, for: FeedStorage.Keys.savedFeeds)
        }
    }

    private func upsertFeed(_ feed: FeedSource) {
        FeedStorage.forgetDeletedFeedURL(feed.url)
        if let existingIndex = feeds.firstIndex(where: { $0.url == feed.url }) {
            feeds[existingIndex] = feed
        } else {
            feeds.append(feed)
            selectedFeedIDs.insert(feed.id)
            FeedStorage.includeFeedInWidgetSelection(feed.url)
        }

        if let data = try? JSONEncoder().encode(feeds) {
            let token = FeedCacheSync.write(data, for: FeedStorage.Keys.savedFeeds)
            savedFeedsData = data
            FeedICloudSyncManager.shared.pushLocalData(data, token: token, for: FeedStorage.Keys.savedFeeds)
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
            entries[index].isRead = true
            entries[index].isNew = false
            store.unmarkRecentlyRead(articleID: entry.link)
            store.setRead(true, articleID: entry.link)
            pushSnapshotToWatch()
        }
    }
    
    func markAsUnread(_ entry: FeedEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].isRead = false
            store.unmarkRecentlyRead(articleID: entry.link)
            store.setRead(false, articleID: entry.link)
            pushSnapshotToWatch()
        }
    }
    
    func toggleBookmark(for entry: FeedEntry, isCurrentlyBookmarked: Bool) {
        BookmarkService.toggleBookmark(for: entry, context: modelContext)
        if isCurrentlyBookmarked {
            bookmarkedLinks.remove(entry.link)
        } else {
            bookmarkedLinks.insert(entry.link)
        }
        let syncedLinks = BookmarkService.allBookmarkedLinks(context: modelContext)
        if syncedLinks != bookmarkedLinks {
            bookmarkedLinks = syncedLinks
        }
    }
    
    @MainActor
    func refreshBookmarkedLinks() {
        bookmarkedLinks = BookmarkService.allBookmarkedLinks(context: modelContext)
    }
    
    
    func feedTitle(for entry: FeedEntry) -> String {
        if let explicit = entry.sourceTitle, !explicit.isEmpty {
            return explicit
        }
        return feedSource(for: entry)?.title ?? "Unbekannte Quelle"
    }
    
    func feedSource(for entry: FeedEntry) -> FeedSource? {
        resolveFeed(for: entry, lookup: effectiveFeedLookupMaps)
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

private struct FilterToolbarAnimatedIcon: View {
    enum Mode {
        case none
        case unread
        case today
        case bookmarks
        case offline
    }

    let mode: Mode
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                staticIcon(for: mode)
            } else {
                animatedIcon(for: mode)
            }
        }
        .foregroundStyle(tint)
        .frame(width: 18, height: 18, alignment: .center)
        .id(mode)
    }

    @ViewBuilder
    private func staticIcon(for mode: Mode) -> some View {
        switch mode {
        case .none:
            Image(systemName: "line.3.horizontal.decrease")
        case .unread:
            Image(systemName: "eye")
        case .today:
            Image(systemName: "calendar")
        case .bookmarks:
            Image(systemName: "bookmark")
        case .offline:
            Image(systemName: "arrow.down.circle")
        }
    }

    @ViewBuilder
    private func animatedIcon(for mode: Mode) -> some View {
        switch mode {
        case .none:
            FilterTopDownFillIcon(symbolName: "line.3.horizontal.decrease")
        case .unread:
            FilterTopDownFillIcon(symbolName: "eye")
        case .today:
            FilterTopDownFillIcon(symbolName: "calendar")
        case .bookmarks:
            FilterTopDownFillIcon(symbolName: "bookmark", fillSymbolName: "bookmark.fill")
        case .offline:
            FilterTopDownFillIcon(symbolName: "arrow.down.circle")
        }
    }
}

private struct FilterTopDownFillIcon: View {
    let symbolName: String
    var fillSymbolName: String? = nil
    @State private var fillProgress: CGFloat = 0.0
    @State private var didStart = false

    var body: some View {
        ZStack {
            Image(systemName: symbolName)
            Image(systemName: fillSymbolName ?? symbolName)
                .mask(alignment: .top) {
                    Rectangle()
                        .scaleEffect(y: max(fillProgress, 0.001), anchor: .top)
                }
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true

            withAnimation(.linear(duration: 0.70)) {
                fillProgress = 1.0
            }
        }
    }
}

struct EmptyFeedView: View {
    @EnvironmentObject private var theme: ThemeSettings
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .fontWeight(.light)
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

struct FeedsSettingsView: View {
    @Binding var feeds: [FeedSource]
    @Binding var savedFeedsData: Data
    let onFeedsDidChange: () -> Void
    @State private var showAddFeedSheet: Bool = false
    @State private var hasPendingFeedReload = false

    @State private var selectedFeed: FeedSource? = nil
    @State private var feedHealthSnapshots: [String: FeedHealthSnapshot] = [:]
    @State private var feedArticleCounts: [String: Int] = [:]

    @EnvironmentObject private var theme: ThemeSettings

    private static let cacheDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    
    var body: some View {
        List {
            Section("Gespeicherte Feeds") {
                if feeds.isEmpty {
                    HStack(spacing: 12) {
                        SettingsListIconBadge(systemName: "tray", tint: theme.uiAccentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Noch keine Feeds hinzugefügt")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text("Füge deinen ersten RSS-Feed hinzu, damit Artikel in der Übersicht erscheinen.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ForEach(feeds, id: \.url) { feed in
                        HStack(spacing: 8) {
                            Button {
                                AppHaptics.selection()
                                selectedFeed = feed
                            } label: {
                                HStack(spacing: 12) {
                                    CachedFeedFaviconView(feedURLString: feed.url)
                                        .frame(width: 38, height: 38)
                                        .clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(feed.title)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                        Text(feed.url)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            FeedHealthInfoButton(
                                feed: feed,
                                snapshot: feedHealthSnapshots[feed.url],
                                articleCount: feedArticleCounts[feed.url],
                                fallbackNextRefreshDate: fallbackNextRefreshDate(for: feed)
                            )

                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .fontWeight(.semibold)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                AppHaptics.selection()
                                selectedFeed = feed
                            } label: {
                                Image(systemName: "pencil")
                                    .fontWeight(.light)
                            }
                            .tint(theme.uiAccentColor)
                            .accessibilityLabel("Feed bearbeiten")
                        }
                    }
                    .onDelete(perform: deleteFeeds)
                    .onMove(perform: moveFeeds)
                }
            }

            Section {
                Button {
                    AppHaptics.selection()
                    showAddFeedSheet = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsListIconBadge(systemName: "plus", tint: theme.uiAccentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Feed hinzufügen")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text("Neuen RSS-Feed mit eigener Farbe anlegen.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Feeds verwalten")
        .navigationBarTitleDisplayMode(.inline)
        .sheetCornerAlignedScrollContent()
        .scrollContentBackground(.hidden)
        .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $showAddFeedSheet) {
            AddSingleFeedView { newItem in
                guard let item = newItem else { return }
                if let existingIndex = feeds.firstIndex(where: { $0.url == item.url }) {
                    feeds[existingIndex] = item
                } else {
                    feeds.append(item)
                    FeedStorage.includeFeedInWidgetSelection(item.url)
                }
                FeedStorage.forgetDeletedFeedURL(item.url)
                persistFeeds()
            }
            .environmentObject(theme)
            .presentationDetents([.large])
        }
        .sheet(item: $selectedFeed, onDismiss: {
            selectedFeed = nil
        }) { feedToEdit in
            let currentColor = theme.color(for: feedToEdit.url)
            EditSingleFeedView(feed: feedToEdit, initialColor: currentColor) { updated in
                guard let updated = updated else { return }
                updateFeed(original: feedToEdit, updated: updated)
            }
            .environmentObject(theme)
            .presentationDetents([.large])
            .interactiveDismissDisabled(false)
            .presentationBackground(.clear)
        }
        .onAppear {
            restoreFeedsFromBestAvailableData()
            restoreFeedHealth()
        }
        .onChange(of: savedFeedsData) { _, _ in
            restoreFeedsFromBestAvailableData()
            restoreFeedHealth()
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedCachedEntriesDidRefresh)) { _ in
            restoreFeedHealth()
        }
        .onDisappear {
            guard hasPendingFeedReload else { return }
            hasPendingFeedReload = false
            onFeedsDidChange()
        }
    }

    private func restoreFeedHealth() {
        feedHealthSnapshots = FeedHealthStore.snapshotsByFeedURL()
        feedArticleCounts = Self.cachedArticleCountsByFeedURL()
    }

    private static func cachedArticleCountsByFeedURL() -> [String: Int] {
        guard let data = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.cachedEntries)
            ?? FeedStorage.defaults.data(forKey: FeedStorage.Keys.cachedEntries),
              let entries = try? cacheDecoder.decode([FeedEntry].self, from: data) else {
            return [:]
        }

        var counts: [String: Int] = [:]
        for entry in entries {
            guard let feedURL = entry.feedURL, !feedURL.isEmpty else { continue }
            counts[feedURL, default: 0] += 1
        }
        return counts
    }

    private func fallbackNextRefreshDate(for feed: FeedSource) -> Date? {
        if let nextRefreshDate = feedHealthSnapshots[feed.url]?.nextRefreshAfter {
            return nextRefreshDate
        }
        guard let lastRefreshDate = FeedRefreshState.lastSuccessfulRefreshDate() else { return nil }
        return lastRefreshDate.addingTimeInterval(FeedRefreshCadence.backgroundMinimumInterval)
    }

    private func restoreFeedsFromBestAvailableData() {
        let effectiveData = FeedCacheSync.bestAvailableData(for: FeedStorage.Keys.savedFeeds) ?? savedFeedsData
        guard !effectiveData.isEmpty else {
            feeds = []
            return
        }
        if let decoded = try? JSONDecoder().decode([FeedSource].self, from: effectiveData) {
            feeds = decoded
        } else {
            feeds = []
        }
    }
    
    private func persistFeeds() {
        if let data = try? JSONEncoder().encode(feeds) {
            let token = FeedCacheSync.write(data, for: FeedStorage.Keys.savedFeeds)
            savedFeedsData = data
            FeedICloudSyncManager.shared.pushLocalData(data, token: token, for: FeedStorage.Keys.savedFeeds)
            hasPendingFeedReload = true
        }
    }

    private func updateFeed(original: FeedSource, updated: FeedSource) {
        guard let originalIndex = feeds.firstIndex(where: { $0.url == original.url }) else {
            upsertFeed(updated)
            return
        }

        if original.url != updated.url {
            FeedStorage.rememberDeletedFeedURLs([original.url])
            FeedHealthStore.removeSnapshots(for: [original.url])
            theme.resetColor(for: original.url)
        }
        FeedStorage.forgetDeletedFeedURL(updated.url)

        if let duplicateIndex = feeds.firstIndex(where: { $0.url == updated.url }),
           duplicateIndex != originalIndex {
            feeds.remove(at: originalIndex)
            let adjustedDuplicateIndex = duplicateIndex > originalIndex ? duplicateIndex - 1 : duplicateIndex
            feeds[adjustedDuplicateIndex] = updated
        } else {
            feeds[originalIndex] = updated
        }

        persistFeeds()
        restoreFeedHealth()
    }

    private func upsertFeed(_ feed: FeedSource) {
        FeedStorage.forgetDeletedFeedURL(feed.url)
        if let existingIndex = feeds.firstIndex(where: { $0.url == feed.url }) {
            feeds[existingIndex] = feed
        } else {
            feeds.append(feed)
            FeedStorage.includeFeedInWidgetSelection(feed.url)
        }
        persistFeeds()
    }
    
    private func deleteFeeds(at offsets: IndexSet) {
        AppHaptics.warning()
        let removedURLs = offsets.map { feeds[$0].url }
        FeedStorage.rememberDeletedFeedURLs(removedURLs)
        FeedHealthStore.removeSnapshots(for: removedURLs)
        for url in removedURLs {
            theme.resetColor(for: url)
        }
        feeds.remove(atOffsets: offsets)
        persistFeeds()
        restoreFeedHealth()
    }
    
    private func moveFeeds(from source: IndexSet, to destination: Int) {
        AppHaptics.selection()
        feeds.move(fromOffsets: source, toOffset: destination)
        persistFeeds()
    }
}

private struct FeedHealthInfoButton: View {
    let feed: FeedSource
    let snapshot: FeedHealthSnapshot?
    let articleCount: Int?
    let fallbackNextRefreshDate: Date?

    @State private var isPresented = false
    @EnvironmentObject private var theme: ThemeSettings

    private var hasError: Bool {
        snapshot?.lastError != nil
    }

    var body: some View {
        Button {
            AppHaptics.selection()
            isPresented = true
        } label: {
            Image(systemName: hasError ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 18))
                .fontWeight(.light)
                .foregroundStyle(hasError ? Color.orange : theme.uiAccentColor)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Feed-Gesundheit anzeigen")
        .accessibilityHint("Zeigt Aktualisierung, Fehler, Artikelanzahl und nächsten Refresh")
        .popover(
            isPresented: $isPresented,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .trailing
        ) {
            FeedHealthPopover(
                feed: feed,
                snapshot: snapshot,
                articleCount: articleCount,
                fallbackNextRefreshDate: fallbackNextRefreshDate,
                accent: theme.uiAccentColor
            )
        }
    }
}

private struct FeedHealthPopover: View {
    let feed: FeedSource
    let snapshot: FeedHealthSnapshot?
    let articleCount: Int?
    let fallbackNextRefreshDate: Date?
    let accent: Color

    private var effectiveArticleCount: Int {
        articleCount ?? snapshot?.articleCount ?? 0
    }

    private var statusText: String {
        if let error = snapshot?.lastError {
            return error.feedHealthDisplayText
        }
        if snapshot?.lastAttemptAt != nil {
            return "Keine Fehler"
        }
        return "Noch kein Refresh erfasst"
    }

    private var statusColor: Color {
        snapshot?.lastError == nil ? accent : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(snapshot?.lastError == nil ? Color.secondary : Color.orange)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                FeedHealthMetricRow(
                    title: "Letzte Aktualisierung",
                    value: dateText(snapshot?.lastSuccessAt, empty: "Noch nicht erfolgreich"),
                    systemImage: "checkmark.circle"
                )
                FeedHealthMetricRow(
                    title: "Letzter Versuch",
                    value: dateText(snapshot?.lastAttemptAt, empty: "Noch nicht erfasst"),
                    systemImage: "arrow.clockwise"
                )
                FeedHealthMetricRow(
                    title: "Fehler",
                    value: snapshot?.lastError?.feedHealthDisplayText ?? "Kein Fehler",
                    systemImage: snapshot?.lastError == nil ? "checkmark.circle" : "exclamationmark.triangle"
                )
                FeedHealthMetricRow(
                    title: "Artikel",
                    value: "\(effectiveArticleCount)",
                    systemImage: "doc.text"
                )
                FeedHealthMetricRow(
                    title: "Nächster Refresh",
                    value: nextRefreshText,
                    systemImage: "clock.arrow.circlepath"
                )
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    private var nextRefreshText: String {
        guard let date = snapshot?.nextRefreshAfter ?? fallbackNextRefreshDate else {
            return "Noch nicht geplant"
        }
        if date <= Date() {
            return "frühestens jetzt"
        }
        return "frühestens \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func dateText(_ date: Date?, empty: String) -> String {
        guard let date else { return empty }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        return "\(relative) · \(DateFormatter.localized.string(from: date))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct FeedHealthMetricRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .fontWeight(.light)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension FeedFetchError {
    var feedHealthDisplayText: String {
        switch self {
        case .invalidURL:
            return "Ungültige URL"
        case .offline:
            return "Offline"
        case .timeout:
            return "Timeout"
        case .parseError:
            return "Feed konnte nicht gelesen werden"
        case .empty:
            return "Keine Artikel gefunden"
        case .network:
            return "Netzwerkfehler"
        }
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
    @State private var selectedOption: FeedColorOption? = FeedColorOption.defaultPalette.first
    @FocusState private var focusedField: Field?

    let onAdd: (FeedSource?) -> Void

    private enum Field: Hashable {
        case title
        case url
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    feedPreview
                }

                Section("Details") {
                    fieldRow(
                        placeholder: "Name",
                        text: $title,
                        keyboardType: .default,
                        autocapitalization: .words,
                        field: .title
                    )

                    fieldRow(
                        placeholder: "Feed URL",
                        text: $urlString,
                        keyboardType: .URL,
                        autocapitalization: .never,
                        field: .url
                    )
                }

                Section {
                    colorPalette
                } header: {
                    Text("Farbe")
                } footer: {
                    Text("Die Farbe dient als visueller Anker in Listen, Widgets und Feed-Details.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
            .navigationTitle("Feed hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .tint(theme.uiAccentColor)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    focusedField = .url
                }
            }
        }
    }

    private var draft: FeedDraft {
        FeedDraft(title: title, url: urlString)
    }

    private var canSave: Bool {
        draft.makeFeedSource(requireValidURL: true, fallbackTitleToURL: true) != nil
    }

    private var selectedColor: Color {
        selectedOption?.color ?? theme.uiAccentColor
    }

    private var previewTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let host = previewHost { return host }
        return "Neuer Feed"
    }

    private var previewSubtitle: String {
        previewHost ?? "RSS-Adresse einfügen"
    }

    private var previewHost: String? {
        guard
            let normalized = draft.normalizedURLString,
            let host = URL(string: normalized)?.host
        else { return nil }
        return host
    }

    private var previewLetter: String {
        if let first = previewTitle.first {
            return String(first).uppercased()
        }
        return "N"
    }

    private var feedPreview: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(selectedColor.gradient)
                Text(previewLetter)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            .shadow(color: selectedColor.opacity(0.22), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(previewTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(previewSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var colorPalette: some View {
        let options = FeedColorOption.defaultPalette

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(options) { option in
                    Button {
                        AppHaptics.selection()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedOption = option
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(option.color)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Circle()
                                        .stroke(selectedOption == option ? theme.uiAccentColor : Color.clear, lineWidth: 3)
                                }

                            if selectedOption == option {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.black.opacity(0.72))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.name)
                    .accessibilityValue(selectedOption == option ? "Ausgewählt" : "Nicht ausgewählt")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func fieldRow(
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType,
        autocapitalization: TextInputAutocapitalization,
        field: Field
    ) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(autocapitalization)
            .keyboardType(keyboardType)
            .autocorrectionDisabled(true)
            .focused($focusedField, equals: field)
            .submitLabel(field == .url ? .done : .next)
            .onSubmit {
                focusedField = field == .title ? .url : nil
            }
        .padding(.vertical, 4)
    }

    private func save() {
        guard let feed = draft.makeFeedSource(requireValidURL: true, fallbackTitleToURL: true) else { return }
        AppHaptics.success()
        if let hex = selectedOption?.hex {
            theme.setColorHex(hex, for: feed.url)
        }
        FaviconCache.prefetchFavicon(for: feed.url)
        onAdd(feed)
        dismiss()
    }
}


struct EditSingleFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeSettings
    @State private var title: String
    @State private var urlString: String
    @State private var selectedOption: FeedColorOption? = nil
    @State private var fallbackColor: Color
    @FocusState private var focusedField: Field?
    
    let onSave: (FeedSource?) -> Void

    private enum Field: Hashable {
        case title
        case url
    }
    
    init(feed: FeedSource, initialColor: Color, onSave: @escaping (FeedSource?) -> Void) {
        _title = State(initialValue: feed.title)
        _urlString = State(initialValue: feed.url)
        _fallbackColor = State(initialValue: initialColor)
        self.onSave = onSave
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    feedPreview
                }

                Section("Details") {
                    fieldRow(
                        placeholder: "Name",
                        text: $title,
                        keyboardType: .default,
                        autocapitalization: .words,
                        field: .title
                    )

                    fieldRow(
                        placeholder: "Feed URL",
                        text: $urlString,
                        keyboardType: .URL,
                        autocapitalization: .never,
                        field: .url
                    )
                }

                Section {
                    colorPalette
                } header: {
                    Text("Farbe")
                } footer: {
                    Text("Die Farbe dient als visueller Anker in Listen, Widgets und Feed-Details.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
            .navigationTitle("Feed bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .tint(theme.uiAccentColor)
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
                    Button("Abbrechen") { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save)
                        .disabled(!canSave)
                }
            }
        }
    }

    private var draft: FeedDraft {
        FeedDraft(title: title, url: urlString)
    }

    private var canSave: Bool {
        draft.makeFeedSource(requireValidURL: true, fallbackTitleToURL: true) != nil
    }

    private var selectedColor: Color {
        selectedOption?.color ?? fallbackColor
    }

    private var previewTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let host = previewHost { return host }
        return "Feed"
    }

    private var previewSubtitle: String {
        previewHost ?? "RSS-Adresse einfügen"
    }

    private var previewHost: String? {
        guard
            let normalized = draft.normalizedURLString,
            let host = URL(string: normalized)?.host
        else { return nil }
        return host
    }

    private var previewLetter: String {
        if let first = previewTitle.first {
            return String(first).uppercased()
        }
        return "F"
    }

    private var feedPreview: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(selectedColor.gradient)

                Text(previewLetter)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            .shadow(color: selectedColor.opacity(0.22), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(previewTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(previewSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var colorPalette: some View {
        let options = FeedColorOption.defaultPalette

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(options) { option in
                    Button {
                        AppHaptics.selection()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedOption = option
                            fallbackColor = option.color
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(option.color)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Circle()
                                        .stroke(selectedOption == option ? theme.uiAccentColor : Color.clear, lineWidth: 3)
                                }

                            if selectedOption == option {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.black.opacity(0.72))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.name)
                    .accessibilityValue(selectedOption == option ? "Ausgewählt" : "Nicht ausgewählt")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func fieldRow(
        placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType,
        autocapitalization: TextInputAutocapitalization,
        field: Field
    ) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(autocapitalization)
            .keyboardType(keyboardType)
            .autocorrectionDisabled(true)
            .focused($focusedField, equals: field)
            .submitLabel(field == .url ? .done : .next)
            .onSubmit {
                focusedField = field == .title ? .url : nil
            }
        .padding(.vertical, 4)
    }

    private func save() {
        guard let updated = draft.makeFeedSource(requireValidURL: true, fallbackTitleToURL: true) else { return }
        AppHaptics.success()
        if let hex = selectedOption?.hex {
            theme.setColorHex(hex, for: updated.url)
        }
        onSave(updated)
        FaviconCache.prefetchFavicon(for: updated.url)
        dismiss()
    }
}

struct PersonalizationViewPlaceholder: View {
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage("ui.cards.style.fullColor") private var fullColorCards: Bool = false
    
    var body: some View {
        List {
            Section {
                Toggle(isOn: $fullColorCards) {
                    HStack(spacing: 12) {
                        SettingsListIconBadge(
                            systemName: fullColorCards ? "rectangle.inset.filled" : "rectangle",
                            tint: theme.uiAccentColor
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Vollflächige Kacheln")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text("Nutzen die Feed-Farbe als deutlichere Kartenfläche.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(theme.uiAccentColor)
            } header: {
                Text("Kartenstil")
            } footer: {
                Text("Aktiviere das für stärkere Farbakzente in der Feed-Übersicht.")
                    .font(.footnote)
            }
        }
        .sheetCornerAlignedScrollContent()
        .scrollContentBackground(.hidden)
        .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
        .listStyle(.insetGrouped)
        .navigationTitle("Karten & Layout")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.uiAccentColor)
        .onChange(of: fullColorCards) { _, newValue in
            AppHaptics.selection()
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.uiCardsStyleFullColor)
        }
    }
}

struct InfoViewPlaceholder: View {
    @EnvironmentObject private var theme: ThemeSettings

    var body: some View {
        List {
            Section("Autor") {
                infoLinkRow(
                    label: "Name",
                    title: "Dyonisos Fergadiotis",
                    destination: URL(string: "https://dyonisosfergadiotis.de")!
                )
            }

            Section("App") {
                infoRow(label: "Version", value: appVersion)
                infoRow(label: "Build", value: appBuild)
            }

            Section("Rechtliches") {
                infoRow(label: "Lizenz", value: "MIT License")
                infoRow(label: "Copyright", value: "© \(Calendar.current.component(.year, from: Date())) Dyonisos Fergadiotis")
            }
        }
        .sheetCornerAlignedScrollContent()
        .scrollContentBackground(.hidden)
        .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
        .listStyle(.insetGrouped)
        .navigationTitle("App & Info")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.body)
                .foregroundStyle(.primary)
        }
    }

    private func infoLinkRow(label: String, title: String, destination: URL) -> some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Link(title, destination: destination)
                .font(.body)
                .foregroundStyle(theme.uiAccentColor)
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
