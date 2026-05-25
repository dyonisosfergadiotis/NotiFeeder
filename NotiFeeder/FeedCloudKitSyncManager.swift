import CloudKit
import Foundation
import OSLog

extension Notification.Name {
    static let feedSavedArticlesDidSyncFromCloudKit = Notification.Name("feedSavedArticlesDidSyncFromCloudKit")
}

@MainActor
final class FeedCloudKitSyncManager {
    static let shared = FeedCloudKitSyncManager()

    private enum Field {
        static let key = "key"
        static let token = "token"
        static let payload = "payload"
        static let schemaVersion = "schemaVersion"
    }

    private enum Keys {
        static let pendingUploadKeys = "cloudkit.pendingUploadKeys"
    }

    private let containerIdentifier = "iCloud.de.DyonisosFergadiotis.NotiFeeder"
    private let recordType = "FeedBlob"
    private let database: CKDatabase
    private let defaults: UserDefaults
    private var didConfigure = false
    private var uploadTasks: [String: Task<Void, Never>] = [:]
    private var localMutationDatesByKey: [String: Date] = [:]
    private let localMutationCloudApplyGraceInterval: TimeInterval = 8

    private let syncKeys: [String] = [
        FeedStorage.Keys.cachedEntries,
        FeedStorage.Keys.savedArticles,
        FeedStorage.Keys.readArticleIDs,
        FeedStorage.Keys.bookmarkedArticleIDs
    ]

    private let notificationByKey: [String: Notification.Name] = [
        FeedStorage.Keys.cachedEntries: .feedCachedEntriesDidRefresh,
        FeedStorage.Keys.savedArticles: .feedSavedArticlesDidSyncFromCloudKit,
        FeedStorage.Keys.readArticleIDs: .feedReadArticleIDsDidSyncFromICloud,
        FeedStorage.Keys.bookmarkedArticleIDs: .feedBookmarkedArticleIDsDidSyncFromICloud
    ]

    init(container: CKContainer? = nil, defaults: UserDefaults? = nil) {
        let resolvedContainer = container ?? CKContainer(identifier: containerIdentifier)
        self.database = resolvedContainer.privateCloudDatabase
        self.defaults = defaults ?? FeedStorage.defaults
    }

    deinit {
        for task in uploadTasks.values {
            task.cancel()
        }
    }

    func configureIfNeeded() {
        guard !didConfigure else { return }
        didConfigure = true
        Task { @MainActor in
            await flushPendingUploadsIfPossible()
            await syncAllFromCloudIfPossible()
        }
    }

    func noteLocalMutation(for key: String) {
        guard syncKeys.contains(key) else { return }
        localMutationDatesByKey[key] = Date()
    }

