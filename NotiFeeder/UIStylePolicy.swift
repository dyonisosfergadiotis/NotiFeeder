import SwiftUI

enum UIStylePolicy {
    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 14
        static let xLarge: CGFloat = 16
    }

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 14
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
    }

    enum Sheet {
        static let scrollContentBottomInset: CGFloat = 12
        static let compactDetent: PresentationDetent = .fraction(0.45)
        static let mediumDetent: PresentationDetent = .fraction(0.5)
    }

    enum Toolbar {
        static var neutralIcon: Color { .secondary }
    }

    enum Motion {
        static let quickDuration: Double = 0.16
        static let standardDuration: Double = 0.2
        static let smoothDuration: Double = 0.22
        static var standardEase: Animation { .easeInOut(duration: standardDuration) }
        static var detailScrollSpring: Animation {
            .interactiveSpring(response: 0.36, dampingFraction: 0.88, blendDuration: 0.2)
        }
    }

    static let glassAccentOpacity: Double = 0.08
    static let cardTintOpacity: Double = 0.10
    static let cardTintOpacityRead: Double = 0.08
    static let fullColorCardInteriorOpacity: Double = 0.10
    static let fullColorCardTintOpacity: Double = 0.34
    static let fullColorCardTintOpacityRead: Double = 0.13
    static let cardBorderOpacityUnread: Double = 0.40
    static let cardBorderOpacityRead: Double = 0.12
    static let cardInnerStrokeOpacityUnread: Double = 0.06
    static let chipTintOpacityUnread: Double = 0.22
    static let chipTintOpacityRead: Double = 0.12
    static let summaryTextOpacity: Double = 0.75

    static var neutralIcon: Color { Toolbar.neutralIcon }

    static func iconTint(isActive: Bool, accent: Color) -> Color {
        isActive ? accent : neutralIcon
    }

    static func accentBackgroundColors(accent: Color, colorScheme: ColorScheme) -> [Color] {
        [
            accent.opacity(colorScheme == .dark ? 0.14 : 0.11),
            accent.opacity(colorScheme == .dark ? 0.06 : 0.04),
            Color(.systemBackground)
        ]
    }

    static func topChromeColors(accent: Color, colorScheme: ColorScheme) -> [Color] {
        [
            accent.opacity(colorScheme == .dark ? 0.16 : 0.12),
            accent.opacity(colorScheme == .dark ? 0.04 : 0.03),
            accent.opacity(0.01),
            accent.opacity(0.01)
        ]
    }
}
