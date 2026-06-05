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
}