    func uploadLocalData(_ data: Data, token: Double, for key: String) {
        guard syncKeys.contains(key) else { return }
        noteLocalMutation(for: key)
        markUploadPending(for: key)
        uploadTasks[key]?.cancel()
        uploadTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, let self else { return }
            let effectiveToken = await self.upload(data, token: token, for: key)
            if effectiveToken == nil {
                self.markUploadPending(for: key)
            } else {
                self.removePendingUpload(for: key)
            }
            self.uploadTasks[key] = nil
        }
    }

    func syncAllFromCloudIfPossible() async {
        await flushPendingUploadsIfPossible()
        for key in syncKeys {
            await syncDataFromCloudIfNeeded(for: key)
        }
    }

    func syncDataFromCloudIfNeeded(for key: String) async {
        guard syncKeys.contains(key) else { return }

        let localData = FeedCacheSync.bestAvailableData(for: key)
        let localToken = FeedCacheSync.bestAvailableToken(for: key)

        let remote: RemoteBlob?
        do {
            remote = try await fetchRemoteBlob(for: key)
        } catch {
            AppLogger.persistence.warning("CloudKit fetch failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if localData != nil {
                markUploadPending(for: key)
            }
            return
        }

        guard let remote else {
            if let localData {
                uploadLocalData(localData, token: localToken > 0 ? localToken : FeedCacheSync.write(localData, for: key), for: key)
            }
            return
        }

        guard let localData else {
            applyRemoteBlob(remote, for: key)
            return
        }

        if localData == remote.data {
            if remote.token > localToken {
                _ = FeedCacheSync.write(localData, for: key, token: remote.token)
            }
            removePendingUpload(for: key)
            return
        }

        if shouldPreferLocalOverRemote(for: key, localData: localData, remoteData: remote.data) {
            let token = max(localToken, remote.token).nextUp
            _ = FeedCacheSync.write(localData, for: key, token: token)
            uploadLocalData(localData, token: token, for: key)
            return
        }

        if key == FeedStorage.Keys.readArticleIDs,
           let mergedData = mergedReadStateData(localData: localData, remoteData: remote.data) {
            let token = max(localToken, remote.token).nextUp
            _ = FeedCacheSync.write(mergedData, for: key, token: token)
            removePendingUpload(for: key)
            postSyncNotification(for: key)
            if mergedData != remote.data {
                uploadLocalData(mergedData, token: token, for: key)
            }
            return
        }

        if remote.token > localToken || (remote.token == localToken && shouldPreferRemoteOnTie(for: key)) {
            applyRemoteBlob(remote, for: key)
        } else {
            uploadLocalData(localData, token: localToken, for: key)
        }
    }

    func flushPendingUploadsIfPossible() async {
        let keys = pendingUploadKeys()
        guard !keys.isEmpty else { return }

        for key in keys {
            guard let data = FeedCacheSync.bestAvailableData(for: key) else {
                removePendingUpload(for: key)
                continue
            }

            let localToken = FeedCacheSync.bestAvailableToken(for: key)
            if await upload(data, token: localToken > 0 ? localToken : FeedCacheSync.write(data, for: key), for: key) != nil {
                removePendingUpload(for: key)
            }
        }
    }

    private func upload(_ data: Data, token: Double, for key: String) async -> Double? {
        do {
            let existingRecord = try await fetchRecordIfAvailable(for: key)
            let currentRemoteToken = (existingRecord?[Field.token] as? NSNumber)?.doubleValue ?? 0
            var resolvedToken = token
            var uploadData = data

            if let existingRecord,
               currentRemoteToken >= resolvedToken,
               let remoteData = try await payloadData(from: existingRecord),
               remoteData != uploadData {
                if shouldPreferLocalOverRemote(for: key, localData: uploadData, remoteData: remoteData) {
                    resolvedToken = currentRemoteToken.nextUp
                    _ = FeedCacheSync.write(uploadData, for: key, token: resolvedToken)
                } else if key == FeedStorage.Keys.readArticleIDs,
                   let mergedData = mergedReadStateData(localData: uploadData, remoteData: remoteData) {
                    uploadData = mergedData
                    resolvedToken = currentRemoteToken.nextUp
                    _ = FeedCacheSync.write(uploadData, for: key, token: resolvedToken)
                } else {
                    return nil
                }
            }

            let record = existingRecord ?? CKRecord(recordType: recordType, recordID: recordID(for: key))
            record[Field.key] = key as NSString
            record[Field.token] = NSNumber(value: resolvedToken)
            record[Field.schemaVersion] = NSNumber(value: 1)

            let assetURL = try temporaryAssetURL(for: key, data: uploadData)
            defer { try? FileManager.default.removeItem(at: assetURL) }
            record[Field.payload] = CKAsset(fileURL: assetURL)

            _ = try await database.save(record)
            return resolvedToken
        } catch {
            AppLogger.persistence.warning("CloudKit upload failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func fetchRemoteBlob(for key: String) async throws -> RemoteBlob? {
        guard let record = try await fetchRecordIfAvailable(for: key) else { return nil }
        guard let data = try await payloadData(from: record) else { return nil }
        let token = (record[Field.token] as? NSNumber)?.doubleValue
            ?? record.modificationDate?.timeIntervalSince1970
            ?? 0
        return RemoteBlob(data: data, token: token)
    }

    private func fetchRecordIfAvailable(for key: String) async throws -> CKRecord? {
        do {
            return try await database.record(for: recordID(for: key))
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func applyRemoteBlob(_ remote: RemoteBlob, for key: String) {
        localMutationDatesByKey.removeValue(forKey: key)
        _ = FeedCacheSync.write(remote.data, for: key, token: remote.token)
        removePendingUpload(for: key)
        postSyncNotification(for: key)
    }

    private func shouldPreferLocalOverRemote(for key: String, localData: Data, remoteData: Data) -> Bool {
        guard localData != remoteData else { return false }
        guard let mutationDate = localMutationDatesByKey[key] else { return false }
        return Date().timeIntervalSince(mutationDate) < localMutationCloudApplyGraceInterval
    }

    private func shouldPreferRemoteOnTie(for key: String) -> Bool {
        key == FeedStorage.Keys.cachedEntries || key == FeedStorage.Keys.savedArticles
    }

    private func mergedReadStateData(localData: Data, remoteData: Data) -> Data? {
        guard let localIDs = readIDs(from: localData),
              let remoteIDs = readIDs(from: remoteData) else {
            return nil
        }
        let mergedIDs = localIDs.union(remoteIDs)
        guard mergedIDs != localIDs || mergedIDs != remoteIDs else {
            return nil
        }
        return try? JSONEncoder().encode(mergedIDs.sorted())
    }

    private func readIDs(from data: Data) -> Set<String>? {
        guard let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return Set(ids)
    }

    private func postSyncNotification(for key: String) {
        if let notification = notificationByKey[key] {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }

    private func payloadData(from record: CKRecord) async throws -> Data? {
        guard let asset = record[Field.payload] as? CKAsset,
              let fileURL = asset.fileURL else {
            return nil
        }
        return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    private func temporaryAssetURL(for key: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotiFeederCloudKit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory
            .appendingPathComponent(sanitizedRecordName(for: key))
            .appendingPathExtension(UUID().uuidString)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    private func recordID(for key: String) -> CKRecord.ID {
        CKRecord.ID(recordName: sanitizedRecordName(for: key))
    }

    private func sanitizedRecordName(for key: String) -> String {
        "feedBlob_" + key.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
    }

    private func pendingUploadKeys() -> Set<String> {
        guard let data = defaults.data(forKey: Keys.pendingUploadKeys),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded).intersection(syncKeys)
    }

    private func persistPendingUploadKeys(_ keys: Set<String>) {
        let sorted = Array(keys).sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        defaults.set(data, forKey: Keys.pendingUploadKeys)
    }

    private func markUploadPending(for key: String) {
        guard syncKeys.contains(key) else { return }
        var keys = pendingUploadKeys()
        keys.insert(key)
        persistPendingUploadKeys(keys)
    }

    private func removePendingUpload(for key: String) {
        var keys = pendingUploadKeys()
        guard keys.remove(key) != nil else { return }
        persistPendingUploadKeys(keys)
    }

    private struct RemoteBlob {
        let data: Data
        let token: Double
    }
}
