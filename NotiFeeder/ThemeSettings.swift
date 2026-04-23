import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

// Version 1.2 features: What's New splash + a few inline info bubbles

final class ThemeSettings: ObservableObject {
    private static let darkModeSkyBlueHex = "#7CC4FF"
    private static let lightModeSkyBlueHex = "#2F7FD6"

    private enum Keys {
        static let feedColorMap = FeedStorage.Keys.feedColorMap
        static let uiAccentHex = "uiAccentHex"
    }

    private static let appGroupSuite = AppGroupDefaults.suiteName

    /// Fixed app accent tone used for persistence and widget fallback.
    @Published private(set) var uiAccentHex: String = ThemeSettings.lightModeSkyBlueHex

    private let defaults: UserDefaults
    private(set) var decoder = JSONDecoder()
    private(set) var encoder = JSONEncoder()
    private var cloudSyncObservers: [NSObjectProtocol] = []

    @Published private(set) var feedColorMap: [String: String] = [:]

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        observeCloudSync()
        loadFeedColors()
        self.uiAccentHex = Self.lightModeSkyBlueHex
        syncAccentToAppGroup()
    }

    deinit {
        for observer in cloudSyncObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var uiAccentColor: Color {
        #if canImport(UIKit)
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
            ? UIColor(Color.fromHex(Self.darkModeSkyBlueHex))
            : UIColor(Color.fromHex(Self.lightModeSkyBlueHex))
        })
        #else
        Color.fromHex(Self.lightModeSkyBlueHex)
        #endif
    }
    
    var uiSwipeColor: Color {
        uiAccentColor
    }

    func color(for feedURL: String?) -> Color {
        guard let url = feedURL else { return uiAccentColor }
        if let storedHex = feedColorMap[url] {
            return Color.fromHex(storedHex)
        }
        let option = defaultOption(for: url)
        feedColorMap[url] = option.hex
        saveFeedColors()
        return option.color
    }

    func colorOption(for feedURL: String) -> FeedColorOption {
        if let storedHex = feedColorMap[feedURL],
           let option = FeedColorOption.option(for: storedHex) {
            return option
        }
        return defaultOption(for: feedURL)
    }

    func setColor(_ option: FeedColorOption, for feedURL: String) {
        feedColorMap[feedURL] = option.hex
        saveFeedColors()
    }

    func setColorHex(_ hex: String, for feedURL: String) {
        let normalized = normalizeHex(hex)
        feedColorMap[feedURL] = normalized
        saveFeedColors()
    }

    func resetColor(for feedURL: String) {
        feedColorMap.removeValue(forKey: feedURL)
        saveFeedColors()
    }

    private func defaultOption(for feedURL: String) -> FeedColorOption {
        let index = abs(feedURL.hashValue) % FeedColorOption.defaultPalette.count
        return FeedColorOption.defaultPalette[index]
    }

    private func loadFeedColors() {
        guard let data = FeedCacheSync.bestAvailableData(for: Keys.feedColorMap)
                ?? defaults.data(forKey: Keys.feedColorMap),
              let map = try? decoder.decode([String: String].self, from: data) else {
            feedColorMap = [:]
            return
        }
        feedColorMap = map
    }

    private func saveFeedColors() {
        if let data = try? encoder.encode(feedColorMap) {
            _ = FeedCacheSync.write(data, for: Keys.feedColorMap)
            Task { @MainActor in
                FeedICloudSyncManager.shared.pushLocalData(data, for: Keys.feedColorMap)
            }
        }
    }

    @MainActor
    func syncFromCloudIfNeeded() {
        FeedICloudSyncManager.shared.syncDataFromCloudIfNeeded(for: Keys.feedColorMap)
        loadFeedColors()
    }

    private func normalizeHex(_ hex: String) -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            return trimmed
        }
        return "#" + trimmed
    }

    private var appGroupDefaults: UserDefaults {
        AppGroupDefaults.defaults(suiteName: Self.appGroupSuite, fallback: defaults)
    }

    private func syncAccentToAppGroup() {
        let group = appGroupDefaults
        if group.string(forKey: Keys.uiAccentHex) != Self.lightModeSkyBlueHex {
            group.set(Self.lightModeSkyBlueHex, forKey: Keys.uiAccentHex)
        }
    }

    private func observeCloudSync() {
        let observer = NotificationCenter.default.addObserver(
            forName: .feedColorMapDidSyncFromICloud,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadFeedColors()
        }
        cloudSyncObservers.append(observer)
    }
}

extension Color {
    public static func fromHex(_ hex: String) -> Color {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&int)

        let r, g, b: UInt64
        switch sanitized.count {
        case 6:
            r = (int >> 16) & 0xFF
            g = (int >> 8) & 0xFF
            b = int & 0xFF
        default:
            r = 128
            g = 128
            b = 128
        }

        return Color(.sRGB,
                     red: Double(r) / 255.0,
                     green: Double(g) / 255.0,
                     blue: Double(b) / 255.0,
                     opacity: 1.0)
    }
    
    func toHex() -> String? {
            // 1. In UIColor konvertieren
            let uic = UIColor(self)
            
            // 2. Sicherstellen, dass wir im RGB-Farbraum sind (wichtig für Systemfarben/Graustufen)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            
            guard uic.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return nil
            }
            
            // 3. Konvertierung zu Int
            let r = Int(lroundf(Float(red) * 255))
            let g = Int(lroundf(Float(green) * 255))
            let b = Int(lroundf(Float(blue) * 255))
            let a = Int(lroundf(Float(alpha) * 255))
            
            // 4. Formatierung
            if alpha < 1.0 {
                return String(format: "%02X%02X%02X%02X", r, g, b, a)
            } else {
                return String(format: "%02X%02X%02X", r, g, b)
            }
        }
}


#if DEBUG
import SwiftUI

struct ThemeSettings_BubblesPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Farbpalette")
                .font(.headline)
                .infoBubble(id: "settings.feedcolor.palette.tip") {
                    Text("Wähle eine Farbe für diesen Feed.")
                        .font(.caption)
                }

            HStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 44)
                    .overlay(Text("Zurücksetzen"))
            }
            .infoBubble(id: "settings.feedcolor.reset.tip") {
                Text("Setzt die Farbe auf automatisch zurück.")
                    .font(.caption)
            }
        }
        .padding()
    }
}

#Preview("Bubbles in Settings") {
    ThemeSettings_BubblesPreview()
}
#endif
