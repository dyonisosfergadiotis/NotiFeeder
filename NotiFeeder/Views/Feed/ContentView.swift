import SwiftUI
import Foundation
import FoundationModels
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var feeds: [FeedSource] = []
    @State private var showOnboarding: Bool = false
    @AppStorage("didRunOnboarding") private var didRunOnboarding: Bool = false
    @AppStorage(UserProfileStore.displayNameKey) private var profileDisplayName: String = ""
    @State private var showSettingsSheet: Bool = false
    @State private var showProfileSetupSheet: Bool = false
    
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
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.feedColorMap)
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.savedArticles)
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.readArticleIDs)
            FeedCacheSync.syncIfNeeded(for: FeedStorage.Keys.bookmarkedArticleIDs)
            FeedICloudSyncManager.shared.configureIfNeeded()
            FeedICloudSyncManager.shared.syncAllFromCloudIfNeeded()
            theme.syncFromCloudIfNeeded()
            ArticleStore.shared.syncFromCloudIfNeeded()
            loadFeeds()
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
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            FeedICloudSyncManager.shared.syncAllFromCloudIfNeeded()
            theme.syncFromCloudIfNeeded()
            ArticleStore.shared.syncFromCloudIfNeeded()
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
            SettingsView(feeds: $feeds, savedFeedsData: $savedFeedsData)
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

    private var requiresProfileSetup: Bool {
        UserProfileStore.sanitizedDisplayName(profileDisplayName).isEmpty
    }

    private func evaluateProfileSetupPresentation() {
        showProfileSetupSheet = requiresProfileSetup && !showOnboarding
    }
}

private struct FeedScrollMetrics: Equatable {
    let distanceFromTop: CGFloat
    let scrollableDistance: CGFloat
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
    
    @EnvironmentObject private var store: ArticleStore
    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var networkState: NetworkState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @AppStorage(FeedStorage.Keys.cachedEntries, store: FeedStorage.defaults) private var cachedEntriesData: Data = Data()
    @AppStorage(UserProfileStore.avatarImageDataKey) private var profileAvatarData: Data = Data()
    
    @AppStorage("ui.cards.style.fullColor") private var fullColorCards: Bool = false
    
    @FocusState private var isToolbarSearchFocused: Bool
    
    @State private var entries: [FeedEntry] = []
    @State private var isLoading = false
    @State private var sortOption = "Neueste zuerst"
    @AppStorage("feed.filter.unreadOnly", store: FeedStorage.defaults) private var showUnreadOnly: Bool = false
    @State private var didTriggerInitialLoad = false
    @State private var path: [FeedEntry] = []
    @State private var didRestoreCachedEntries = false
    @State private var selectedFeedIDs: Set<String> = []
    @State private var didInitializeFeedSelection = false
    @State private var activeFeedTabID: String = FeedFilterSelection.all
    
    @State private var feedToEdit: FeedSource? = nil
    @State private var showOnlyBookmarks: Bool = false
    @State private var showTodayOnly: Bool = false
    
    @State private var refreshTask: Task<Void, Never>? = nil
    @State private var feedsReloadTask: Task<Void, Never>? = nil
    @State private var statusBarRefreshTask: Task<Void, Never>? = nil
    @State private var widgetTimelineReloadTask: Task<Void, Never>? = nil
    @State private var lastRefreshDate: Date? = nil
    @State private var bookmarkedLinks: Set<String> = []
    @State private var pendingInsertedEntryIDs: Set<String> = []
    @State private var insertionAnimationCleanupTask: Task<Void, Never>? = nil
    @State private var showBackToTopToolbarButton = false
    @State private var scrollToTopRequestToken = 0
    @State private var lastObservedScrollDistanceFromTop: CGFloat = 0
    @State private var topChromeHidden = false
    @State private var isSearchBarExpanded = false
    @State private var renderedEntryLimit: Int = 0
    @State private var lastRenderContextKey: String = ""
    @State private var didPrepareDerivedFeedState = false
    @State private var cachedFeedLookupMaps = FeedLookupMaps.empty
    @State private var cachedVisibleEntries: [FeedEntry] = []
    @State private var cachedFeedPillFeeds: [FeedSource] = []
    
    // New states for launch screen overlay
    @State private var showLaunchScreen: Bool = true
    @State private var didInitialFeedLoad: Bool = false
    @State private var launchScreenShownAt: Date? = nil


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
    private let backToTopVisibilityThreshold: CGFloat = 60
    private let topChromeScrollDeltaThreshold: CGFloat = 14
    private let scrollMetricsUpdateDistanceThreshold: CGFloat = 12
    private let initialCardAppearanceAnimationCount: Int = 12
    private let initialRenderBatchSize: Int = 60
    private let renderBatchSize: Int = 40
    private let renderPrefetchThreshold: Int = 16
    private let launchScreenSafetyAutoHideDelay: TimeInterval = 0.12
    private let launchScreenMinimumVisibleDuration: TimeInterval = 0
    private let launchScreenHideAnimationDuration: TimeInterval = 0.16

    private var recentlyReadLinks: Set<String> {
        store.recentlyReadArticleIDs
    }

