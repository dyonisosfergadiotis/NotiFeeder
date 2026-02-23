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
        FeedColorOption(name: "Rosenquarz", hex: "#F7C8D0"),
        FeedColorOption(name: "Aprikose", hex: "#FFD5B8"),
        FeedColorOption(name: "Vanille", hex: "#FCE7A8"),
        FeedColorOption(name: "Pistazie", hex: "#D7EDB5"),
        FeedColorOption(name: "Mint", hex: "#BFEED8"),
        FeedColorOption(name: "Lagune", hex: "#BFE9F2"),
        FeedColorOption(name: "Himmel", hex: "#C9DDFF"),
        FeedColorOption(name: "Flieder", hex: "#DECDFB"),
        FeedColorOption(name: "Pfirsich", hex: "#FFD9C8")
    ]

    static func option(for hex: String) -> FeedColorOption? {
        defaultPalette.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }
    }
}
