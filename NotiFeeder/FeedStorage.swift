import Foundation

nonisolated enum FeedStorage {
    enum Keys {
        static let savedFeeds = "savedFeeds"
        static let savedFeedsDeletedURLs = "savedFeeds.deletedURLs"
        static let cachedEntries = "cachedEntries"
        static let feedColorMap = "feedColorMap"
        static let savedArticles = "savedArticles"
        static let articleSummaries = "articleSummaries"
        static let readArticleIDs = "readArticleIDs"
        static let bookmarkedArticleIDs = "bookmarkedArticleIDs"
        static let lastSuccessfulFeedRefresh = "feed.lastSuccessfulRefreshAt"
        static let feedHealthSnapshots = "feed.health.snapshots.v1"
        static let offlineRetainedFetchedArticleLimit = "offline.retainedFetchedArticleLimit"
        static let profileDisplayName = "profile.displayName"
        static let profileAvatarImageData = "profile.avatarImageData"
        static let uiCardsStyleFullColor = "ui.cards.style.fullColor"
        static let readerFontScale = "readerFontScale"
        static let readerFontFamily = "readerFontFamily"
        static let readerLineSpacing = "readerLineSpacing"
        static let readerTextAlignment = "readerTextAlignment"
        static let readerParagraphSpacing = "readerParagraphSpacing"
        static let readerContentWidth = "readerContentWidth"
        static let widgetSelectedFeedIDs = "nf_widget_selected_feed_ids_v1"
    }

    static let suiteName = AppGroupDefaults.suiteName

    static var defaults: UserDefaults {
        AppGroupDefaults.defaults(suiteName: suiteName, fallback: .standard)
    }

    static func migrateIfNeeded() {
        FeedCacheSync.migrateLargeDefaultsToBlobStore()

        let groupDefaults = defaults
        let standard = UserDefaults.standard

        let keysToMigrate = [
            Keys.savedFeeds,
            Keys.savedFeedsDeletedURLs,
            Keys.cachedEntries,
            Keys.feedColorMap,
            Keys.savedArticles,
            Keys.articleSummaries,
            Keys.readArticleIDs,
            Keys.bookmarkedArticleIDs,
            Keys.lastSuccessfulFeedRefresh,
            Keys.feedHealthSnapshots,
            Keys.offlineRetainedFetchedArticleLimit,
            Keys.profileDisplayName,
            Keys.profileAvatarImageData,
            Keys.uiCardsStyleFullColor,
            Keys.readerFontScale,
            Keys.readerFontFamily,
            Keys.readerLineSpacing,
            Keys.readerTextAlignment,
            Keys.readerParagraphSpacing,
            Keys.readerContentWidth,
            Keys.widgetSelectedFeedIDs
        ]

        for key in keysToMigrate {
            let hasGroupValue = groupDefaults.object(forKey: key) != nil
            let hasStandardValue = standard.object(forKey: key) != nil
            guard !hasGroupValue, hasStandardValue else { continue }
            groupDefaults.set(standard.object(forKey: key), forKey: key)
        }
    }

    static func deletedFeedURLs() -> Set<String> {
        let groupData = defaults.data(forKey: Keys.savedFeedsDeletedURLs)
        let standardData = UserDefaults.standard.data(forKey: Keys.savedFeedsDeletedURLs)
        var urls: Set<String> = []

        if let groupData,
           let decoded = try? JSONDecoder().decode([String].self, from: groupData) {
            urls.formUnion(decoded)
        }

        if let standardData,
           let decoded = try? JSONDecoder().decode([String].self, from: standardData) {
            urls.formUnion(decoded)
        }

        return urls
    }

    static func rememberDeletedFeedURLs(_ urls: [String]) {
        let normalizedURLs = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedURLs.isEmpty else { return }

        var current = deletedFeedURLs()
        current.formUnion(normalizedURLs)
        writeDeletedFeedURLs(current)
    }

    static func forgetDeletedFeedURL(_ url: String) {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return }

        var current = deletedFeedURLs()
        guard current.remove(normalizedURL) != nil else { return }
        writeDeletedFeedURLs(current)
    }

    private static func writeDeletedFeedURLs(_ urls: Set<String>) {
        guard let data = try? JSONEncoder().encode(Array(urls).sorted()) else { return }
        defaults.set(data, forKey: Keys.savedFeedsDeletedURLs)
        UserDefaults.standard.set(data, forKey: Keys.savedFeedsDeletedURLs)
        defaults.synchronize()
        UserDefaults.standard.synchronize()
    }

    static func includeFeedInWidgetSelection(_ feedURL: String) {
        let normalizedURL = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return }

        var selectedIDs = widgetSelectedFeedIDs()
        guard selectedIDs.insert(normalizedURL).inserted else { return }
        writeWidgetSelectedFeedIDs(selectedIDs)
    }

    private static func widgetSelectedFeedIDs() -> Set<String> {
        let groupData = defaults.data(forKey: Keys.widgetSelectedFeedIDs)
        let standardData = UserDefaults.standard.data(forKey: Keys.widgetSelectedFeedIDs)
        var selectedIDs: Set<String> = []

        if let groupData,
           let decoded = try? JSONDecoder().decode([String].self, from: groupData) {
            selectedIDs.formUnion(decoded)
        }

        if let standardData,
           let decoded = try? JSONDecoder().decode([String].self, from: standardData) {
            selectedIDs.formUnion(decoded)
        }

        return selectedIDs
    }

    private static func writeWidgetSelectedFeedIDs(_ selectedIDs: Set<String>) {
        guard let data = try? JSONEncoder().encode(Array(selectedIDs).sorted()) else { return }
        defaults.set(data, forKey: Keys.widgetSelectedFeedIDs)
        UserDefaults.standard.set(data, forKey: Keys.widgetSelectedFeedIDs)
        defaults.synchronize()
        UserDefaults.standard.synchronize()
    }
}