    private var showsSearchCloseButton: Bool {
        isSearchBarExpanded || isToolbarSearchFocused || !searchText.isEmpty
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
        let daySections = daySections(for: displayedEntries)

        return ScrollViewReader { scrollProxy in
            ZStack(alignment: .top) {
                List {
                    ForEach(daySections) { section in
                        Section {
                            if section.title != "Heute" {
                                daySectionDividerRow(title: section.title)
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }

                            ForEach(section.entries) { dayEntry in
                                trackedEntryRow(
                                    for: dayEntry.entry,
                                    index: dayEntry.index,
                                    lookup: lookup
                                )
                                .onAppear {
                                    loadMoreEntriesIfNeeded(
                                        currentIndex: dayEntry.index,
                                        totalVisibleCount: visibleEntries.count
                                    )
                                }
                            }
                        }
                    }

                    if visibleEntries.isEmpty {
                        Color.clear
                            .frame(height: 140)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .accessibilityHidden(true)
                    }

                    if hasMoreEntries {
                        feedListLoadingRow
                            .onAppear {
                                loadMoreEntriesIfNeeded(
                                    currentIndex: max(0, effectiveLimit - 1),
                                    totalVisibleCount: visibleEntries.count
                                )
                            }
                    }
                }
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
                                entries[idx].isNew = false
                            }
                        }
                        store.clearRecentlyRead()
                        persistEntriesCache()
                        pushSnapshotToWatch()
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                //.listRowSpacing(6)
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
                .onScrollGeometryChange(
                    for: FeedScrollMetrics.self,
                    of: { geometry in
                        let distanceFromTop = max(0, geometry.contentOffset.y + geometry.contentInsets.top)
                        let scrollableDistance = max(
                            0,
                            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom - geometry.containerSize.height
                        )
                        return FeedScrollMetrics(
                            distanceFromTop: distanceFromTop,
                            scrollableDistance: scrollableDistance
                        )
                    },
                    action: { oldMetrics, newMetrics in
                        guard shouldProcessScrollMetricsChange(from: oldMetrics, to: newMetrics) else {
                            return
                        }
                        handleScrollMetricsChange(newMetrics)
                    }
                )
                .onChange(of: activeFeedTabID) { _, _ in
                    showBackToTopToolbarButton = false
                    topChromeHidden = false
                    lastObservedScrollDistanceFromTop = 0
                }
                .onChange(of: scrollToTopRequestToken) { _, _ in
                    guard let firstEntryID = visibleEntries.first?.id else { return }
                    withAnimation(.easeInOut(duration: 0.22)) {
                        scrollProxy.scrollTo(firstEntryID, anchor: .top)
                    }
                }
                .onChange(of: visibleEntries.isEmpty) { _, isEmpty in
                    if isEmpty {
                        showBackToTopToolbarButton = false
                        topChromeHidden = false
                        lastObservedScrollDistanceFromTop = 0
                    }
                }
                .overlay {
                    EmptyEntriesOverlay(isEmpty: visibleEntries.isEmpty)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if showsFeedSegmentedPicker {
                        segmentedPickerFeeds
                    }
                }
            }
        }
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
        .padding(.vertical, 1)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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
    private func trackedEntryRow(for entry: FeedEntry, index: Int, lookup: FeedLookupMaps) -> some View {
        entryRow(for: entry, index: index, lookup: lookup)
    }

    private func handleScrollMetricsChange(_ metrics: FeedScrollMetrics) {
        let distanceFromTop = metrics.distanceFromTop
        let canShowBackToTopButton = metrics.scrollableDistance > backToTopVisibilityThreshold
        let shouldShowButton = canShowBackToTopButton && distanceFromTop > backToTopVisibilityThreshold
        if shouldShowButton != showBackToTopToolbarButton {
            withAnimation(.easeInOut(duration: 0.18)) {
                showBackToTopToolbarButton = shouldShowButton
            }
        }

        let delta = distanceFromTop - lastObservedScrollDistanceFromTop
        if distanceFromTop <= 8 {
            if topChromeHidden {
                withAnimation(.easeInOut(duration: 0.22)) {
                    topChromeHidden = false
                }
            }
        } else if delta > topChromeScrollDeltaThreshold, !topChromeHidden {
            withAnimation(.easeInOut(duration: 0.22)) {
                topChromeHidden = true
            }
        } else if delta < -topChromeScrollDeltaThreshold, topChromeHidden {
            withAnimation(.easeInOut(duration: 0.22)) {
                topChromeHidden = false
            }
        }

        lastObservedScrollDistanceFromTop = distanceFromTop
    }

    private func shouldProcessScrollMetricsChange(from oldMetrics: FeedScrollMetrics,
                                                  to newMetrics: FeedScrollMetrics) -> Bool {
        let oldDistance = oldMetrics.distanceFromTop
        let newDistance = newMetrics.distanceFromTop

        let oldCanShowBackToTopButton = oldMetrics.scrollableDistance > backToTopVisibilityThreshold
        let newCanShowBackToTopButton = newMetrics.scrollableDistance > backToTopVisibilityThreshold
        if oldCanShowBackToTopButton != newCanShowBackToTopButton {
            return true
        }

        if abs(newDistance - oldDistance) >= scrollMetricsUpdateDistanceThreshold {
            return true
        }

        let oldNearTop = oldDistance <= 8
        let newNearTop = newDistance <= 8
        if oldNearTop != newNearTop {
            return true
        }

        let oldPastBackToTopThreshold = oldCanShowBackToTopButton && oldDistance > backToTopVisibilityThreshold
        let newPastBackToTopThreshold = newCanShowBackToTopButton && newDistance > backToTopVisibilityThreshold
        return oldPastBackToTopThreshold != newPastBackToTopThreshold
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

    private func loadMoreEntriesIfNeeded(currentIndex: Int, totalVisibleCount: Int) {
        guard totalVisibleCount > 0 else { return }

        let currentLimit = effectiveRenderedEntryLimit(totalVisibleCount: totalVisibleCount)
        guard currentLimit < totalVisibleCount else { return }

        let triggerIndex = max(0, currentLimit - renderPrefetchThreshold)
        guard currentIndex >= triggerIndex else { return }

        let expandedLimit = min(totalVisibleCount, currentLimit + renderBatchSize)
        guard expandedLimit != renderedEntryLimit else { return }

        renderedEntryLimit = expandedLimit
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
        ZStack {
            mainContentView
            if showLaunchScreen {
                launchScreenView
            }
        }
    }

    private var launchScreenView: some View {
        ZStack {
            AccentBackground(accent: theme.uiAccentColor)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                AppIconArtwork()
                Text(launchScreenAppName)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
        .onAppear {
            if launchScreenShownAt == nil {
                launchScreenShownAt = Date()
            }
        }
        .task {
            // Safety auto-hide: if no loading path hides the overlay, hide promptly.
            try? await Task.sleep(nanoseconds: UInt64(launchScreenSafetyAutoHideDelay * 1_000_000_000))
            hideLaunchScreenIfNeeded()
        }
    }

    private var launchScreenAppName: String {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !displayName.isEmpty {
            return displayName
        }
        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !bundleName.isEmpty {
            return bundleName
        }
        return "NotiFeeder"
    }

    private var mainContentView: some View {
        let navigationView = NavigationStack(path: $path) {
            feedListView(for: activeFeedTabID)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { feedToolbar }
                .toolbarBackground(.hidden, for: .navigationBar)
                .sheet(item: $feedToEdit, onDismiss: {
                    feedToEdit = nil
                }) { feed in
                    EditSingleFeedView(feed: feed, initialColor: theme.color(for: feed.url)) { updated in
                        guard let updated = updated else { return }
                        updateFeed(original: feed, updated: updated)
                    }
                    .environmentObject(theme)
                    .presentationDetents([.fraction(0.6)])
                    .presentationBackground(.clear)
                }
                .navigationDestination(for: FeedEntry.self) { entry in
                    navigationDestinationView(entry)
                }
        }

        let contentWithStateObservers = navigationView
            .onAppear {
                refreshDerivedFeedState()
                if !didRestoreCachedEntries {
                    didRestoreCachedEntries = true
                    restoreCachedEntries()
                }
                if lastRefreshDate == nil {
                    lastRefreshDate = FeedRefreshState.lastSuccessfulRefreshDate()
                }
                normalizeSelectedFeedIDs()
                persistWidgetSelectionContext()
                triggerInitialLoadIfPossible()
                pruneEntriesForRemovedFeeds()
                Task { @MainActor in
                    syncCloudStateFromICloud()
                }
                pushSnapshotToWatch()
            }
            .onChange(of: feeds) { _, newValue in
                normalizeSelectedFeedIDs(using: newValue)
                persistWidgetSelectionContext()
                scheduleWidgetTimelineReload()
                refreshDerivedFeedState()
            }
            .onChange(of: selectedFeedIDs) { _, _ in
                persistWidgetSelectionContext()
                scheduleWidgetTimelineReload()
                refreshDerivedFeedState()
            }
            .onChange(of: networkState.isOffline) { _, isOffline in
                guard isOffline else { return }
                completeInitialFeedLoad()
            }
            .onChange(of: showOnlyBookmarks) { _, _ in
                persistWidgetSelectionContext()
                scheduleWidgetTimelineReload()
                refreshDerivedFeedState()
            }
            .onChange(of: store.readArticleIDs) { oldValue, newValue in
                applyReadStateFromStore()
                persistEntriesCache()
                pushSnapshotToWatch()
                let shouldReload = shouldReloadWidgetForReadStateChange(
                    from: oldValue,
                    to: newValue
                )
                if shouldReload {
                    scheduleWidgetTimelineReload()
                }
                refreshDerivedFeedState()
            }
            .onChange(of: showUnreadOnly) { _, _ in
                persistWidgetSelectionContext()
                scheduleWidgetTimelineReload()
                refreshDerivedFeedState()
            }
            .onChange(of: showTodayOnly) { _, _ in
                persistWidgetSelectionContext()
                scheduleWidgetTimelineReload()
                refreshDerivedFeedState()
            }
            .onChange(of: entries) { _, _ in
                refreshDerivedFeedState()
            }
            .onChange(of: searchText) { _, _ in
                refreshDerivedFeedState()
            }
            .onChange(of: activeFeedTabID) { _, _ in
                refreshDerivedFeedState()
            }
            .onChange(of: bookmarkedLinks) { _, _ in
                refreshDerivedFeedState()
            }
            .onChange(of: store.recentlyReadArticleIDs) { _, _ in
                refreshDerivedFeedState()
            }

        return contentWithStateObservers
            .onReceive(NotificationCenter.default.publisher(for: .feedBookmarkedArticleIDsDidSyncFromICloud)) { _ in
                Task { @MainActor in
                    BookmarkService.syncBookmarksFromCloudIfNeeded(context: modelContext)
                    refreshBookmarkedLinks()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .feedCachedEntriesDidRefresh)) { _ in
                restoreCachedEntries()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                restoreCachedEntries()
                Task { @MainActor in
                    await refreshOnAppActivationIfNeeded()
                }
            }
            .onOpenURL { url in
                Task { @MainActor in
                    handleDeepLink(url)
                }
            }
            .onDisappear {
                refreshTask?.cancel()
                feedsReloadTask?.cancel()
                statusBarRefreshTask?.cancel()
                widgetTimelineReloadTask?.cancel()
                insertionAnimationCleanupTask?.cancel()
            }
    }
    
    private var isAtTopOfFeedList: Bool {
        lastObservedScrollDistanceFromTop <= 8
    }

    private var showsFeedSegmentedPicker: Bool {
        feeds.count > 1 && !feedPillFeeds.isEmpty
    }

    private var segmentedPickerFeeds: some View {
        let visibleFeeds = feedPillFeeds
        let visibleFeedIDs = Set(visibleFeeds.map(\.id))
        let allFeedTints = visibleFeeds.map { theme.color(for: $0.url) }
        let shouldShowAllPill = visibleFeeds.count >= 2
        let allPillIsActive = !visibleFeedIDs.isEmpty && resolvedSelectedFeedIDs.isSuperset(of: visibleFeedIDs)
        let shouldHideTopChrome = topChromeHidden || !isAtTopOfFeedList
        let feedPillIndexOffset = shouldShowAllPill ? 1 : 0

        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 8) {
                        if shouldShowAllPill {
                            FeedSegmentPill(
                                title: "Alle",
                                tints: allFeedTints.isEmpty ? [theme.uiAccentColor] : allFeedTints,
                                isActive: allPillIsActive,
                                useFullColorBackground: fullColorCards
                            ) {
                                withAnimation(UIStylePolicy.Motion.standardEase) {
                                    toggleAllFeedSelection(for: visibleFeedIDs)
                                }
                            }
                            .modifier(
                                FeedPillStackingModifier(
                                    index: 0,
                                    isCollapsed: shouldHideTopChrome
                                )
                            )
                        }

                        ForEach(Array(visibleFeeds.enumerated()), id: \.element.id) { index, feed in
                            FeedSegmentPill(
                                title: feedDisplayTitle(for: feed),
                                tints: [theme.color(for: feed.url)],
                                isActive: resolvedSelectedFeedIDs.contains(feed.id),
                                useFullColorBackground: fullColorCards
                            ) {
                                withAnimation(UIStylePolicy.Motion.standardEase) {
                                    toggleFeedSelection(for: feed.id)
                                }
                            }
                            .modifier(
                                FeedPillStackingModifier(
                                    index: index + feedPillIndexOffset,
                                    isCollapsed: shouldHideTopChrome
                                )
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: shouldHideTopChrome ? -12 : 0)
        }
        .padding(.top, 2)
        .allowsHitTesting(!shouldHideTopChrome)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: shouldHideTopChrome)
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

    @ToolbarContentBuilder
    private var feedToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text("Feed")
                    .font(.headline)
                if networkState.isOffline {
                    Text("Offline")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }

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
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .task {
                        isToolbarSearchFocused = true
                    }
                } else {
                    Button {
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
        if showsSearchCloseButton {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    clearAndDismissSearch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body)
                        .fontWeight(.light)
                        .foregroundStyle(theme.uiAccentColor)
                }
                .buttonStyle(.plain)
                .minimumHitTarget()
                .accessibilityLabel("Suche schließen")
                .accessibilityHint("Leert die Suche und beendet die Eingabe")
            }
        } else if showBackToTopToolbarButton {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    scrollToTopRequestToken += 1
                } label: {
                    Image(systemName: "arrow.up.to.line")
                        .font(.body)
                        .fontWeight(.light)
                        .foregroundStyle(theme.uiAccentColor)
                }
                .minimumHitTarget()
                .accessibilityLabel("Nach oben")
                .accessibilityHint("Scrollt zurück zum Listenanfang")
                .buttonStyle(.plain)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.94)),
                        removal: .move(edge: .trailing)
                            .combined(with: .opacity)
                    )
                )
            }
        }

        ToolbarItemGroup(placement: .topBarLeading) {
            Button {
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
            .minimumHitTarget()
            .accessibilityLabel("Einstellungen")
        }

        // Gruppe 2: Filter + Sortierung
        ToolbarSpacer(.fixed,placement: .topBarTrailing)
        ToolbarItemGroup(placement: .topBarTrailing) {
            filterAndSortMenuButton()
        } // <- Ende ToolbarItemGroup topBarTrailing
    } // <- Ende feedToolbar

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
                        if isRead {
                            entries[idx].isNew = false
                        }
                    }
                    if isRead {
                        store.markRecentlyRead(articleID: entry.link)
                    } else {
                        store.unmarkRecentlyRead(articleID: entry.link)
                    }
                }
                persistEntriesCache()
            },
            onToggleBookmark: { isBookmarked in
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isBookmarked {
                        bookmarkedLinks.insert(entry.link)
                    } else {
                        bookmarkedLinks.remove(entry.link)
                    }
                }
            }
        )
    }
    
    @ViewBuilder
    private func entryRow(for entry: FeedEntry, index: Int, lookup: FeedLookupMaps) -> some View {
        let matchedFeed = resolveFeed(for: entry, lookup: lookup)
        let feedName = {
            if let explicit = entry.sourceTitle, !explicit.isEmpty {
                return explicit
            }
            return matchedFeed?.title ?? "Unbekannte Quelle"
        }()
        let rowFeedColor = feedColor(for: matchedFeed?.url)
        let shouldAnimateInitialAppearance = !didInitialFeedLoad && index < initialCardAppearanceAnimationCount
        let shouldAnimateInsertedAppearance = pendingInsertedEntryIDs.contains(entry.id)
        let shouldAnimateCardAppearance = shouldAnimateInitialAppearance || shouldAnimateInsertedAppearance
        let baseDelay = shouldAnimateCardAppearance ? min(Double(index) * 0.015, 0.12) : 0
        let entryDateValue = entryDate(for: entry)
        let detailEntry: FeedEntry = {
            var updated = entry
            updated.sourceTitle = feedName
            updated.feedURL = matchedFeed?.url
            return updated
        }()
        let isBookmarked = bookmarkedLinks.contains(detailEntry.link)
        
        Button {
            var navigationEntry = detailEntry
            // Opening an unread item -> becomes read + recently; if already read, never becomes recently again
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
            path.append(navigationEntry)
        } label: {
            let card = ArticleCardView(
                feedTitle: feedName,
                feedColor: rowFeedColor,
                articleLink: entry.link,
                title: entry.displayTitle,
                summary: entry.content,
                imageURL: entry.imageURL,
                isRead: entry.isRead,
                date: entryDateValue,
                isBookmarked: isBookmarked,
                highlightTerm: searchText.isEmpty ? nil : searchText,
                highlightColor: rowFeedColor,
                useFullColorBackground: fullColorCards
            )
                .background(Color(.systemBackground).opacity(0.0))
                .overlay(
                    Group {
                        if !fullColorCards {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(
                                    (entry.isRead)
                                    ? rowFeedColor.opacity(0.2)
                                    : rowFeedColor.opacity(0.6),
                                    lineWidth: 1
                                )
                        }
                    }
                )
            
            Group {
                if shouldAnimateCardAppearance {
                    card
                        .articleCardAppear(trigger: entry.id,
                                           delay: baseDelay,
                                           glowColor: rowFeedColor,
                                           speedFactor: 1)
                } else {
                    card
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
        .accessibilityValue(entryRowAccessibilityValue(feedName: feedName,
                                                       isRead: entry.isRead,
                                                       isBookmarked: isBookmarked,
                                                       date: entryDateValue))
        .accessibilityHint("Öffnet Artikel")
        .listRowBackground(Color(.systemBackground).opacity(0.0))
        .background(Color(.systemBackground).opacity(0.0))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowSeparatorTint(.clear)
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
                        glowOpacity: 0.11,
                        glowRadius: 20,
                        glowYOffset: 6
                    )
                )
            )
        )
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            let isReadState = entry.isRead
            Button {
                if isReadState {
                    markAsUnread(entry)
                } else {
                    markAsRead(entry)
                }
            } label: {
                Image(systemName: isReadState ? "eye.slash" : "eye")
                    .fontWeight(.light)
            }
            .accessibilityLabel(isReadState ? "Als ungelesen markieren" : "Als gelesen markieren")
            .tint(theme.uiSwipeColor)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                toggleBookmark(for: detailEntry, isCurrentlyBookmarked: isBookmarked)
            } label: {
                Image(systemName: isBookmarked ? "bookmark.slash" : "bookmark")
                    .fontWeight(.light)
            }
            .accessibilityLabel(isBookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen")
            .tint(isBookmarked ? .red : theme.uiSwipeColor)
        }
    }
    
    private func triggerInitialLoadIfPossible() {
        guard !feeds.isEmpty else {
            // No feeds to load; hide launch screen quickly so the user can proceed
            completeInitialFeedLoad()
            return
        }
        didTriggerInitialLoad = true

        // Prefer immediate access to cached/local content when offline.
        if networkState.isOffline {
            completeInitialFeedLoad()
            return
        }

        // Only show launch screen on first cold start, not on background resume
        if !didInitialFeedLoad {
            showLaunchScreen = true
        }
        Task {
            await loadRSSFeed()
        }
    }

    @MainActor
    private func completeInitialFeedLoad(minimumVisibleDuration: TimeInterval = 0) {
        guard !didInitialFeedLoad else { return }
        hideLaunchScreenIfNeeded(minimumVisibleDuration: minimumVisibleDuration)
        didInitialFeedLoad = true
    }

    @MainActor
    private func hideLaunchScreenIfNeeded(minimumVisibleDuration: TimeInterval = 0) {
        guard showLaunchScreen else { return }

        let hideNow = {
            withAnimation(.easeOut(duration: launchScreenHideAnimationDuration)) {
                showLaunchScreen = false
            }
            launchScreenShownAt = nil
        }

        guard minimumVisibleDuration > 0, let shownAt = launchScreenShownAt else {
            hideNow()
            return
        }

        let elapsed = Date().timeIntervalSince(shownAt)
        let remaining = minimumVisibleDuration - elapsed
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                guard showLaunchScreen else { return }
                hideNow()
            }
        } else {
            hideNow()
        }
    }

    @MainActor
    private func refreshOnAppActivationIfNeeded() async {
        guard !feeds.isEmpty else { return }
        guard !isLoading else { return }
        guard !networkState.isOffline else { return }
        let minimumRefreshAge: TimeInterval = 120
        let now = Date()

        if let persistedDate = FeedRefreshState.lastSuccessfulRefreshDate() {
            let persistedAge = now.timeIntervalSince(persistedDate)
            guard persistedAge >= minimumRefreshAge else { return }
        }

        if let lastRefreshDate {
            let age = now.timeIntervalSince(lastRefreshDate)
            guard age >= minimumRefreshAge else { return }
        }

        await loadRSSFeed()
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

private struct AppIconArtwork: View {
    var body: some View {
        Group {
            if let iconImage = UIImage.primaryAppIcon {
                Image(uiImage: iconImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .fontWeight(.light)
                    .scaledToFit()
                    .padding(24)
                    .foregroundStyle(.primary.opacity(0.85))
                    .background(.ultraThinMaterial)
            }
        }
        .frame(width: 116, height: 116)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 8)
        .accessibilityHidden(true)
    }
}

private extension UIImage {
    static var primaryAppIcon: UIImage? {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconFiles = primaryIcon?["CFBundleIconFiles"] as? [String]

        for iconName in (iconFiles ?? []).reversed() {
            if let image = UIImage(named: iconName) {
                return image
            }
        }

        return nil
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
}

private struct FeedSegmentPill: View {
    let title: String
    let tints: [Color]
    let isActive: Bool
    let useFullColorBackground: Bool
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
            return colorScheme == .dark
            ? Color.white.opacity(0.96)
            : (Self.isLight(representativeTint) ? Color.black.opacity(0.86) : Color.white.opacity(0.96))
        }
        return colorScheme == .dark
        ? Color.white.opacity(0.42)
        : Color.black.opacity(0.62)
    }

    private var capsuleFill: Color {
        let contrastBoost = colorSchemeContrast == .increased ? 0.08 : 0
        if useFullColorBackground {
            let tintColor = isActive
            ? representativeTint
            : (colorScheme == .dark ? Color.white : Color.black)
            let baseOpacity = isActive
            ? (colorScheme == .dark ? 0.30 : 0.30)
            : (colorScheme == .dark ? 0.14 : 0.14)
            return tintColor.opacity(min(1, baseOpacity + contrastBoost))
        }

        let neutralBase = colorScheme == .dark ? Color.white : Color.black
        let baseOpacity = isActive
        ? (colorScheme == .dark ? 0.05 : 0.11)
        : (colorScheme == .dark ? 0.035 : 0.075)
        return neutralBase.opacity(min(1, baseOpacity + (contrastBoost * 0.4)))
    }

    private var capsuleStroke: Color {
        let contrastBoost = colorSchemeContrast == .increased ? 0.10 : 0
        if useFullColorBackground {
            return (isActive ? representativeTint : (colorScheme == .dark ? Color.white : Color.black))
                .opacity(min(1, (isActive ? 0.22 : 0.14) + contrastBoost))
        }

        let strokeBase = isActive ? representativeTint : (colorScheme == .dark ? Color.white : Color.black)
        let baseOpacity = isActive
        ? (colorScheme == .dark ? 0.78 : 0.62)
        : (colorScheme == .dark ? 0.22 : 0.30)
        return strokeBase.opacity(min(1, baseOpacity + contrastBoost))
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(labelColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Capsule())
        .background(capsuleFill, in: Capsule())
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
        .frame(minHeight: FeedPillMetrics.height)
        .accessibilityAddTraits(isActive ? .isSelected : [])
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

private struct FeedPillStackingModifier: ViewModifier {
    let index: Int
    let isCollapsed: Bool

    func body(content: Content) -> some View {
        let travel = CGFloat(26 + (min(index, 10) * 10))
        let xOffset = isCollapsed ? -travel : 0
        let yOffset: CGFloat = 0
        let opacity = isCollapsed ? 0.0 : 1.0
        let delayFactor = isCollapsed ? 0.004 : 0.012
        let delay = Double(min(index, 12)) * delayFactor
        let animation: Animation = isCollapsed
        ? .spring(response: 0.20, dampingFraction: 0.90, blendDuration: 0.08)
        : .spring(response: 0.32, dampingFraction: 0.86, blendDuration: 0.12)

        return content
            .offset(x: xOffset, y: yOffset)
            .opacity(opacity)
            .zIndex(Double(250 - index))
            .animation(
                animation.delay(delay),
                value: isCollapsed
            )
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

    private func scheduleInsertionAnimationCleanup() {
        insertionAnimationCleanupTask?.cancel()
        let entryIDsToClear = pendingInsertedEntryIDs
        guard !entryIDsToClear.isEmpty else { return }

        insertionAnimationCleanupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            pendingInsertedEntryIDs.subtract(entryIDsToClear)
        }
    }

    @MainActor
    private func syncCloudStateFromICloud() {
        FeedICloudSyncManager.shared.syncAllFromCloudIfNeeded()
        theme.syncFromCloudIfNeeded()
        store.syncFromCloudIfNeeded()
        BookmarkService.syncBookmarksFromCloudIfNeeded(context: modelContext)
        refreshBookmarkedLinks()
        applyReadStateFromStore()
    }

    private func applyReadStateFromStore() {
        let readIDs = store.readArticleIDs
        for index in entries.indices {
            entries[index].isRead = readIDs.contains(entries[index].link)
            if entries[index].isRead {
                entries[index].isNew = false
            }
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
    private func applyEntriesSnapshot(_ snapshot: [FeedEntry], insertedEntryIDs: Set<String> = [], persistCache: Bool) {
        let normalizedSnapshot = sortedAndLimitedEntries(snapshot)
        let visibleInsertedEntryIDs = insertedEntryIDs.intersection(Set(normalizedSnapshot.map(\.id)))

        if visibleInsertedEntryIDs.isEmpty {
            withTransaction(Transaction(animation: nil)) {
                entries = normalizedSnapshot
            }
        } else {
            pendingInsertedEntryIDs.formUnion(visibleInsertedEntryIDs)
            scheduleInsertionAnimationCleanup()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9, blendDuration: 0.12)) {
                entries = normalizedSnapshot
            }
        }

        if persistCache {
            persistEntriesCache()
        }
    }

    @MainActor
    func loadRSSFeed() async {
        syncCloudStateFromICloud()

        // Offline fast path: keep cached/local state visible and avoid network waits.
        guard !networkState.isOffline else {
            completeInitialFeedLoad()
            return
        }

        isLoading = true

        let feedsSnapshot = feeds
        var newEntries: [FeedEntry] = []
        
        await withTaskGroup(of: (FeedSource, FeedFetchStatus).self) { group in
            for feed in feedsSnapshot {
                group.addTask {
                    let status = await fetchFeed(feed)
                    return (feed, status)
                }
            }
            
            for await (feed, status) in group {
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
            persistCache: true
        )
        scheduleOfflinePreload(for: mergeResult.entries)

        isLoading = false
        let refreshDate = Date()
        lastRefreshDate = refreshDate
        FeedRefreshState.persistLastSuccessfulRefreshDate(refreshDate)
        pushSnapshotToWatch()
        refreshBookmarkedLinks()
        
        completeInitialFeedLoad(minimumVisibleDuration: launchScreenMinimumVisibleDuration)
    }
    
    func fetchFeed(_ feed: FeedSource) async -> FeedFetchStatus {
        await feedClient.fetch(feed: feed)
    }
    
    private func persistEntriesCache() {
        guard let data = try? Self.cacheEncoder.encode(entries) else { return }

        FeedCacheSync.write(data, for: FeedStorage.Keys.cachedEntries)
        cachedEntriesData = data
    }

    private func scheduleOfflinePreload(for entries: [FeedEntry]) {
        guard !entries.isEmpty, !networkState.isOffline else { return }
        let snapshot = entries
        Task.detached(priority: .utility) {
            await OfflineArticleArchive.preloader.preload(entries: snapshot)
        }
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
            
            // If cached content is restored, hide the launch screen promptly with a tiny minimum
            if showLaunchScreen {
                completeInitialFeedLoad(minimumVisibleDuration: launchScreenMinimumVisibleDuration)
            }
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

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bookmarks:
                return "Lesezeichen"
            case .unread:
                return "Ungelesen"
            case .today:
                return "Heute"
            }
        }

        var iconName: String {
            switch self {
            case .bookmarks:
                return "bookmark"
            case .unread:
                return "eye"
            case .today:
                return "calendar"
            }
        }
    }

    private enum WidgetSelectionContextStore {
        static let selectedFeedIDsKey = "nf_widget_selected_feed_ids_v1"
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
            // Keep recently-read items in unread flow until next refresh promotion.
            return !entry.isRead || recentlyReadLinks.contains(entry.link)
        case .today:
            let publishedDate = entry.parsedPubDate ?? .distantPast
            return publishedDate != .distantPast && Calendar.current.isDateInToday(publishedDate)
        case .none:
            return true
        }
    }

    private func normalizeSelectedFeedIDs(using availableFeeds: [FeedSource]? = nil) {
        let availableFeeds = availableFeeds ?? feeds
        let orderedIDs = availableFeeds.map(\.id)
        let availableIDs = Set(orderedIDs)

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

        let currentSelection = selectedFeedIDs.intersection(availableIDs)
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
    
    private var activeQuickFilter: QuickFilterKind? {
        if showOnlyBookmarks { return .bookmarks }
        if showUnreadOnly { return .unread }
        if showTodayOnly { return .today }
        return nil
    }

    private var filterToolbarIconMode: FilterToolbarAnimatedIcon.Mode {
        switch activeQuickFilter {
        case .bookmarks:
            return .bookmarks
        case .unread:
            return .unread
        case .today:
            return .today
        case .none:
            return .none
        }
    }

    private func triggerLightHaptic() {
#if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
#endif
    }

    private func clearAndDismissSearch() {
        searchText = ""
        withAnimation(UIStylePolicy.Motion.standardEase) {}
        isSearchBarExpanded = false
        isToolbarSearchFocused = false
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
                ControlGroup {
                    quickFilterMenuButton(title: "Heute", iconName: "calendar", selection: .today)
                    quickFilterMenuButton(title: "Ungelesen", iconName: "eye", selection: .unread)
                    quickFilterMenuButton(title: "Bookmark", iconName: "bookmark", selection: .bookmarks)
                }
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
        showOnlyBookmarks = filter == .bookmarks
        showUnreadOnly = filter == .unread
        showTodayOnly = filter == .today
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
            entries[index].isRead = true
            entries[index].isNew = false
            store.markRecentlyRead(articleID: entry.link)
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
        }
    }

    @ViewBuilder
    private func animatedIcon(for mode: Mode) -> some View {
        switch mode {
        case .none:
            FilterSequentialLinesIcon()
        case .unread:
            FilterBlinkingEyeIcon()
        case .today:
            FilterCalendarJumpingDotsIcon()
        case .bookmarks:
            FilterBookmarkFillIcon()
        }
    }
}

