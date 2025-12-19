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

        return true
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