nonisolated enum FeedCacheSync {
    static let syncTokenSuffix = ".syncToken"
    private static let blobStorageThreshold = 512 * 1024
    private static let blobBackedKeys: Set<String> = [
        FeedStorage.Keys.cachedEntries,
        FeedStorage.Keys.savedArticles,
        FeedStorage.Keys.articleSummaries,
        FeedStorage.Keys.readArticleIDs,
        FeedStorage.Keys.bookmarkedArticleIDs,
        "recentlyReadArticleIDs",
        "nf_widget_bg_latest"
    ]

    static func syncTokenKey(for key: String) -> String {
        "\(key)\(syncTokenSuffix)"
    }

    @discardableResult
    static func write(_ data: Data, for key: String, token: Double? = nil) -> Double {
        let timestamp = token ?? Date().timeIntervalSince1970
        let groupDefaults = FeedStorage.defaults
        let standardDefaults = UserDefaults.standard

        if shouldUseBlobStorage(for: key, data: data) {
            AppGroupBlobStore.write(data, forKey: key)
            groupDefaults.removeObject(forKey: key)
            standardDefaults.removeObject(forKey: key)
        } else {
            groupDefaults.set(data, forKey: key)
            standardDefaults.set(data, forKey: key)
            AppGroupBlobStore.remove(forKey: key)
        }

        groupDefaults.set(timestamp, forKey: syncTokenKey(for: key))
        standardDefaults.set(timestamp, forKey: syncTokenKey(for: key))
        groupDefaults.synchronize()
        standardDefaults.synchronize()
        return timestamp
    }

    static func bestAvailableToken(for key: String) -> Double {
        let groupToken = FeedStorage.defaults.double(forKey: syncTokenKey(for: key))
        let standardToken = UserDefaults.standard.double(forKey: syncTokenKey(for: key))
        return max(groupToken, standardToken)
    }

    static func bestAvailableData(for key: String) -> Data? {
        let groupDefaults = FeedStorage.defaults
        let standardDefaults = UserDefaults.standard

        let blobData = AppGroupBlobStore.data(forKey: key)
        let groupData = groupDefaults.data(forKey: key)
        let standardData = standardDefaults.data(forKey: key)
        let groupToken = groupDefaults.double(forKey: syncTokenKey(for: key))
        let standardToken = standardDefaults.double(forKey: syncTokenKey(for: key))

        switch (blobData, groupData, standardData) {
        case (let blob?, nil, nil):
            return blob
        case (nil, nil, nil):
            return nil
        case (let blob?, let g?, nil):
            return groupToken > 0 ? g : blob
        case (let blob?, nil, let s?):
            return standardToken > 0 ? s : blob
        case (let blob?, let g?, let s?):
            return groupToken >= standardToken ? g : (standardToken > 0 ? s : blob)
        case (nil, let g?, nil):
            return g
        case (nil, nil, let s?):
            return s
        case (nil, let g?, let s?):
            return groupToken >= standardToken ? g : s
        }
    }

    static func migrateLargeDefaultsToBlobStore() {
        let keys = Array(blobBackedKeys)
        for key in keys {
            migrateLargeDefaultValue(for: key)
        }
    }

    private static func migrateLargeDefaultValue(for key: String) {
        let groupDefaults = FeedStorage.defaults
        let standardDefaults = UserDefaults.standard
        let groupData = groupDefaults.data(forKey: key)
        let standardData = standardDefaults.data(forKey: key)

        guard groupData != nil || standardData != nil else { return }

        let selectedData: Data?
        switch (groupData, standardData) {
        case (let group?, let standard?):
            let groupToken = groupDefaults.double(forKey: syncTokenKey(for: key))
            let standardToken = standardDefaults.double(forKey: syncTokenKey(for: key))
            selectedData = groupToken >= standardToken ? group : standard
        case (let group?, nil):
            selectedData = group
        case (nil, let standard?):
            selectedData = standard
        case (nil, nil):
            selectedData = nil
        }

        guard let data = selectedData, shouldUseBlobStorage(for: key, data: data) else { return }
        AppGroupBlobStore.write(data, forKey: key)
        groupDefaults.removeObject(forKey: key)
        standardDefaults.removeObject(forKey: key)
    }

    private static func shouldUseBlobStorage(for key: String, data: Data) -> Bool {
        if key == FeedStorage.Keys.profileAvatarImageData {
            return false
        }
        return blobBackedKeys.contains(key) || data.count >= blobStorageThreshold
    }

    static func defaultsData(for key: String, defaults: UserDefaults) -> Data? {
        AppGroupBlobStore.data(forKey: key) ?? defaults.data(forKey: key)
    }

    private static func localData(for key: String, defaults: UserDefaults) -> Data? {
        AppGroupBlobStore.data(forKey: key) ?? defaults.data(forKey: key)
    }

    static func syncIfNeeded(for key: String) {
        let groupDefaults = FeedStorage.defaults
        let standardDefaults = UserDefaults.standard
        let tokenKey = syncTokenKey(for: key)

        let groupData = localData(for: key, defaults: groupDefaults)
        let standardData = localData(for: key, defaults: standardDefaults)
        let groupToken = groupDefaults.double(forKey: tokenKey)
        let standardToken = standardDefaults.double(forKey: tokenKey)

        guard let best = bestAvailableData(for: key) else { return }

        let bestToken = max(groupToken, standardToken)
        let storesAlreadyAligned = groupData == standardData && groupToken == standardToken
        guard !storesAlreadyAligned else { return }

        // Preserve existing sync token semantics; never stamp "now" during local reconciliation.
        _ = write(best, for: key, token: bestToken > 0 ? bestToken : 0)
    }
}
