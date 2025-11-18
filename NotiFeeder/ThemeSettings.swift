import SwiftUI
import Combine

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
        FeedColorOption(name: "Karmin", hex: "#FF6F61"),
        FeedColorOption(name: "Mandarine", hex: "#FF9F1C"),
        FeedColorOption(name: "Goldtulpe", hex: "#F6C344"),
        FeedColorOption(name: "Limette", hex: "#80C904"),
        FeedColorOption(name: "Jade", hex: "#2EC4B6"),
        FeedColorOption(name: "Meerblau", hex: "#2D9CDB"),
        FeedColorOption(name: "Indigo", hex: "#4C63D2"),
        FeedColorOption(name: "Amethyst", hex: "#9B5DE5"),
        FeedColorOption(name: "Sand", hex: "#D4A373")
    ]

    static func option(for hex: String) -> FeedColorOption? {
        defaultPalette.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }
}

final class ThemeSettings: ObservableObject {
    private enum Keys {
        static let feedColorMap = "feedColorMap"
    }

    /// Carefully chosen accent tone reserved for the overall UI chrome.
    private let uiAccentHex = "#9CCFFF" // Professional deep blue

    private let defaults: UserDefaults
    private(set) var decoder = JSONDecoder()
    private(set) var encoder = JSONEncoder()

    @Published private(set) var feedColorMap: [String: String] = [:]

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        loadFeedColors()
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
