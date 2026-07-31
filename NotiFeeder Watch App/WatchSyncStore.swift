import Foundation
import Combine
import WatchConnectivity
#if canImport(WidgetKit)
import WidgetKit
#endif

private enum WatchSyncConstants {
    static let appGroupSuiteName = "group.notiFeeder"
    static let snapshotData = "watch.feed.snapshot"
    static let requestType = "request"
    static let openLink = "link"
    static let refresh = "refresh"
    static let open = "open"
    static let bookmark = "bookmark"
    static let cachedSnapshot = "watch.cached.snapshot"
}

@MainActor
final class WatchSyncStore: NSObject, ObservableObject {
    @Published private(set) var snapshot: WatchFeedSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var statusText: String?

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let defaults = UserDefaults(suiteName: WatchSyncConstants.appGroupSuiteName) ?? .standard

    override init() {
        super.init()
        restoreCachedSnapshot()
        activateSessionIfNeeded()
    }

    var entries: [WatchFeedEntry] {
        guard let snapshot else { return [] }
        return Self.sortedEntries(snapshot.entries)
    }

    var lastRefreshText: String {
        guard let date = snapshot?.lastRefreshDate ?? snapshot?.generatedAt else {
            return "Noch nicht aktualisiert"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Aktualisiert \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    func activateSessionIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()

        if let data = session.applicationContext[WatchSyncConstants.snapshotData] as? Data {
            consumeSnapshotData(data)
        }
    }

    func requestRefresh() async {
        guard WCSession.isSupported() else {
            statusText = "WatchConnectivity nicht verfügbar"
            return
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            statusText = "Warte auf Verbindung zum iPhone"
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        await withCheckedContinuation { continuation in
            let message: [String: Any] = [WatchSyncConstants.requestType: WatchSyncConstants.refresh]

            if session.isReachable {
                session.sendMessage(message, replyHandler: { _ in
                    Task { @MainActor in
                        self.statusText = "Aktualisierung gestartet"
                        continuation.resume()
                    }
                }, errorHandler: { _ in
                    session.transferUserInfo(message)
                    Task { @MainActor in
                        self.statusText = "Wird im Hintergrund aktualisiert"
                        continuation.resume()
                    }
                })
            } else {
                session.transferUserInfo(message)
                statusText = "Wird im Hintergrund aktualisiert"
                continuation.resume()
            }
        }
    }

    func openOnPhone(link: String) {
        guard WCSession.isSupported() else { return }
        let payload: [String: Any] = [
            WatchSyncConstants.requestType: WatchSyncConstants.open,
            WatchSyncConstants.openLink: link
        ]

        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            session.transferUserInfo(payload)
            statusText = "Öffnen ans iPhone gesendet"
        }
    }

    func toggleBookmark(for entry: WatchFeedEntry) {
        guard WCSession.isSupported() else { return }
        updateBookmarkLocally(link: entry.link)

        let payload: [String: Any] = [
            WatchSyncConstants.requestType: WatchSyncConstants.bookmark,
            WatchSyncConstants.openLink: entry.link
        ]

        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: { [weak self] _ in
                session.transferUserInfo(payload)
                Task { @MainActor in
                    self?.statusText = "Lesezeichen ans iPhone gesendet"
                }
            })
        } else {
            session.transferUserInfo(payload)
            statusText = "Lesezeichen ans iPhone gesendet"
        }
    }

    private func restoreCachedSnapshot() {
        guard let data = defaults.data(forKey: WatchSyncConstants.cachedSnapshot) else { return }
        consumeSnapshotData(data)
    }

    private func consumeSnapshotData(_ data: Data) {
        guard let decoded = try? decoder.decode(WatchFeedSnapshot.self, from: data) else { return }
        snapshot = decoded
        defaults.set(data, forKey: WatchSyncConstants.cachedSnapshot)

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func updateBookmarkLocally(link: String) {
        guard let snapshot,
              let index = snapshot.entries.firstIndex(where: { $0.link == link }) else {
            return
        }
        var entries = snapshot.entries
        entries[index] = entries[index].toggledBookmark()
        let updated = WatchFeedSnapshot(
            generatedAt: snapshot.generatedAt,
            lastRefreshDate: snapshot.lastRefreshDate,
            feeds: snapshot.feeds,
            entries: entries
        )
        self.snapshot = updated
        if let data = try? JSONEncoder.watchSnapshotEncoder.encode(updated) {
            defaults.set(data, forKey: WatchSyncConstants.cachedSnapshot)
        }
    }

    private static func sortedEntries(_ entries: [WatchFeedEntry]) -> [WatchFeedEntry] {
        entries.sorted { lhs, rhs in
            if lhs.watchPriority != rhs.watchPriority {
                return lhs.watchPriority > rhs.watchPriority
            }
            return (lhs.parsedDate ?? .distantPast) > (rhs.parsedDate ?? .distantPast)
        }
    }
}

extension WatchSyncStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if let error {
            Task { @MainActor in
                self.statusText = error.localizedDescription
            }
            return
        }

        if let data = session.applicationContext["watch.feed.snapshot"] as? Data {
            Task { @MainActor in
                self.consumeSnapshotData(data)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        guard let data = applicationContext["watch.feed.snapshot"] as? Data else { return }
        Task { @MainActor in
            self.consumeSnapshotData(data)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        guard let data = userInfo["watch.feed.snapshot"] as? Data else { return }
        Task { @MainActor in
            self.consumeSnapshotData(data)
        }
    }

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
#endif
}

private extension JSONEncoder {
    static var watchSnapshotEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
