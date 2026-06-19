import Foundation

nonisolated enum AppGroupDefaults {
    static let suiteName = "group.notiFeeder"

    static func defaults(suiteName: String = AppGroupDefaults.suiteName, fallback: UserDefaults = .standard) -> UserDefaults {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) != nil else {
            return fallback
        }
        return UserDefaults(suiteName: suiteName) ?? fallback
    }
}

nonisolated enum AppGroupBlobStore {
    private static let directoryName = "LargePreferenceValues"
    private static let fileExtension = "data"

    static func data(forKey key: String, suiteName: String = AppGroupDefaults.suiteName) -> Data? {
        guard let url = fileURL(forKey: key, suiteName: suiteName) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func write(_ data: Data, forKey key: String, suiteName: String = AppGroupDefaults.suiteName) {
        guard let url = fileURL(forKey: key, suiteName: suiteName) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            assertionFailure("Failed to write blob for \(key): \(error)")
        }
    }

    static func remove(forKey key: String, suiteName: String = AppGroupDefaults.suiteName) {
        guard let url = fileURL(forKey: key, suiteName: suiteName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileURL(forKey key: String, suiteName: String) -> URL? {
        guard let directory = storageDirectory(suiteName: suiteName) else { return nil }
        return directory
            .appendingPathComponent(fileName(forKey: key), isDirectory: false)
            .appendingPathExtension(fileExtension)
    }

    private static func storageDirectory(suiteName: String) -> URL? {
        let fileManager = FileManager.default
        if let appGroupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: suiteName) {
            return appGroupURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        }

        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func fileName(forKey key: String) -> String {
        key.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        .map(String.init)
        .joined()
    }
}
