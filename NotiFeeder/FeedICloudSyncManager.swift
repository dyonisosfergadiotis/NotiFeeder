import Foundation

extension Notification.Name {
    static let feedSavedFeedsDidSyncFromICloud = Notification.Name("feedSavedFeedsDidSyncFromICloud")
    static let feedColorMapDidSyncFromICloud = Notification.Name("feedColorMapDidSyncFromICloud")
    static let feedReadArticleIDsDidSyncFromICloud = Notification.Name("feedReadArticleIDsDidSyncFromICloud")
    static let feedBookmarkedArticleIDsDidSyncFromICloud = Notification.Name("feedBookmarkedArticleIDsDidSyncFromICloud")
    static let feedCardPreferencesDidSyncFromICloud = Notification.Name("feedCardPreferencesDidSyncFromICloud")
    static let feedProfileDidSyncFromICloud = Notification.Name("feedProfileDidSyncFromICloud")
    static let feedReaderPreferencesDidSyncFromICloud = Notification.Name("feedReaderPreferencesDidSyncFromICloud")
}

@MainActor
final class FeedICloudSyncManager {
    static let shared = FeedICloudSyncManager()

    private let cloudStore: NSUbiquitousKeyValueStore
    private var didConfigure = false
    private var keysApplyingCloudChange: Set<String> = []
    private var appliedCloudPayloadsByKey: [String: Data] = [:]
    private var preferenceKeysApplyingCloudChange: Set<String> = []
    private var externalChangeObserver: NSObjectProtocol?
    private var pendingCloudDataPushes: [String: PendingCloudDataPush] = [:]
    private var cloudDataPushTasks: [String: Task<Void, Never>] = [:]
    private var cloudSynchronizeTask: Task<Void, Never>?
    private var localMutationDatesByKey: [String: Date] = [:]

    private let syncKeys: [String]
    private let notificationByKey: [String: Notification.Name]
    private let syncedPreferences: [SyncedPreference]
    private let cloudPushDebounceNanoseconds: UInt64 = 250_000_000
    private let cloudSynchronizeDebounceNanoseconds: UInt64 = 500_000_000
    private let localMutationCloudApplyGraceInterval: TimeInterval = 4

    init(cloudStore: NSUbiquitousKeyValueStore = .default) {
        self.cloudStore = cloudStore
        self.syncKeys = [
            FeedStorage.Keys.savedFeeds,
            FeedStorage.Keys.feedColorMap
        ]
        self.notificationByKey = [
            FeedStorage.Keys.savedFeeds: .feedSavedFeedsDidSyncFromICloud,
            FeedStorage.Keys.feedColorMap: .feedColorMapDidSyncFromICloud,
            FeedStorage.Keys.readArticleIDs: .feedReadArticleIDsDidSyncFromICloud,
            FeedStorage.Keys.bookmarkedArticleIDs: .feedBookmarkedArticleIDsDidSyncFromICloud
        ]
        self.syncedPreferences = [
            SyncedPreference(
                key: FeedStorage.Keys.profileDisplayName,
                defaultValue: .string(""),
                notification: .feedProfileDidSyncFromICloud
            ),
            SyncedPreference(
                key: FeedStorage.Keys.uiCardsStyleFullColor,
                defaultValue: .bool(false),
                notification: .feedCardPreferencesDidSyncFromICloud
            ),
            SyncedPreference(
                key: FeedStorage.Keys.readerFontScale,
                defaultValue: .double(1.0),
                notification: .feedReaderPreferencesDidSyncFromICloud
            ),
            SyncedPreference(
                key: FeedStorage.Keys.readerFontFamily,
                defaultValue: .string("rounded"),
                notification: .feedReaderPreferencesDidSyncFromICloud
            ),
            SyncedPreference(
                key: FeedStorage.Keys.readerLineSpacing,
                defaultValue: .double(1.4),
                notification: .feedReaderPreferencesDidSyncFromICloud
            ),
            SyncedPreference(
                key: FeedStorage.Keys.readerTextAlignment,
                defaultValue: .string("left"),
                notification: .feedReaderPreferencesDidSyncFromICloud
            ),
            SyncedPreference(
                key: FeedStorage.Keys.readerParagraphSpacing,
                defaultValue: .double(0.72),
                notification: .feedReaderPreferencesDidSyncFromICloud
            ),
            SyncedPreference(
                key: FeedStorage.Keys.readerContentWidth,
                defaultValue: .double(720),
                notification: .feedReaderPreferencesDidSyncFromICloud
            ),
            SyncedPreference(
                key: FeedStorage.Keys.readerMediaWidth,
                defaultValue: .double(90),
                notification: .feedReaderPreferencesDidSyncFromICloud
            )
        ]
    }

