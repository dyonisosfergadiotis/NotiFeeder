// Widget entry point for unread articles
import WidgetKit
import SwiftUI
import Foundation

struct UnreadArticlesProvider: TimelineProvider {
    func placeholder(in context: Context) -> UnreadArticlesEntry {
        UnreadArticlesEntry(date: Date(), articles: UnreadArticlesEntry.placeholderArticles, accentColorHex: "#9CCFFF", configuration: UnreadArticlesIntent())
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadArticlesEntry) -> Void) {
        let entry = UnreadArticlesEntry(date: Date(), articles: UnreadArticlesEntry.placeholderArticles, accentColorHex: "#9CCFFF", configuration: UnreadArticlesIntent())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadArticlesEntry>) -> Void) {
        let articles = UnreadArticlesProvider.loadUnreadArticles(maxCount: 5)
        let accentColor = UnreadArticlesProvider.loadAccentHex()
        let entry = UnreadArticlesEntry(
            date: Date(),
            articles: articles,
            accentColorHex: accentColor,
            configuration: UnreadArticlesIntent()
        )
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900)))
        completion(timeline)
    }
    
    static func loadUnreadArticles(maxCount: Int) -> [FeedEntry] {
        // Try to load from UserDefaults (mirroring ArticleStore logic)
        guard let data = UserDefaults(suiteName: "group.dein.app.group")?.data(forKey: "cachedEntries"),
              let decoded = try? JSONDecoder().decode([FeedEntry].self, from: data) else {
            return UnreadArticlesEntry.placeholderArticles
        }
        return decoded.filter { !$0.isRead }.sorted { ($0.parsedPubDate ?? .distantPast) > ($1.parsedPubDate ?? .distantPast) }.prefix(maxCount).map { $0 }
    }
    static func loadAccentHex() -> String {
        UserDefaults(suiteName: "group.dein.app.group")?.string(forKey: "uiAccentHex") ?? "#9CCFFF"
    }
}

struct UnreadArticlesEntry: TimelineEntry {
    let date: Date
    let articles: [FeedEntry]
    let accentColorHex: String
    let configuration: UnreadArticlesIntent

    static let placeholderArticles: [FeedEntry] = [
        FeedEntry(title: "Neuer Apple Leak entdeckt", link: "https://apple.com/1", content: "", imageURL: nil, author: "Lisa", sourceTitle: "MacRumors", feedURL: nil, pubDateString: "2026-02-02T09:00:00Z"),
        FeedEntry(title: "iOS 20 kommt früher", link: "https://apple.com/2", content: "", imageURL: nil, author: "Jan", sourceTitle: "9to5Mac", feedURL: nil, pubDateString: "2026-02-02T08:00:00Z")
    ]
}

struct UnreadArticlesWidget: Widget {
    let kind: String = "UnreadArticlesWidget"

    var body: some WidgetConfiguration {
        IntentConfiguration(kind: kind, intent: UnreadArticlesIntent.self, provider: UnreadArticlesProvider()) { entry in
            UnreadArticlesWidgetView(entry: entry)
        }
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .configurationDisplayName("Ungelesene Artikel")
        .description("Zeigt die neuesten ungelesenen Artikel aus deinen Feeds.")
    }
}

struct UnreadArticlesWidgetView: View {
    var entry: UnreadArticlesEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let accent = Color.fromHex(entry.accentColorHex)
        ZStack {
            // Widget background adapts to light/dark/tinted
            if #available(iOS 17.0, *) {
                ContainerRelativeShape().fill(.background).opacity(0.96)
            } else {
                Color(.systemBackground)
            }
            VStack(spacing: 0) {
                let articles = entry.articles
                switch family {
                case .systemSmall:
                    UnreadArticlesListWidgetView(articles: Array(articles.prefix(2)), showImages: false, accent: accent)
                case .systemMedium:
                    UnreadArticlesListWidgetView(articles: Array(articles.prefix(2)), showImages: true, accent: accent)
                case .systemLarge:
                    UnreadArticlesListWidgetView(articles: Array(articles.prefix(5)), showImages: true, accent: accent)
                default:
                    EmptyView()
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 16)
        }
    }
}

struct UnreadArticlesListWidgetView: View {
    let articles: [FeedEntry]
    let showImages: Bool
    let accent: Color

    var body: some View {
        VStack(spacing: 12) {
            ForEach(articles, id: \.id) { article in
                UnreadArticleWidgetRow(entry: article, showImage: showImages, accent: accent)
            }
        }
    }
}
