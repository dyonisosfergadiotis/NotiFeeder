import Foundation

enum FeedStorage {
    static let suiteName = "group.notiFeeder"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func migrateIfNeeded() {
        let groupDefaults = defaults
        let standard = UserDefaults.standard

        let hasGroupValue = groupDefaults.object(forKey: "savedFeeds") != nil
        let hasStandardValue = standard.object(forKey: "savedFeeds") != nil

        guard !hasGroupValue, hasStandardValue else { return }

        if let data = standard.data(forKey: "savedFeeds") {
            groupDefaults.set(data, forKey: "savedFeeds")
        }
    }
}
