import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

enum WidgetTheme {
    private static let lightAccentHex = "#3F6F9F"
    private static let darkAccentHex = "#A6CDFB"

    static func accent(for colorScheme: ColorScheme) -> Color {
        Color.fromHex(colorScheme == .dark ? darkAccentHex : lightAccentHex)
    }

    static func primaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : Color(red: 0.08, green: 0.10, blue: 0.12)
    }

    static func secondaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.72) : Color.black.opacity(0.64)
    }

    static func tertiaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white.opacity(0.48) : Color.black.opacity(0.42)
    }

    static func cardFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.62) : Color.white.opacity(0.93)
    }

    static func divider(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }

    static func textShadow(for colorScheme: ColorScheme, isTransparent: Bool, opacity: Double) -> Color {
        guard isTransparent else { return .clear }
        return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity * 0.85)
    }
}

public extension Color {
    static func fromHex(_ hex: String) -> Color {
        #if canImport(UIKit)
        Color(UIColor { trait in
            let colorScheme: ColorScheme = trait.userInterfaceStyle == .dark ? .dark : .light
            let resolvedHex = FeedColorOption.resolvedHex(hex, for: colorScheme)
            let components = rgbComponents(from: resolvedHex) ?? (128, 128, 128)
            return UIColor(
                red: CGFloat(components.red) / 255.0,
                green: CGFloat(components.green) / 255.0,
                blue: CGFloat(components.blue) / 255.0,
                alpha: 1.0
            )
        })
        #else
        let resolvedHex = FeedColorOption.resolvedHex(hex, for: .light)
        let components = rgbComponents(from: resolvedHex) ?? (128, 128, 128)
        return Color(.sRGB,
                     red: Double(components.red) / 255.0,
                     green: Double(components.green) / 255.0,
                     blue: Double(components.blue) / 255.0,
                     opacity: 1.0)
        #endif
    }

    private static func rgbComponents(from hex: String) -> (red: UInt64, green: UInt64, blue: UInt64)? {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard sanitized.count == 6, Scanner(string: sanitized).scanHexInt64(&int) else {
            return nil
        }

        return ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
    }
}
