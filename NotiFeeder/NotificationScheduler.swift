import Foundation
import UserNotifications

final class NotificationScheduler {
    static let shared = NotificationScheduler()
    private init() {}

    func requestAuthorizationIfNeeded(completion: ((Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion?(true)
            case .denied:
                completion?(false)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    completion?(granted)
                }
            @unknown default:
                completion?(false)
            }
        }
    }

    func scheduleTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Test-Benachrichtigung"
        content.body = "Wenn du das siehst, funktionieren lokale Benachrichtigungen."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "notifeeder.test.notification", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    func scheduleArticleNotification(for entry: FeedEntry, feedTitle: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = entry.title
        if let feedTitle, !feedTitle.isEmpty {
            content.subtitle = feedTitle
        }
        content.body = bodySummary(for: entry)
        content.userInfo = ["link": entry.link]
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: entry.link, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func bodySummary(for entry: FeedEntry) -> String {
        let stripped = HTMLText.stripHTML(entry.content)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !stripped.isEmpty {
            return trimmed(stripped, limit: 160)
        }

        if let author = entry.author, !author.isEmpty {
            return "Von \(author)"
        }

        if let feed = entry.sourceTitle, !feed.isEmpty {
            return "Neuer Artikel auf \(feed)"
        }

        return "Neuer Artikel verfügbar"
    }

    private func trimmed(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        var candidate = String(text[..<idx])
        if let lastSpace = candidate.lastIndex(of: " ") {
            candidate = String(candidate[..<lastSpace])
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
