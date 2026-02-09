import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

// Version 1.2 features: What's New splash + a few inline info bubbles

struct FeedColorOption: Identifiable, Equatable {
    let id: String
    let name: String
    let hex: String

    init(name: String, hex: String) {
        self.id = hex
        self.name = name
        self.hex = hex
    }

    var color: Color {
        Color.fromHex(hex)
    }

    static let defaultPalette: [FeedColorOption] = [
        FeedColorOption(name: "Karmin", hex: "#F3A2A2"),
        FeedColorOption(name: "Mandarine", hex: "#F4B989"),
        FeedColorOption(name: "Goldtulpe", hex: "#F7D783"),
        FeedColorOption(name: "Limette", hex: "#CFE08E"),
        FeedColorOption(name: "Jade", hex: "#B7E0C8"),
        FeedColorOption(name: "Meerblau", hex: "#A6DEDA"),
        FeedColorOption(name: "Indigo", hex: "#A9C8F2"),
        FeedColorOption(name: "Amethyst", hex: "#C4AEEF"),
        FeedColorOption(name: "Sand", hex: "#DDBF8F")
    ]

    static func option(for hex: String) -> FeedColorOption? {
        defaultPalette.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }
}

final class ThemeSettings: ObservableObject {
    private enum Keys {
        static let feedColorMap = "feedColorMap"
        static let uiAccentHex = "uiAccentHex"
    }

    private static let appGroupSuite = "group.notiFeeder"

    /// Carefully chosen accent tone reserved for the overall UI chrome.
    @Published private(set) var uiAccentHex: String = "#A9C8F2" // default; overridden in init

    private let defaults: UserDefaults
    private(set) var decoder = JSONDecoder()
    private(set) var encoder = JSONEncoder()

    @Published private(set) var feedColorMap: [String: String] = [:]

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        loadFeedColors()
        self.uiAccentHex = loadUIAccentHex()
        syncAccentToAppGroup()
    }

    var uiAccentColor: Color {
        Color.fromHex(uiAccentHex)
    }
    
    var uiSwipeColor: Color {
        Color.fromHex(uiAccentHex) //Color.fromHex(feedcolor)
    }

    var uiAccentHexString: String {
        uiAccentHex
    }

    func setUIAccentColor(_ color: Color) {
        #if canImport(UIKit)
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            let hex = String(format: "#%02lX%02lX%02lX", lroundf(Float(r * 255)), lroundf(Float(g * 255)), lroundf(Float(b * 255)))
            uiAccentHex = hex
            saveUIAccentHex()
        }
        #endif
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
        guard let data = defaults.data(forKey: Keys.feedColorMap),
              let map = try? decoder.decode([String: String].self, from: data) else {
            feedColorMap = [:]
            return
        }
        feedColorMap = map
    }

    private func saveFeedColors() {
        if let data = try? encoder.encode(feedColorMap) {
            defaults.set(data, forKey: Keys.feedColorMap)
        }
    }

    private func normalizeHex(_ hex: String) -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            return trimmed
        }
        return "#" + trimmed
    }

    private func loadUIAccentHex() -> String {
        if let stored = defaults.string(forKey: Keys.uiAccentHex), !stored.isEmpty {
            return stored
        }
        if let groupStored = appGroupDefaults?.string(forKey: Keys.uiAccentHex), !groupStored.isEmpty {
            return groupStored
        }
        return "#A9C8F2"
    }

    private func saveUIAccentHex() {
        defaults.set(uiAccentHex, forKey: Keys.uiAccentHex)
        appGroupDefaults?.set(uiAccentHex, forKey: Keys.uiAccentHex)
    }

    private var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.appGroupSuite)
    }

    private func syncAccentToAppGroup() {
        guard let group = appGroupDefaults else { return }
        if group.string(forKey: Keys.uiAccentHex) != uiAccentHex {
            group.set(uiAccentHex, forKey: Keys.uiAccentHex)
        }
    }
}

extension Color {
    static func fromHex(_ hex: String) -> Color {
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