private struct FilterBlinkingEyeIcon: View {
    @State private var isClosed = false
    @State private var didStart = false

    var body: some View {
        ZStack {
            Image(systemName: "eye")
                .opacity(isClosed ? 0 : 1)
            Image(systemName: "eye.slash")
                .opacity(isClosed ? 1 : 0)
        }
        .scaleEffect(y: isClosed ? 0.94 : 1.0)
        .onAppear {
            guard !didStart else { return }
            didStart = true

            withAnimation(.easeInOut(duration: 0.20)) {
                isClosed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                withAnimation(.easeInOut(duration: 0.24)) {
                    isClosed = false
                }
            }
        }
    }
}

private struct FilterCalendarJumpingDotsIcon: View {
    @State private var dotOffsets: [CGFloat] = [1.3, 1.3, 1.3]
    @State private var didStart = false

    var body: some View {
        ZStack {
            Image(systemName: "calendar")
            HStack(spacing: 2.1) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 2.8, height: 2.8)
                        .offset(y: dotOffsets[index])
                }
            }
            .offset(y: 3.5)
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true

            for index in 0..<3 {
                let startDelay = Double(index) * 0.08
                DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        dotOffsets[index] = -1.3
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + startDelay + 0.16) {
                    withAnimation(.easeIn(duration: 0.14)) {
                        dotOffsets[index] = 1.3
                    }
                }
            }
        }
    }
}

