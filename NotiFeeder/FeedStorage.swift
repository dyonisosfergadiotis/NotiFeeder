import Foundation

enum FeedStorage {
    enum Keys {
        static let savedFeeds = "savedFeeds"
        static let cachedEntries = "cachedEntries"
    }

    static let suiteName = "group.notiFeeder"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func migrateIfNeeded() {
        let groupDefaults = defaults
        let standard = UserDefaults.standard

        let hasGroupValue = groupDefaults.object(forKey: Keys.savedFeeds) != nil
        let hasStandardValue = standard.object(forKey: Keys.savedFeeds) != nil

        guard !hasGroupValue, hasStandardValue else { return }

        if let data = standard.data(forKey: Keys.savedFeeds) {
            groupDefaults.set(data, forKey: Keys.savedFeeds)
        }
    }
}

enum FeedCacheSync {
    private static let syncTokenSuffix = ".syncToken"

    private static func syncTokenKey(for key: String) -> String {
        "\(key)\(syncTokenSuffix)"
    }

    static func write(_ data: Data, for key: String) {
        let timestamp = Date().timeIntervalSince1970
        let groupDefaults = FeedStorage.defaults
        let standardDefaults = UserDefaults.standard

        groupDefaults.set(data, forKey: key)
        standardDefaults.set(data, forKey: key)

        groupDefaults.set(timestamp, forKey: syncTokenKey(for: key))
        standardDefaults.set(timestamp, forKey: syncTokenKey(for: key))
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
