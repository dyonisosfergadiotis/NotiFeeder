import Foundation
import WatchConnectivity
import OSLog

extension Notification.Name {
    static let watchRefreshRequested = Notification.Name("watchRefreshRequested")
    static let watchOpenArticleRequested = Notification.Name("watchOpenArticleRequested")
}

struct WatchFeedSnapshot: Codable {
    let generatedAt: Date
    let lastRefreshDate: Date?
    let feeds: [WatchFeedSource]
    let entries: [WatchFeedEntry]
}

struct WatchFeedSource: Codable, Hashable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
}

struct WatchFeedEntry: Codable, Hashable, Identifiable {
    var id: String { link }
    let title: String
    let shortTitle: String
    let link: String
    let content: String
    let sourceTitle: String?
    let feedURL: String?
    let pubDateString: String?
    let isRead: Bool
}

final class PhoneWatchSyncManager: NSObject {
    static let shared = PhoneWatchSyncManager()

    private enum Keys {
        static let snapshotData = "watch.feed.snapshot"
        static let requestType = "request"
        static let openLink = "link"
        static let refresh = "refresh"
        static let open = "open"
    }

    private let maxEntries = 100
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var snapshotTask: Task<Void, Never>?
    private let activationQueue = DispatchQueue(label: "PhoneWatchSyncManager.activation")
    private var isActivationInFlight = false

    private override init() {
        super.init()
        activateSessionIfNeeded()
    }

    func activateSessionIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self

        let shouldActivate = activationQueue.sync { () -> Bool in
            guard !isActivationInFlight else { return false }
            guard session.activationState != .activated else { return false }
            isActivationInFlight = true
            return true
        }

        guard shouldActivate else { return }
        session.activate()
    }

    func pushSnapshot(feeds: [FeedSource], entries: [FeedEntry], readIDs: Set<String>, lastRefreshDate: Date?) {
        snapshotTask?.cancel()
        snapshotTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            let normalizedFeeds = feeds.map { WatchFeedSource(title: $0.title, url: $0.url) }
            let sorted = entries.sorted { lhs, rhs in
                DateParser.parse(lhs.pubDateString) > DateParser.parse(rhs.pubDateString)
            }

            let normalizedEntries = sorted.prefix(maxEntries).map { entry in
                WatchFeedEntry(
                    title: entry.title,
                    shortTitle: entry.shortTitle,
                    link: entry.link,
                    content: entry.content,
                    sourceTitle: entry.sourceTitle,
                    feedURL: entry.feedURL,
                    pubDateString: entry.pubDateString,
                    isRead: readIDs.contains(entry.link)
                )
            }

            let snapshot = WatchFeedSnapshot(
                generatedAt: Date(),
                lastRefreshDate: lastRefreshDate,
                feeds: normalizedFeeds,
                entries: normalizedEntries
            )

            guard let data = try? self.encoder.encode(snapshot) else { return }
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard self.canSendSnapshot(using: session) else { return }

            let context: [String: Any] = [Keys.snapshotData: data]
            do {
                try session.updateApplicationContext(context)
            } catch let wcError as WCError {
                if Self.canFallbackToBackgroundTransfer(for: wcError) {
                    session.transferUserInfo(context)
                }
            } catch {
                session.transferUserInfo(context)
            }
        }
    }

    private func canSendSnapshot(using session: WCSession) -> Bool {
        guard session.activationState == .activated else {
            activateSessionIfNeeded()
            return false
        }

#if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { return false }
#endif
        return true
    }

    private static func canFallbackToBackgroundTransfer(for error: WCError) -> Bool {
        switch error.code {
        case .watchAppNotInstalled, .deviceNotPaired, .sessionNotActivated, .payloadTooLarge:
            return false
        default:
            return true
        }
    }

}

extension PhoneWatchSyncManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        activationQueue.sync {
            isActivationInFlight = false
        }
        if let error {
            AppLogger.app.error("WCSession activation error: \(error.localizedDescription, privacy: .public)")
            return
        }
        AppLogger.app.info("WCSession activated with state: \(activationState.rawValue)")
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handleIncoming(message: message)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        handleIncoming(message: userInfo)
    }

    private func handleIncoming(message: [String: Any]) {
        guard let request = message[Keys.requestType] as? String else { return }

        switch request {
        case Keys.refresh:
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .watchRefreshRequested, object: nil)
            }
        case Keys.open:
            guard let link = message[Keys.openLink] as? String, !link.isEmpty else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .watchOpenArticleRequested,
                    object: nil,
                    userInfo: [Keys.openLink: link]
                )
            }
        default:
            break
        }
    }

#if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        activationQueue.sync {
            isActivationInFlight = false
        }
        activateSessionIfNeeded()
    }
#endif
}
