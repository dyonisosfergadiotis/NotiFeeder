import SwiftUI

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

    func color(for colorScheme: ColorScheme) -> Color {
        Color.fromHex(Self.resolvedHex(hex, for: colorScheme))
    }

    static let defaultPalette: [FeedColorOption] = [
        FeedColorOption(name: "Rosenquarz", hex: "#FF9EB5"),
        FeedColorOption(name: "Koralle", hex: "#FFB38A"),
        FeedColorOption(name: "Sonnengelb", hex: "#FFE16B"),
        FeedColorOption(name: "Limette", hex: "#B8E85A"),
        FeedColorOption(name: "Mint", hex: "#7EE7B8"),
        FeedColorOption(name: "Türkis", hex: "#6FE7E7"),
        FeedColorOption(name: "Himmel", hex: "#89B8FF"),
        FeedColorOption(name: "Lavendel", hex: "#C0A6FF"),
        FeedColorOption(name: "Pink", hex: "#FF9BE8")
    ]

    static func option(for hex: String) -> FeedColorOption? {
        defaultPalette.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }

    static func resolvedColor(for hex: String, colorScheme: ColorScheme) -> Color {
        Color.fromHex(resolvedHex(hex, for: colorScheme))
    }

    static func resolvedHex(_ hex: String, for colorScheme: ColorScheme) -> String {
        let normalized = normalizeHex(hex)
        guard colorScheme == .light else { return normalized }
        return lightModeHexOverrides[normalized.uppercased()] ?? normalized
    }

    private static func normalizeHex(_ hex: String) -> String {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixed = trimmed.hasPrefix("#") ? trimmed : "#" + trimmed
        return prefixed.uppercased()
    }

    private static let lightModeHexOverrides: [String: String] = [
        "#FF9EB5": "#E33F68",
        "#FFB38A": "#E56B2F",
        "#FFE16B": "#B88400",
        "#B8E85A": "#6CA900",
        "#7EE7B8": "#009A72",
        "#6FE7E7": "#008FA1",
        "#89B8FF": "#3478D8",
        "#C0A6FF": "#7956D8",
        "#FF9BE8": "#D83CC7"
    ]
}
