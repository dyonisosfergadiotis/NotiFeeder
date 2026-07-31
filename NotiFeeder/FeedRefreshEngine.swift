import Foundation
import BackgroundTasks
import OSLog

#if canImport(WidgetKit)
import WidgetKit
#endif

extension Notification.Name {
    static let feedCachedEntriesDidRefresh = Notification.Name("feedCachedEntriesDidRefresh")
}

#if canImport(WidgetKit)
private enum FeedWidgetReloader {
    // Keep in sync with `NotiFeeder_Widget_LockScreenRectangular.kind`.
    static let lockScreenRectangularKind = "NotiFeeder_Widget_LockScreenRectangular"

    static func reloadAfterFeedUpdate() {
        let center = WidgetCenter.shared
        center.reloadTimelines(ofKind: lockScreenRectangularKind)
        center.reloadAllTimelines()
    }
}
#endif

enum FeedRefreshTrigger: String, Sendable {
    case appForeground
    case backgroundTask
    case appIntent
    case manual
}

nonisolated enum FeedRefreshCadence {
    static let backgroundMinimumInterval: TimeInterval = 20 * 60
    static let foregroundMinimumAge: TimeInterval = 10 * 60
}

struct FeedRefreshResult: Sendable {
    let trigger: FeedRefreshTrigger
    let totalFeeds: Int
    let successfulFeeds: Int
    let fetchedEntries: Int
    let cachedEntries: Int
    let didWriteCache: Bool
    let wasCancelled: Bool

    var isSuccess: Bool {
        guard !wasCancelled else { return false }
        if totalFeeds == 0 { return true }
        return successfulFeeds > 0 || didWriteCache || cachedEntries > 0
    }
}

@MainActor
enum FeedRefreshState {
    static func lastSuccessfulRefreshDate() -> Date? {
        let key = FeedStorage.Keys.lastSuccessfulFeedRefresh
        let groupValue = FeedStorage.defaults.double(forKey: key)
        let standardValue = UserDefaults.standard.double(forKey: key)
        let timestamp = max(groupValue, standardValue)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func persistLastSuccessfulRefreshDate(_ date: Date) {
        let key = FeedStorage.Keys.lastSuccessfulFeedRefresh
        let timestamp = date.timeIntervalSince1970
        FeedStorage.defaults.set(timestamp, forKey: key)
        UserDefaults.standard.set(timestamp, forKey: key)
    }
}

@MainActor
final class FeedRefreshEngine {
    static let shared = FeedRefreshEngine()

    private let feedClient = FeedNetworkClient(maxRetries: 1, timeout: 8)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maxCachedEntries = 1500

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func refreshAllFeeds(trigger: FeedRefreshTrigger = .manual) async -> FeedRefreshResult {
        let feeds = loadSavedFeeds()
        guard !feeds.isEmpty else {
            return FeedRefreshResult(
                trigger: trigger,
                totalFeeds: 0,
                successfulFeeds: 0,
                fetchedEntries: 0,
                cachedEntries: loadCachedEntries().count,
                didWriteCache: false,
                wasCancelled: false
            )
        }

        var fetchedEntries: [FeedEntry] = []
        var feedStatuses: [(FeedSource, FeedFetchStatus)] = []
        var successfulFeeds = 0

        await withTaskGroup(of: (FeedSource, FeedFetchStatus).self) { group in
            for feed in feeds {
                group.addTask { [feedClient] in
                    let status = await feedClient.fetch(feed: feed)
                    return (feed, status)
                }
            }

            for await (feed, status) in group {
                feedStatuses.append((feed, status))
                if status.error == nil {
                    successfulFeeds += 1
                }

                let normalizedEntries = status.entries.map { entry -> FeedEntry in
                    var normalized = entry
                    if normalized.sourceTitle == nil {
                        normalized.sourceTitle = feed.title
                    }
                    if normalized.feedURL == nil {
                        normalized.feedURL = feed.url
                    }
                    return normalized
                }
                fetchedEntries.append(contentsOf: normalizedEntries)
            }
        }

        if Task.isCancelled {
            return FeedRefreshResult(
                trigger: trigger,
                totalFeeds: feeds.count,
                successfulFeeds: successfulFeeds,
                fetchedEntries: fetchedEntries.count,
                cachedEntries: loadCachedEntries().count,
                didWriteCache: false,
                wasCancelled: true
            )
        }

        let readIDs = loadReadArticleIDs()
        let bookmarkedLinks = loadBookmarkedArticleIDs()
        let mergedEntries = mergeEntries(
            cachedEntries: loadCachedEntries(),
            freshEntries: fetchedEntries,
            readIDs: readIDs,
            activeFeedURLs: Set(feeds.map(\.url))
        )
        let didWriteCache = persistCachedEntriesIfChanged(mergedEntries)
        let refreshDate = Date()
        let articleCounts = articleCountsByFeedURL(in: mergedEntries)
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

        if !mergedEntries.isEmpty {
            let preloadEntries = OfflineArticleRetentionPolicy.retainedEntries(
                from: mergedEntries,
                readIDs: readIDs,
                bookmarkedLinks: bookmarkedLinks
            )
            Task.detached(priority: .utility) {
                await OfflineArticleArchive.preloader.preload(entries: preloadEntries)
            }
        }

        if successfulFeeds > 0 {
            FeedRefreshState.persistLastSuccessfulRefreshDate(refreshDate)
        }

        if didWriteCache || successfulFeeds > 0 {
            NotificationCenter.default.post(name: .feedCachedEntriesDidRefresh, object: nil)
            PhoneWatchSyncManager.shared.pushSnapshot(
                feeds: feeds,
                entries: mergedEntries,
                readIDs: readIDs,
                bookmarkedLinks: bookmarkedLinks,
                lastRefreshDate: FeedRefreshState.lastSuccessfulRefreshDate()
            )
#if canImport(WidgetKit)
            FeedWidgetReloader.reloadAfterFeedUpdate()
#endif
        }

        return FeedRefreshResult(
            trigger: trigger,
            totalFeeds: feeds.count,
            successfulFeeds: successfulFeeds,
            fetchedEntries: fetchedEntries.count,
            cachedEntries: mergedEntries.count,
            didWriteCache: didWriteCache,
            wasCancelled: false
        )
    }