private struct FilterBookmarkFillIcon: View {
    @State private var fillProgress: CGFloat = 0.0
    @State private var didStart = false

    var body: some View {
        ZStack {
            Image(systemName: "bookmark")
            Image(systemName: "bookmark.fill")
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

private struct FilterSequentialLinesIcon: View {
    @State private var offsetY: CGFloat = 4.0
    @State private var opacity: Double = 0.0
    @State private var didStart = false

    var body: some View {
        Image(systemName: "line.3.horizontal.decrease")
            .offset(y: offsetY)
            .opacity(opacity)
        .onAppear {
            guard !didStart else { return }
            didStart = true

            withAnimation(.easeOut(duration: 0.20)) {
                opacity = 1.0
            }
            withAnimation(.spring(response: 0.44, dampingFraction: 0.82)) {
                offsetY = 0.0
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

struct FeedsSettingsViewPlaceholder: View {
    @AppStorage("savedFeeds", store: FeedStorage.defaults) private var savedFeedsData: Data = Data()
    @State private var feeds: [FeedSource] = []
    @State private var showAddFeedSheet: Bool = false
    
    @State private var selectedFeed: FeedSource? = nil
    @State private var selectedIndex: Int? = nil
    
    @EnvironmentObject private var theme: ThemeSettings
    
    var body: some View {
        List {
            Section("Gespeicherte Feeds") {
                if feeds.isEmpty {
                    HStack(spacing: 12) {
                        SettingsListIconBadge(systemName: "tray", tint: theme.uiAccentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Noch keine Feeds hinzugefügt")
                                .appTitle()
                                .foregroundStyle(.primary)
                            Text("Füge deinen ersten RSS-Feed hinzu, damit Artikel in der Übersicht erscheinen.")
                                .appMeta()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ForEach(feeds, id: \.url) { feed in
                        Button {
                            if let idx = feeds.firstIndex(where: { $0.url == feed.url }) {
                                selectedIndex = idx
                                selectedFeed = feed
                            }
                        } label: {
                            HStack(spacing: 12) {
                                CachedFeedFaviconView(feedURLString: feed.url)
                                    .frame(width: 38, height: 38)
                                    .clipShape(Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feed.title)
                                        .appTitle()
                                        .foregroundStyle(.primary)
                                    Text(feed.url)
                                        .appMeta()
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                if let idx = feeds.firstIndex(where: { $0.url == feed.url }) {
                                    selectedIndex = idx
                                    selectedFeed = feed
                                }
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
                    showAddFeedSheet = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsListIconBadge(systemName: "plus", tint: theme.uiAccentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Feed hinzufügen")
                                .appTitle()
                                .foregroundStyle(.primary)
                            Text("Neuen RSS-Feed mit eigener Farbe anlegen.")
                                .appMeta()
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
                feeds.append(item)
                persistFeeds()
            }
            .environmentObject(theme)
            .presentationDetents([.fraction(0.6)])
            .presentationBackground(.clear)
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
            .presentationDetents([.fraction(0.6)])
            .interactiveDismissDisabled(false)
            .presentationBackground(.clear)
        }
        .onAppear { restoreFeeds() }
        .onChange(of: savedFeedsData) { _, _ in
            // Keep in sync with external changes (e.g., onboarding added a feed)
            restoreFeeds()
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var title: String = ""
    @State private var urlString: String = ""
    @State private var selectedColor: Color = FeedColorOption.defaultPalette.first?.color ?? Color(red: 0.78, green: 0.88, blue: 0.97)
    @State private var selectedOption: FeedColorOption? = FeedColorOption.defaultPalette.first
    let onAdd: (FeedSource?) -> Void
    
    var body: some View {
        NavigationStack {
            SettingsScaffold {
                SettingsSectionCard(title: "Details") {
                    editorField(title: "Name", text: $title, keyboardType: .default, autocapitalization: .words)
                    editorField(title: "Feed URL", text: $urlString, keyboardType: .URL, autocapitalization: .never)
                }

                SettingsSectionCard(title: "Farbe") {
                    colorPalette
                }
            }
            .navigationTitle("Feed hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .tint(theme.uiAccentColor)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() }label:{Image(systemName: "xmark").fontWeight(.light)}
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
                    }label:{Image(systemName: "checkmark").fontWeight(.light)}
                        .disabled(FeedDraft(title: title, url: urlString).trimmedURL.isEmpty)
                }
            }
        }
    }

    private var colorPalette: some View {
        let options = FeedColorOption.defaultPalette

        return HStack(spacing: 12) {
            Spacer(minLength: 0)

            ForEach(options) { option in
                ZStack {
                    Circle()
                        .fill(option.color)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if selectedOption == option {
                                Circle().stroke(theme.uiAccentColor, lineWidth: 3)
                            }
                        }

                    if selectedOption == option {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .fontWeight(.light)
                            .foregroundStyle(.black.opacity(0.7))
                    }
                }
                .contentShape(Circle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedOption = option
                        selectedColor = option.color
                    }
                }
                .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func editorField(
        title: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType,
        autocapitalization: TextInputAutocapitalization
    ) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(autocapitalization)
            .keyboardType(keyboardType)
            .autocorrectionDisabled(true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07), lineWidth: 1)
            }
    }
}


struct EditSingleFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeSettings
    @Environment(\.colorScheme) private var colorScheme
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
            SettingsScaffold {
                SettingsSectionCard(title: "Details") {
                    editorField(title: "Name", text: $title, keyboardType: .default, autocapitalization: .words)
                    editorField(title: "Feed URL", text: $urlString, keyboardType: .URL, autocapitalization: .never)
                }

                SettingsSectionCard(title: "Farbe") {
                    colorPalette
                }
            }
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
                    Button { dismiss() } label: { Image(systemName: "xmark").fontWeight(.light) }
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
                    } label: { Image(systemName: "checkmark").fontWeight(.light) }
                        .disabled(FeedDraft(title: title, url: urlString).trimmedURL.isEmpty)
                }
            }
        }
    }

    private var colorPalette: some View {
        let options = FeedColorOption.defaultPalette

        return HStack(spacing: 12) {
            ForEach(options) { option in
                ZStack {
                    Circle()
                        .fill(option.color)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if selectedOption == option {
                                Circle().stroke(theme.uiAccentColor, lineWidth: 3)
                            }
                        }

                    if selectedOption == option {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .fontWeight(.light)
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
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func editorField(
        title: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType,
        autocapitalization: TextInputAutocapitalization
    ) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(autocapitalization)
            .keyboardType(keyboardType)
            .autocorrectionDisabled(true)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.035))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07), lineWidth: 1)
            }
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
                                .appTitle()
                                .foregroundStyle(.primary)
                            Text("Nutzen die Feed-Farbe als deutlichere Kartenfläche.")
                                .appMeta()
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
                    .appMeta()
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
                .appSecondary()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value)
                .appTitle()
                .foregroundStyle(.primary)
        }
    }

    private func infoLinkRow(label: String, title: String, destination: URL) -> some View {
        HStack {
            Text(label)
                .appSecondary()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Link(title, destination: destination)
                .appTitle()
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
