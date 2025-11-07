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

    func scheduleNewArticlesNotification(count: Int, feedTitle: String? = nil) {
        guard count > 0 else { return }
        let content = UNMutableNotificationContent()
        if let feedTitle, !feedTitle.isEmpty {
            content.title = "Neue Artikel in \(feedTitle)"
        } else {
            content.title = "Neue Artikel verfügbar"
        }
        content.body = count == 1 ? "1 neuer Artikel" : "\(count) neue Artikel"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.5, repeats: false)
        let request = UNNotificationRequest(identifier: "notifeeder.new.articles.summary", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
