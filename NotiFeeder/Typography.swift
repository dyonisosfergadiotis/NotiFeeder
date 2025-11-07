import SwiftUI

struct AppTypography {
    // Section label (feed title chips)
    static let sectionLabel = Font.caption.weight(.semibold)
    // Primary title (article title)
    static let title = Font.headline
    // Secondary text (summary/excerpt)
    static let secondary = Font.subheadline
    // Meta info (date, source, small notes)
    static let meta = Font.caption
}

extension View {
    func appSectionLabel() -> some View { self.font(AppTypography.sectionLabel) }
    func appTitle() -> some View { self.font(AppTypography.title) }
    func appSecondary() -> some View { self.font(AppTypography.secondary) }
    func appMeta() -> some View { self.font(AppTypography.meta) }
}
