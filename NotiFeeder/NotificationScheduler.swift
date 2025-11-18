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
        scheduleNotification(
            title: "Test-Benachrichtigung",
            body: "Wenn du das siehst, funktionieren lokale Benachrichtigungen."
        )
    }

    func scheduleArticleNotification(for entry: FeedEntry, feedTitle: String? = nil) {
        let body = NotificationSummary.summarize(entry: entry)

        var userInfo: [String: Any] = ["link": entry.link]
        if let source = entry.feedURL {
            userInfo["feedURL"] = source
        }

        scheduleNotification(
            title: entry.title,
            subtitle: feedTitle ?? entry.sourceTitle,
            body: body,
            userInfo: userInfo,
            identifier: entry.link
        )
    }

    func scheduleStatusNotification(title: String, body: String, identifier: String = UUID().uuidString) {
        scheduleNotification(title: title, body: body, identifier: identifier)
    }

    private func scheduleNotification(
        title: String,
        subtitle: String? = nil,
        body: String,
        userInfo: [String: Any] = [:],
        identifier: String = UUID().uuidString
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = body
        content.userInfo = userInfo
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
