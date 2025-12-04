import SwiftUI
import BackgroundTasks
import SwiftData


// Use the FeedSource defined in this target (no module qualifier to avoid ambiguity)

@main
struct NotiFeederApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var theme = ThemeSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ArticleStore.shared)
                .environmentObject(theme)
                .tint(theme.uiAccentColor)
        }
        .modelContainer(for: FeedEntryModel.self)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        // Benachrichtigungserlaubnis

        // Background Task registrieren
        BGTaskScheduler.shared.register(forTaskWithIdentifier: "de.dyonisos.NotiFeeder.refresh", using: nil) { [self] task in
            Task {
                // Fetch new entries and merge into persistent store
                let feeds = self.loadFeedsFromStorage()
                await FeedBackgroundFetcher.shared.checkForNewEntries(feeds: feeds)
                task.setTaskCompleted(success: true)
            }
            self.scheduleNextFetch()
        }

        self.scheduleNextFetch()
        _ = ArticleStore.shared
        return true
    }

    func scheduleNextFetch() {
        let request = BGAppRefreshTaskRequest(identifier: "de.dyonisos.NotiFeeder.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60) // alle 30 min
        try? BGTaskScheduler.shared.submit(request)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        self.scheduleNextFetch()
    }

    private func loadFeedsFromStorage() -> [FeedSource] {
        if let data = UserDefaults.standard.data(forKey: "savedFeeds") {
            do {
                let feeds = try JSONDecoder().decode([FeedSource].self, from: data)
                return feeds
            } catch {
                // If decoding fails, fall back to default feed
            }
        }
        return [FeedSource(title: "MacRumors", url: "https://feeds.macrumors.com/MacRumors-All")]
    }
}

