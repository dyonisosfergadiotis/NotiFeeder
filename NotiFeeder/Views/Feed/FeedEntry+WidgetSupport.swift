import Foundation

// Make FeedEntry conform to everything WidgetKit needs (Codable, Hashable, Identifiable)
// If FeedEntry is already imported from the main app target, this ensures compatibility when compiled for the widget extension.
#if canImport(WidgetKit)
extension FeedEntry: Identifiable, Codable, Hashable { }
#endif
