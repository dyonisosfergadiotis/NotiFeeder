import SwiftUI
import WidgetKit
import Foundation

struct UnreadArticleItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let feedTitle: String
    let date: Date
    let imageURL: URL?
    let link: String
}

struct UnreadArticlesEntry: TimelineEntry {
    let date: Date
    let items: [UnreadArticleItem]
    let accent: Color
    let isTinted: Bool
}

private struct FeedEntryCache: Codable {
    let title: String
    let link: String
    let content: String?
    let author: String?
    let sourceTitle: String?
    let feedURL: String?
    let pubDateString: String
    let imageURL: String?
    let isRead: Bool

    static func decode(from data: Data) -> [FeedEntryCache]? {
        let decoder = JSONDecoder()
        return try? decoder.decode([FeedEntryCache].self, from: data)
    }
}

private extension Date {
    /// Parses pubDateString with minimal logic (ISO8601 and RFC822)
    init?(rssDateString: String) {
        // Try ISO8601
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: rssDateString) {
            self = date
            return
        }
        // Try RFC822 formats
        let rfc822Formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm zzz",
            "dd MMM yyyy HH:mm zzz"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in rfc822Formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: rssDateString) {
                self = date
                return
            }
        }
        return nil
    }
}

private struct ArticleStore {
    // Minimal read state parser using UserDefaults (shared or standard)
    // Keys: "readArticles" stored as Set<String> stringified links
    static let suiteName = "group.notiFeeder"
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func isRead(link: String) -> Bool {
        if let shared = sharedDefaults, let readLinks = shared.array(forKey: "readArticles") as? [String] {
            return readLinks.contains(link)
        }
        if let standard = UserDefaults.standard.array(forKey: "readArticles") as? [String] {
            return standard.contains(link)
        }
        return false
    }
}

struct Provider: TimelineProvider {
    typealias Entry = UnreadArticlesEntry

    private let suiteName = "group.notiFeeder"

    func placeholder(in context: Context) -> UnreadArticlesEntry {
        let item1 = UnreadArticleItem(
            id: UUID(),
            title: "SwiftUI 3.0 Released",
            feedTitle: "Swift Blog",
            date: Date(),
            imageURL: nil,
            link: "https://swift.org/blog/swiftui-3"
        )
        let item2 = UnreadArticleItem(
            id: UUID(),
            title: "New Features in iOS 15",
            feedTitle: "Apple News",
            date: Date().addingTimeInterval(-3600),
            imageURL: nil,
            link: "https://apple.com/ios15/features"
        )
        return UnreadArticlesEntry(
            date: Date(),
            items: [item1, item2],
            accent: .accentColor,
            isTinted: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadArticlesEntry) -> Void) {
        let entry = loadEntry(for: context.family)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadArticlesEntry>) -> Void) {
        let entry = loadEntry(for: context.family)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadEntry(for family: WidgetFamily) -> UnreadArticlesEntry {
        let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults.standard

        var cachedEntries: [FeedEntryCache] = []
        if let data = defaults.data(forKey: "cachedEntries"), let decoded = FeedEntryCache.decode(from: data) {
            cachedEntries = decoded
        }

        let filteredEntries = cachedEntries.filter { feedEntry in
            !ArticleStore.isRead(link: feedEntry.link) && feedEntry.isRead == false
        }

        let sortedEntries = filteredEntries.sorted { lhs, rhs in
            let lhsDate = Date(rssDateString: lhs.pubDateString) ?? Date.distantPast
            let rhsDate = Date(rssDateString: rhs.pubDateString) ?? Date.distantPast
            return lhsDate > rhsDate
        }

        let maxCount: Int
        switch family {
        case .systemSmall:
            maxCount = 2
        case .systemMedium:
            maxCount = 2
        case .systemLarge:
            maxCount = 5
        default:
            maxCount = 2
        }

        let selectedEntries = sortedEntries.prefix(maxCount)

        // Determine accent color fallback: try bundle info dictionary or fallback to .accentColor
        var accentColor = Color.accentColor
        var isTinted = true

        if let infoDict = Bundle.main.infoDictionary {
            if let accentHex = infoDict["AccentColor"] as? String,
               let uiColor = UIColor(hexString: accentHex) {
                accentColor = Color(uiColor)
            }
        }

        // Build items
        let items: [UnreadArticleItem] = selectedEntries.enumerated().map { index, feedEntry in
            let date = Date(rssDateString: feedEntry.pubDateString) ?? Date()
            let url: URL?
            if family == .systemSmall {
                url = nil
            } else {
                if let imgStr = feedEntry.imageURL,
                   let u = URL(string: imgStr) {
                    url = u
                } else {
                    url = nil
                }
            }
            return UnreadArticleItem(
                id: UUID(),
                title: feedEntry.title,
                feedTitle: feedEntry.sourceTitle ?? "",
                date: date,
                imageURL: url,
                link: feedEntry.link
            )
        }

        return UnreadArticlesEntry(date: Date(), items: items, accent: accentColor, isTinted: isTinted)
    }
}

