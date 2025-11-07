import SwiftUI

/// Wrap your root view with this to inject shared environment objects and enable background refresh
struct AppRoot<Content: View>: View {
    private let content: Content
    @StateObject private var theme = ThemeSettings()

    // Use a shared instance if ArticleStore has a private init
    @StateObject private var store = ArticleStore.shared

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .environmentObject(store)
            .environmentObject(theme)
            .enableBackgroundRefresh()
    }
}

#Preview {
    AppRoot {
        ContentView()
    }
}
