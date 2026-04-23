import Foundation

enum AppGroupDefaults {
    static let suiteName = "group.notiFeeder"

    static func defaults(suiteName: String = AppGroupDefaults.suiteName, fallback: UserDefaults = .standard) -> UserDefaults {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil else {
            return fallback
        }
        return UserDefaults(suiteName: suiteName) ?? fallback
    }
}
