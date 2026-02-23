import SwiftUI
import BackgroundTasks
import SwiftData


// Use the FeedSource defined in this target (no module qualifier to avoid ambiguity)

@main
struct NotiFeederApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var theme = ThemeSettings()
    private let watchSyncManager = PhoneWatchSyncManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ArticleStore.shared)
                .environmentObject(theme)
                .tint(theme.uiAccentColor)
                .onAppear {
                    watchSyncManager.activateSessionIfNeeded()
                }
        }
        .modelContainer(for: FeedEntryModel.self)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        return true
    }
}