    deinit {
        if let externalChangeObserver {
            NotificationCenter.default.removeObserver(externalChangeObserver)
        }
        for task in cloudDataPushTasks.values {
            task.cancel()
        }
        cloudSynchronizeTask?.cancel()
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

    func pushLocalPreferenceValue(_ value: Int, for key: String) {
        pushLocalPreferenceValue(.int(value), for: key)
    }

    func pushLocalPreferenceValue(_ value: Bool, for key: String) {
        pushLocalPreferenceValue(.bool(value), for: key)
    }

    func pushLocalPreferenceValue(_ value: Double, for key: String) {
        pushLocalPreferenceValue(.double(value), for: key)
    }

    func pushLocalPreferenceValue(_ value: String, for key: String) {
        pushLocalPreferenceValue(.string(value), for: key)
    }

    func pushLocalData(_ data: Data, for key: String) {
        let token = FeedCacheSync.write(data, for: key)
        pushLocalData(data, token: token, for: key)
    }

    func noteLocalMutation(for key: String) {
        localMutationDatesByKey[key] = Date()
    }

    func pushLocalData(_ data: Data, token: Double, for key: String) {
        if appliedCloudPayloadsByKey[key] == data {
            appliedCloudPayloadsByKey.removeValue(forKey: key)
            return
        }
        guard !keysApplyingCloudChange.contains(key) else { return }
        noteLocalMutation(for: key)

        let cloudData = cloudStore.data(forKey: key)
        let cloudToken = cloudStore.double(forKey: FeedCacheSync.syncTokenKey(for: key))
        var resolvedToken = token

        if cloudData != data, cloudToken >= resolvedToken {
            resolvedToken = cloudToken.nextUp
            _ = FeedCacheSync.write(data, for: key, token: resolvedToken)
        }

        guard cloudData != data || cloudToken < resolvedToken else { return }
        scheduleCloudDataPush(data: data, token: resolvedToken, for: key)
    }

    private func syncAllFromCloudIfNeeded(preferCloudOnTie: Bool) {
        for key in syncKeys {
            syncDataFromCloudIfNeeded(for: key, preferCloudOnTie: preferCloudOnTie)
        }
        for preference in syncedPreferences {
            syncPreferenceFromCloudIfNeeded(for: preference, preferCloudOnTie: preferCloudOnTie)
        }
    }

    private func syncDataFromCloudIfNeeded(for key: String, preferCloudOnTie: Bool) {
        let localData = FeedCacheSync.bestAvailableData(for: key)
        let localToken = FeedCacheSync.bestAvailableToken(for: key)
        let cloudData = cloudStore.data(forKey: key)
        let cloudToken = cloudStore.double(forKey: FeedCacheSync.syncTokenKey(for: key))

        if shouldDeferCloudApply(for: key, localData: localData, cloudData: cloudData) {
            return
        }

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

            if key == FeedStorage.Keys.savedFeeds,
               let mergedData = mergedSavedFeedsData(localData: local, remoteData: remote) {
                let resolvedToken = max(normalizedLocalToken, normalizedCloudToken).nextUp
                _ = FeedCacheSync.write(mergedData, for: key, token: resolvedToken)
                pushToCloud(data: mergedData, token: resolvedToken, for: key)
                if mergedData != local {
                    NotificationCenter.default.post(name: .feedSavedFeedsDidSyncFromICloud, object: nil)
                }
                return
            }

            if key == FeedStorage.Keys.feedColorMap,
               let mergedData = mergedFeedColorMapData(
                    localData: local,
                    remoteData: remote,
                    preferLocalValues: normalizedLocalToken >= normalizedCloudToken
               ) {
                let resolvedToken = max(normalizedLocalToken, normalizedCloudToken).nextUp
                _ = FeedCacheSync.write(mergedData, for: key, token: resolvedToken)
                pushToCloud(data: mergedData, token: resolvedToken, for: key)
                if mergedData != local {
                    NotificationCenter.default.post(name: .feedColorMapDidSyncFromICloud, object: nil)
                }
                return
            }

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
        localMutationDatesByKey.removeValue(forKey: key)
        appliedCloudPayloadsByKey[key] = data
        _ = FeedCacheSync.write(data, for: key, token: resolvedToken)
        if let notification = notificationByKey[key] {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    private func shouldDeferCloudApply(for key: String, localData: Data?, cloudData: Data?) -> Bool {
        guard localData != cloudData else { return false }
        guard let localMutationDate = localMutationDatesByKey[key] else { return false }
        return Date().timeIntervalSince(localMutationDate) < localMutationCloudApplyGraceInterval
    }

    private func pushToCloud(data: Data, token: Double, for key: String) {
        cloudStore.set(data, forKey: key)
        cloudStore.set(token, forKey: FeedCacheSync.syncTokenKey(for: key))
        scheduleCloudSynchronize()
    }

    private func scheduleCloudDataPush(data: Data, token: Double, for key: String) {
        pendingCloudDataPushes[key] = PendingCloudDataPush(data: data, token: token)
        cloudDataPushTasks[key]?.cancel()
        cloudDataPushTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.cloudPushDebounceNanoseconds ?? 250_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let pending = self.pendingCloudDataPushes.removeValue(forKey: key) else { return }
            self.cloudDataPushTasks[key] = nil
            let cloudData = self.cloudStore.data(forKey: key)
            let cloudToken = self.cloudStore.double(forKey: FeedCacheSync.syncTokenKey(for: key))
            var resolvedToken = pending.token

            if cloudData != pending.data, cloudToken >= resolvedToken {
                if key == FeedStorage.Keys.savedFeeds {
                    resolvedToken = cloudToken.nextUp
                    _ = FeedCacheSync.write(pending.data, for: key, token: resolvedToken)
                } else {
                    guard self.shouldDeferCloudApply(for: key, localData: pending.data, cloudData: cloudData) else {
                        return
                    }
                    resolvedToken = cloudToken.nextUp
                    _ = FeedCacheSync.write(pending.data, for: key, token: resolvedToken)
                }
            }

            guard cloudData != pending.data || cloudToken < resolvedToken else { return }
            self.pushToCloud(data: pending.data, token: resolvedToken, for: key)
        }
    }

    private func mergedSavedFeedsData(localData: Data, remoteData: Data) -> Data? {
        guard let localFeeds = try? JSONDecoder().decode([FeedSource].self, from: localData),
              let remoteFeeds = try? JSONDecoder().decode([FeedSource].self, from: remoteData) else {
            return nil
        }

        let deletedURLs = FeedStorage.deletedFeedURLs()
        var mergedFeeds = localFeeds
        var existingURLs = Set(localFeeds.map(\.url))

        for remoteFeed in remoteFeeds {
            guard !existingURLs.contains(remoteFeed.url),
                  !deletedURLs.contains(remoteFeed.url) else {
                continue
            }
            mergedFeeds.append(remoteFeed)
            existingURLs.insert(remoteFeed.url)
        }

        return try? JSONEncoder().encode(mergedFeeds)
    }

    private func mergedFeedColorMapData(localData: Data,
                                        remoteData: Data,
                                        preferLocalValues: Bool) -> Data? {
        guard let localMap = try? JSONDecoder().decode([String: String].self, from: localData),
              let remoteMap = try? JSONDecoder().decode([String: String].self, from: remoteData) else {
            return nil
        }

        let deletedURLs = FeedStorage.deletedFeedURLs()
        var merged = preferLocalValues ? remoteMap : localMap
        let overlay = preferLocalValues ? localMap : remoteMap

        for (url, hex) in overlay where !deletedURLs.contains(url) {
            merged[url] = hex
        }

        for deletedURL in deletedURLs {
            merged.removeValue(forKey: deletedURL)
        }

        guard merged != localMap || merged != remoteMap else { return nil }
        return try? JSONEncoder().encode(merged)
    }

    private func scheduleCloudSynchronize() {
        cloudSynchronizeTask?.cancel()
        cloudSynchronizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.cloudSynchronizeDebounceNanoseconds ?? 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.cloudSynchronizeTask = nil
            self.cloudStore.synchronize()
        }
    }

    private func pushLocalPreferenceValue(_ value: SyncedPreferenceValue, for key: String) {
        guard let preference = syncedPreference(for: key) else { return }
        let localValue = bestAvailablePreferenceValue(for: preference)

        if preferenceKeysApplyingCloudChange.contains(key) {
            return
        }

        let token: Double
        if localValue.value == value {
            token = localValue.token > 0 ? localValue.token : writePreference(value, for: preference)
        } else {
            token = writePreference(value, for: preference)
        }

        let cloudValue = cloudPreferenceValue(for: preference)
        let cloudToken = cloudStore.double(forKey: FeedCacheSync.syncTokenKey(for: key))
        guard cloudValue != value || cloudToken < token else { return }

        pushPreferenceToCloud(value, token: token, for: preference)
    }

    private func syncPreferenceFromCloudIfNeeded(for preference: SyncedPreference, preferCloudOnTie: Bool) {
        let local = bestAvailablePreferenceValue(for: preference)
        let cloudValue = cloudPreferenceValue(for: preference)
        let cloudToken = cloudStore.double(forKey: FeedCacheSync.syncTokenKey(for: preference.key))

        switch (local.value, cloudValue) {
        case (nil, nil):
            let token = writePreference(preference.defaultValue, for: preference)
            pushPreferenceToCloud(preference.defaultValue, token: token, for: preference)
        case (nil, let remote?):
            applyCloudPreference(remote, token: cloudToken, for: preference)
        case (let localValue?, nil):
            let token = local.token > 0 ? local.token : writePreference(localValue, for: preference)
            pushPreferenceToCloud(localValue, token: token, for: preference)
        case (let localValue?, let remote?):
            if localValue == remote {
                let resolvedToken = max(local.token, cloudToken)
                if resolvedToken > 0 {
                    _ = writePreference(localValue, for: preference, token: resolvedToken)
                    pushPreferenceToCloud(localValue, token: resolvedToken, for: preference)
                }
                return
            }

            let normalizedLocalToken = local.token > 0 ? local.token : 0
            let normalizedCloudToken = cloudToken > 0 ? cloudToken : 0

            if normalizedCloudToken > normalizedLocalToken {
                applyCloudPreference(remote, token: normalizedCloudToken, for: preference)
            } else if normalizedLocalToken > normalizedCloudToken {
                pushPreferenceToCloud(localValue, token: normalizedLocalToken, for: preference)
            } else if preferCloudOnTie {
                applyCloudPreference(remote, token: normalizedCloudToken, for: preference)
            } else {
                let newToken = writePreference(localValue, for: preference)
                pushPreferenceToCloud(localValue, token: newToken, for: preference)
            }
        }
    }

    private func applyCloudPreference(_ value: SyncedPreferenceValue, token: Double, for preference: SyncedPreference) {
        preferenceKeysApplyingCloudChange.insert(preference.key)
        defer { preferenceKeysApplyingCloudChange.remove(preference.key) }

        let resolvedToken = token > 0 ? token : Date().timeIntervalSince1970
        _ = writePreference(value, for: preference, token: resolvedToken)
        NotificationCenter.default.post(name: preference.notification, object: nil)
    }

    private func pushPreferenceToCloud(_ value: SyncedPreferenceValue, token: Double, for preference: SyncedPreference) {
        switch value {
        case .bool(let value):
            cloudStore.set(value, forKey: preference.key)
        case .int(let value):
            cloudStore.set(Int64(value), forKey: preference.key)
        case .double(let value):
            cloudStore.set(value, forKey: preference.key)
        case .string(let value):
            cloudStore.set(value, forKey: preference.key)
        }
        cloudStore.set(token, forKey: FeedCacheSync.syncTokenKey(for: preference.key))
        scheduleCloudSynchronize()
    }

    private func syncedPreference(for key: String) -> SyncedPreference? {
        syncedPreferences.first(where: { $0.key == key })
    }

    private func bestAvailablePreferenceValue(for preference: SyncedPreference) -> (value: SyncedPreferenceValue?, token: Double) {
        let groupDefaults = FeedStorage.defaults
        let standardDefaults = UserDefaults.standard
        let tokenKey = FeedCacheSync.syncTokenKey(for: preference.key)
        let groupToken = groupDefaults.double(forKey: tokenKey)
        let standardToken = standardDefaults.double(forKey: tokenKey)
        let groupValue = preference.localValue(from: groupDefaults)
        let standardValue = preference.localValue(from: standardDefaults)

        switch (groupValue, standardValue) {
        case (nil, nil):
            return (nil, max(groupToken, standardToken))
        case (let groupValue?, nil):
            return (groupValue, max(groupToken, standardToken))
        case (nil, let standardValue?):
            return (standardValue, max(groupToken, standardToken))
        case (let groupValue?, let standardValue?):
            if groupToken > standardToken {
                return (groupValue, groupToken)
            }
            if standardToken > groupToken {
                return (standardValue, standardToken)
            }
            return (standardValue, standardToken)
        }
    }

    @discardableResult
    private func writePreference(_ value: SyncedPreferenceValue, for preference: SyncedPreference, token: Double? = nil) -> Double {
        let resolvedToken = token ?? Date().timeIntervalSince1970
        let tokenKey = FeedCacheSync.syncTokenKey(for: preference.key)
        let groupDefaults = FeedStorage.defaults
        let standardDefaults = UserDefaults.standard

        preference.set(value, in: groupDefaults)
        preference.set(value, in: standardDefaults)
        groupDefaults.set(resolvedToken, forKey: tokenKey)
        standardDefaults.set(resolvedToken, forKey: tokenKey)
        return resolvedToken
    }

    private func cloudPreferenceValue(for preference: SyncedPreference) -> SyncedPreferenceValue? {
        preference.cloudValue(from: cloudStore)
    }
}

private extension FeedICloudSyncManager {
    struct SyncedPreference {
        let key: String
        let defaultValue: SyncedPreferenceValue
        let notification: Notification.Name