extension UIColor {
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex = String(hex.dropFirst())
        }
        guard hex.count == 6 || hex.count == 8 else {
            return nil
        }
        var int = UInt64()
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        if hex.count == 8 {
            a = (int & 0xff000000) >> 24
            r = (int & 0x00ff0000) >> 16
            g = (int & 0x0000ff00) >> 8
            b = int & 0x000000ff
        } else {
            a = 255
            r = (int & 0xff0000) >> 16
            g = (int & 0x00ff00) >> 8
            b = int & 0x0000ff
        }
        self.init(red: CGFloat(r) / 255,
                  green: CGFloat(g) / 255,
                  blue: CGFloat(b) / 255,
                  alpha: CGFloat(a) / 255)
    }
}

struct UnreadArticlesWidgetEntryView: View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
                .widgetAccentable()
                .containerBackground(for: .widget) {
                    entry.accent
                }
        case .systemMedium, .systemLarge:
            largerView
                .widgetAccentable()
                .containerBackground(for: .widget) {
                    entry.accent
                }
        default:
            smallView
                .widgetAccentable()
                .containerBackground(for: .widget) {
                    entry.accent
                }
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.items.prefix(2)) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.feedTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(item.date, format: .dateTime.hour().minute().month().day())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
    }

    private var largerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(entry.items.enumerated().map({ $0 }), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    if let imgURL = item.imageURL {
                        AsyncImage(url: imgURL) { phase in
                            switch phase {
                            case .empty:
                                Color.gray.opacity(0.3)
                                    .frame(width: 40, height: 40)
                                    .cornerRadius(6)
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 40, height: 40)
                                    .cornerRadius(6)
                                    .clipped()
                            case .failure(_):
                                Color.gray.opacity(0.3)
                                    .frame(width: 40, height: 40)
                                    .cornerRadius(6)
                            @unknown default:
                                Color.gray.opacity(0.3)
                                    .frame(width: 40, height: 40)
                                    .cornerRadius(6)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(index == 0 ? .headline : .subheadline)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text(item.feedTitle)
                            Text("•")
                            Text(item.date, format: .dateTime.hour().minute().month().day())
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Capsule()
                        .fill(entry.accent)
                        .frame(width: 3)
                }
            }
        }
        .padding(12)
    }
}

@main
struct UnreadArticlesWidget: Widget {
    let kind: String = "UnreadArticlesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            UnreadArticlesWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Ungelesen")
        .description("Zeigt ungelesene Artikel an")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct UnreadArticlesWidget_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            UnreadArticlesWidgetEntryView(entry: previewEntry(family: .systemSmall))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
            UnreadArticlesWidgetEntryView(entry: previewEntry(family: .systemMedium))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
            UnreadArticlesWidgetEntryView(entry: previewEntry(family: .systemLarge))
                .previewContext(WidgetPreviewContext(family: .systemLarge))
        }
    }

    static func previewEntry(family: WidgetFamily) -> UnreadArticlesEntry {
        let now = Date()
        let items: [UnreadArticleItem] = [
            UnreadArticleItem(
                id: UUID(),
                title: "Introducing Widgets in SwiftUI",
                feedTitle: "Swift Blog",
                date: now.addingTimeInterval(-3600),
                imageURL: family == .systemSmall ? nil : URL(string: "https://developer.apple.com/swiftui/images/swiftui-logo-430x430_2x.png"),
                link: "https://swift.org/blog/widgets"
            ),
            UnreadArticleItem(
                id: UUID(),
                title: "What's New in iOS 15",
                feedTitle: "Apple Newsroom",
                date: now.addingTimeInterval(-7200),
                imageURL: family == .systemSmall ? nil : URL(string: "https://developer.apple.com/news/images/ios15-logo-hero.jpg"),
                link: "https://apple.com/news/ios15"
            ),
            UnreadArticleItem(
                id: UUID(),
                title: "Combine Framework Deep Dive",
                feedTitle: "Swift Weekly",
                date: now.addingTimeInterval(-10800),
                imageURL: family == .systemSmall ? nil : URL(string: "https://swiftweekly.github.io/assets/swift-combine.png"),
                link: "https://swiftweekly.github.io/articles/combine"
            ),
            UnreadArticleItem(
                id: UUID(),
                title: "Async/Await in Swift Explained",
                feedTitle: "Swift by Sundell",
                date: now.addingTimeInterval(-14400),
                imageURL: family == .systemSmall ? nil : URL(string: "https://www.swiftbysundell.com/images/logo.png"),
                link: "https://swiftbysundell.com/articles/async-await-in-swift"
            ),
            UnreadArticleItem(
                id: UUID(),
                title: "Swift Package Manager Tips",
                feedTitle: "Swift Forums",
                date: now.addingTimeInterval(-18000),
                imageURL: family == .systemSmall ? nil : URL(string: "https://swift.org/assets/images/swift.svg"),
                link: "https://forums.swift.org/t/swift-package-manager-tips"
            )
        ]

        let accent = Color.accentColor
        return UnreadArticlesEntry(date: now, items: Array(items.prefix(family == .systemLarge ? 5 : 2)), accent: accent, isTinted: true)
    }
}
