import SwiftUI

@main
struct MyApp: App {
    @StateObject private var model = Model()
    @StateObject private var settings = Settings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(settings)
                .enableBackgroundRefresh()
        }
    }
}
