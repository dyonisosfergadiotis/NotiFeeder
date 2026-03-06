import Foundation

extension Notification.Name {
    static let feedSavedFeedsDidSyncFromICloud = Notification.Name("feedSavedFeedsDidSyncFromICloud")
    static let feedCachedEntriesDidSyncFromICloud = Notification.Name("feedCachedEntriesDidSyncFromICloud")
    static let feedColorMapDidSyncFromICloud = Notification.Name("feedColorMapDidSyncFromICloud")
    static let feedSavedArticlesDidSyncFromICloud = Notification.Name("feedSavedArticlesDidSyncFromICloud")
    static let feedReadArticleIDsDidSyncFromICloud = Notification.Name("feedReadArticleIDsDidSyncFromICloud")
    static let feedBookmarkedArticleIDsDidSyncFromICloud = Notification.Name("feedBookmarkedArticleIDsDidSyncFromICloud")
}

@MainActor
final class FeedICloudSyncManager {
    static let shared = FeedICloudSyncManager()

    private let cloudStore: NSUbiquitousKeyValueStore
    private var didConfigure = false
    private var keysApplyingCloudChange: Set<String> = []
    private var appliedCloudPayloadsByKey: [String: Data] = [:]
    private var externalChangeObserver: NSObjectProtocol?

    private let syncKeys: [String]
    private let notificationByKey: [String: Notification.Name]

    init(cloudStore: NSUbiquitousKeyValueStore = .default) {
        self.cloudStore = cloudStore
        self.syncKeys = [
            FeedStorage.Keys.savedFeeds,
            FeedStorage.Keys.feedColorMap,
            FeedStorage.Keys.cachedEntries,
            FeedStorage.Keys.savedArticles,
            FeedStorage.Keys.readArticleIDs,
            FeedStorage.Keys.bookmarkedArticleIDs
        ]
        self.notificationByKey = [
            FeedStorage.Keys.savedFeeds: .feedSavedFeedsDidSyncFromICloud,
            FeedStorage.Keys.feedColorMap: .feedColorMapDidSyncFromICloud,
            FeedStorage.Keys.cachedEntries: .feedCachedEntriesDidSyncFromICloud,
            FeedStorage.Keys.savedArticles: .feedSavedArticlesDidSyncFromICloud,
            FeedStorage.Keys.readArticleIDs: .feedReadArticleIDsDidSyncFromICloud,
            FeedStorage.Keys.bookmarkedArticleIDs: .feedBookmarkedArticleIDsDidSyncFromICloud
        ]
    }

    deinit {
        if let externalChangeObserver {
            NotificationCenter.default.removeObserver(externalChangeObserver)
        }
    }

    func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true

        externalChangeObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.syncAllFromCloudIfNeeded(preferCloudOnTie: true)
            }
        }

        cloudStore.synchronize()
        syncAllFromCloudIfNeeded(preferCloudOnTie: false)
    }

    func syncAllFromCloudIfNeeded() {
        syncAllFromCloudIfNeeded(preferCloudOnTie: true)
    }

    func syncSavedFeedsFromCloudIfNeeded() {
        syncDataFromCloudIfNeeded(for: FeedStorage.Keys.savedFeeds)
    }

    func syncDataFromCloudIfNeeded(for key: String) {
        syncDataFromCloudIfNeeded(for: key, preferCloudOnTie: true)
    }

    func pushLocalSavedFeeds(_ data: Data) {
        pushLocalData(data, for: FeedStorage.Keys.savedFeeds)
    }

    func pushLocalData(_ data: Data, for key: String) {
        if appliedCloudPayloadsByKey[key] == data {
            appliedCloudPayloadsByKey.removeValue(forKey: key)
            return
        }
        guard !keysApplyingCloudChange.contains(key) else { return }

        let token = FeedCacheSync.write(data, for: key)
        let cloudData = cloudStore.data(forKey: key)
        let cloudToken = cloudStore.double(forKey: FeedCacheSync.syncTokenKey(for: key))

        guard cloudData != data || cloudToken < token else { return }
        pushToCloud(data: data, token: token, for: key)
    }

    private func syncAllFromCloudIfNeeded(preferCloudOnTie: Bool) {
        for key in syncKeys {
            syncDataFromCloudIfNeeded(for: key, preferCloudOnTie: preferCloudOnTie)
        }
    }

    private func syncDataFromCloudIfNeeded(for key: String, preferCloudOnTie: Bool) {
        let localData = FeedCacheSync.bestAvailableData(for: key)
        let localToken = FeedCacheSync.bestAvailableToken(for: key)
        let cloudData = cloudStore.data(forKey: key)
        let cloudToken = cloudStore.double(forKey: FeedCacheSync.syncTokenKey(for: key))

        switch (localData, cloudData) {
        case (nil, nil):
            return
        case (nil, let remote?):
            applyCloud(remote, token: cloudToken, for: key)
        case (let local?, nil):
            let token = localToken > 0 ? localToken : FeedCacheSync.write(local, for: key)
            pushToCloud(data: local, token: token, for: key)
        case (let local?, let remote?):
            if local == remote {
                let resolvedToken = max(localToken, cloudToken)
                if resolvedToken > 0 {
                    _ = FeedCacheSync.write(local, for: key, token: resolvedToken)
                    pushToCloud(data: local, token: resolvedToken, for: key)
                }
                return
            }

            let normalizedLocalToken = localToken > 0 ? localToken : 0
            let normalizedCloudToken = cloudToken > 0 ? cloudToken : 0

            if normalizedCloudToken > normalizedLocalToken {
                applyCloud(remote, token: normalizedCloudToken, for: key)
            } else if normalizedLocalToken > normalizedCloudToken {
                pushToCloud(data: local, token: normalizedLocalToken, for: key)
            } else if preferCloudOnTie {
                applyCloud(remote, token: normalizedCloudToken, for: key)
            } else {
                let newToken = FeedCacheSync.write(local, for: key)
                pushToCloud(data: local, token: newToken, for: key)
            }
        }
    }

    private func applyCloud(_ data: Data, token: Double, for key: String) {
        keysApplyingCloudChange.insert(key)
        defer { keysApplyingCloudChange.remove(key) }

        let resolvedToken = token > 0 ? token : Date().timeIntervalSince1970
        appliedCloudPayloadsByKey[key] = data
        _ = FeedCacheSync.write(data, for: key, token: resolvedToken)
        if let notification = notificationByKey[key] {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    private func pushToCloud(data: Data, token: Double, for key: String) {
        cloudStore.set(data, forKey: key)
        cloudStore.set(token, forKey: FeedCacheSync.syncTokenKey(for: key))
        cloudStore.synchronize()
    }
}
