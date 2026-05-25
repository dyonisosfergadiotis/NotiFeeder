import SwiftUI
import BackgroundTasks
import SwiftData


// Use the FeedSource defined in this target (no module qualifier to avoid ambiguity)

@main
struct NotiFeederApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
        FeedBackgroundRefreshManager.registerIfNeeded()
        FeedBackgroundRefreshManager.scheduleNext()

        Task { @MainActor in
            FeedICloudSyncManager.shared.configureIfNeeded()
            FeedCloudKitSyncManager.shared.configureIfNeeded()
        }
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        Task { @MainActor in
            FeedICloudSyncManager.shared.syncAllFromCloudIfNeeded()
            await FeedCloudKitSyncManager.shared.syncAllFromCloudIfPossible()
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        FeedBackgroundRefreshManager.scheduleNext()

        Task { @MainActor in
            FeedICloudSyncManager.shared.syncAllFromCloudIfNeeded()
            await FeedCloudKitSyncManager.shared.syncAllFromCloudIfPossible()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        FeedBackgroundRefreshManager.scheduleNext()
    }

    func application(_ application: UIApplication,
                     performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            let result = await FeedBackgroundRefreshManager.performBackgroundFetch()
            if result.wasCancelled {
                completionHandler(.failed)
                return
            }
            if result.didWriteCache {
                completionHandler(.newData)
                return
            }
            if result.successfulFeeds > 0 {
                completionHandler(.noData)
                return
            }
            completionHandler(.failed)
        }
    }
}