    private func loadSavedFeeds() -> [FeedSource] {
        let key = FeedStorage.Keys.savedFeeds
        guard let data = FeedCacheSync.bestAvailableData(for: key) ?? FeedStorage.defaults.data(forKey: key),
              let feeds = try? decoder.decode([FeedSource].self, from: data) else {
            return []
        }
        return feeds
    }

    private func loadReadArticleIDs() -> Set<String> {
        let key = FeedStorage.Keys.readArticleIDs
        guard let data = FeedCacheSync.bestAvailableData(for: key) ?? FeedStorage.defaults.data(forKey: key),
              let ids = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    private func loadBookmarkedArticleIDs() -> Set<String> {
        let key = FeedStorage.Keys.bookmarkedArticleIDs
        guard let data = FeedCacheSync.bestAvailableData(for: key) ?? FeedStorage.defaults.data(forKey: key),
              let ids = try? decoder.decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    private func loadCachedEntries() -> [FeedEntry] {
        let key = FeedStorage.Keys.cachedEntries
        guard let data = FeedCacheSync.bestAvailableData(for: key) ?? FeedStorage.defaults.data(forKey: key),
              let cached = try? decoder.decode([FeedEntry].self, from: data) else {
            return []
        }
        return cached
    }

    private func mergeEntries(
        cachedEntries: [FeedEntry],
        freshEntries: [FeedEntry],
        readIDs: Set<String>,
        activeFeedURLs: Set<String>
    ) -> [FeedEntry] {
        var merged: [FeedEntry] = []
        merged.reserveCapacity(max(cachedEntries.count, freshEntries.count))

        var indexByLink: [String: Int] = [:]
        indexByLink.reserveCapacity(max(cachedEntries.count, freshEntries.count))

        for var entry in cachedEntries {
            if let feedURL = entry.feedURL, !activeFeedURLs.contains(feedURL) {
                continue
            }
            guard indexByLink[entry.link] == nil else { continue }
            entry.isRead = readIDs.contains(entry.link)
            if entry.isRead {
                entry.isNew = false
            }
            indexByLink[entry.link] = merged.count
            merged.append(entry)
        }

        for var fresh in freshEntries {
            fresh.isRead = readIDs.contains(fresh.link)
            fresh.isNew = fresh.isRead ? false : true

            if let existingIndex = indexByLink[fresh.link] {
                var existing = merged[existingIndex]
                existing.title = fresh.title
                existing.shortTitle = fresh.shortTitle
                existing.content = fresh.content
                existing.contentRaw = fresh.contentRaw
                existing.imageURL = fresh.imageURL
                existing.author = fresh.author
                existing.pubDateString = fresh.pubDateString
                existing.feedURL = fresh.feedURL ?? existing.feedURL
                existing.sourceTitle = fresh.sourceTitle ?? existing.sourceTitle
                existing.isRead = readIDs.contains(existing.link)
                if existing.isRead {
                    existing.isNew = false
                }
                merged[existingIndex] = existing
            } else {
                indexByLink[fresh.link] = merged.count
                merged.append(fresh)
            }
        }

        merged.sort { lhs, rhs in
            let lhsDate = DateParser.parse(lhs.pubDateString)
            let rhsDate = DateParser.parse(rhs.pubDateString)
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        if merged.count > maxCachedEntries {
            merged = Array(merged.prefix(maxCachedEntries))
        }

        return merged
    }

    private func persistCachedEntriesIfChanged(_ entries: [FeedEntry]) -> Bool {
        guard let data = try? encoder.encode(entries) else { return false }
        let key = FeedStorage.Keys.cachedEntries
        let current = FeedCacheSync.bestAvailableData(for: key)
        guard current != data else { return false }
        let token = FeedCacheSync.write(data, for: key)
        FeedCloudKitSyncManager.shared.uploadLocalData(data, token: token, for: key)
        return true
    }

    private func articleCountsByFeedURL(in entries: [FeedEntry]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries {
            guard let feedURL = entry.feedURL, !feedURL.isEmpty else { continue }
            counts[feedURL, default: 0] += 1
        }
        return counts
    }
}

enum FeedBackgroundRefreshManager {
    static let taskIdentifier = "de.DyonisosFergadiotis.NotiFeeder.feedRefresh"

    private static var didRegister = false
    private static let minimumInterval: TimeInterval = FeedRefreshCadence.backgroundMinimumInterval

    static func registerIfNeeded() {
        guard !didRegister else { return }
        didRegister = true

        let registrationSucceeded = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: refreshTask)
        }

        if !registrationSucceeded {
            AppLogger.app.error("BGTask registration failed for identifier \(taskIdentifier, privacy: .public)")
        }
    }

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.app.error("BGTask schedule failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func performBackgroundFetch() async -> FeedRefreshResult {
        await FeedRefreshEngine.shared.refreshAllFeeds(trigger: .backgroundTask)
    }

    private static func handle(task: BGAppRefreshTask) {
        scheduleNext()

        let refreshTask = Task(priority: .background) {
            let result = await FeedRefreshEngine.shared.refreshAllFeeds(trigger: .backgroundTask)
            task.setTaskCompleted(success: result.isSuccess)
        }

        task.expirationHandler = {
            refreshTask.cancel()
        }
    }
}
