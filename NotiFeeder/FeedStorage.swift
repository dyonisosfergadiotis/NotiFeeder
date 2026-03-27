import Foundation

enum FeedStorage {
    enum Keys {
        static let savedFeeds = "savedFeeds"
        static let cachedEntries = "cachedEntries"
        static let feedColorMap = "feedColorMap"
        static let savedArticles = "savedArticles"
        static let readArticleIDs = "readArticleIDs"
        static let bookmarkedArticleIDs = "bookmarkedArticleIDs"
        static let profileDisplayName = "profile.displayName"
        static let uiCardsPreviewLines = "ui.cards.previewLines"
        static let uiCardsStyleFullColor = "ui.cards.style.fullColor"
        static let readerFontScale = "readerFontScale"
        static let readerFontFamily = "readerFontFamily"
        static let readerLineSpacing = "readerLineSpacing"
        static let readerTextAlignment = "readerTextAlignment"
    }

    static let suiteName = "group.notiFeeder"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func migrateIfNeeded() {
        let groupDefaults = defaults
        let standard = UserDefaults.standard

        let keysToMigrate = [
            Keys.savedFeeds,
            Keys.cachedEntries,
            Keys.feedColorMap,
            Keys.savedArticles,
            Keys.readArticleIDs,
            Keys.bookmarkedArticleIDs,
            Keys.profileDisplayName,
            Keys.uiCardsPreviewLines,
            Keys.uiCardsStyleFullColor,
            Keys.readerFontScale,
            Keys.readerFontFamily,
            Keys.readerLineSpacing,
            Keys.readerTextAlignment
        ]

        for key in keysToMigrate {
            let hasGroupValue = groupDefaults.object(forKey: key) != nil
            let hasStandardValue = standard.object(forKey: key) != nil
            guard !hasGroupValue, hasStandardValue else { continue }
            groupDefaults.set(standard.object(forKey: key), forKey: key)
        }
    }
}

enum FeedCacheSync {
    static let syncTokenSuffix = ".syncToken"

    static func syncTokenKey(for key: String) -> String {
        "\(key)\(syncTokenSuffix)"
    }

    @discardableResult
    static func write(_ data: Data, for key: String, token: Double? = nil) -> Double {
        let timestamp = token ?? Date().timeIntervalSince1970
        let groupDefaults = FeedStorage.defaults
        let standardDefaults = UserDefaults.standard

        groupDefaults.set(data, forKey: key)
        standardDefaults.set(data, forKey: key)

        groupDefaults.set(timestamp, forKey: syncTokenKey(for: key))
        standardDefaults.set(timestamp, forKey: syncTokenKey(for: key))
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

        let groupData = groupDefaults.data(forKey: key)
        let standardData = standardDefaults.data(forKey: key)
        let groupToken = groupDefaults.double(forKey: syncTokenKey(for: key))
        let standardToken = standardDefaults.double(forKey: syncTokenKey(for: key))

        switch (groupData, standardData) {
        case (nil, nil):
            return nil
        case (let g?, nil):
            return g
        case (nil, let s?):
            return s
        case (let g?, let s?):
            return groupToken >= standardToken ? g : s
        }
    }

    static func syncIfNeeded(for key: String) {
        guard let best = bestAvailableData(for: key) else { return }
        write(best, for: key)
    }
}