        func localValue(from defaults: UserDefaults) -> SyncedPreferenceValue? {
            guard defaults.object(forKey: key) != nil else { return nil }
            switch defaultValue {
            case .bool:
                return .bool(defaults.bool(forKey: key))
            case .int:
                return .int(defaults.integer(forKey: key))
            case .double:
                return .double(defaults.double(forKey: key))
            case .string:
                return .string(defaults.string(forKey: key) ?? "")
            }
        }

        func cloudValue(from store: NSUbiquitousKeyValueStore) -> SyncedPreferenceValue? {
            guard store.object(forKey: key) != nil else { return nil }
            switch defaultValue {
            case .bool:
                return .bool(store.bool(forKey: key))
            case .int:
                return .int(Int(store.longLong(forKey: key)))
            case .double:
                return .double(store.double(forKey: key))
            case .string:
                return .string(store.string(forKey: key) ?? "")
            }
        }

        func set(_ value: SyncedPreferenceValue, in defaults: UserDefaults) {
            switch value {
            case .bool(let value):
                defaults.set(value, forKey: key)
            case .int(let value):
                defaults.set(value, forKey: key)
            case .double(let value):
                defaults.set(value, forKey: key)
            case .string(let value):
                defaults.set(value, forKey: key)
            }
        }
    }

    enum SyncedPreferenceValue: Equatable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
    }

    struct PendingCloudDataPush {
        let data: Data
        let token: Double
    }
}
