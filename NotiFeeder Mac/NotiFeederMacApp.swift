import SwiftUI

@main
struct NotiFeederMacApp: App {
    @StateObject private var store = MacFeedStore()
    @StateObject private var theme = ThemeSettings()

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environmentObject(store)
                .environmentObject(theme)
                .tint(theme.uiAccentColor)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            MacFeedCommands()
        }

        Settings {
            MacSettingsView()
                .environmentObject(store)
                .environmentObject(theme)
                .frame(width: 520)
        }
    }
}
