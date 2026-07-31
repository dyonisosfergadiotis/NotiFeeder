import SwiftUI

@main
struct NotiFeeder_AtvApp: App {
    @StateObject private var articleStore = TVArticleStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(articleStore)
                .tint(.accentColor)
        }
    }
}
