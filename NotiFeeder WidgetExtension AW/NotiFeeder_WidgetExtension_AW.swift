import WidgetKit
import SwiftUI
import AppIntents
import Foundation

private enum WatchComplicationStore {
    static let appGroupSuiteName = "group.notiFeeder"
    static let cachedSnapshotKey = "watch.cached.snapshot"

    static func defaults() -> UserDefaults {
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupSuiteName) != nil,
           let groupDefaults = UserDefaults(suiteName: appGroupSuiteName) {
            return groupDefaults
        }
        return .standard
    }
}

private struct WatchComplicationSnapshot: Codable {
    let generatedAt: Date
    let lastRefreshDate: Date?
    let entries: [WatchComplicationFeedEntry]
}

private struct WatchComplicationFeedEntry: Codable {
    let title: String
    let shortTitle: String
    let link: String
    let content: String
    let sourceTitle: String?
    let pubDateString: String?
    let isRead: Bool

    var displayTitle: String {
        let trimmed = shortTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    var sourceDisplayTitle: String {
        let trimmed = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "NotiFeeder" : trimmed
    }

    var parsedDate: Date {
        guard let pubDateString,
              let parsed = WatchComplicationDateParser.parse(pubDateString) else {
            return .distantPast
        }
        return parsed
    }
}

struct WatchComplicationArticle {
    let title: String
    let preview: String
    let feedTitle: String
    let link: String
    let date: Date
    let isUnread: Bool
    let feedColor: Color
}

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let article: WatchComplicationArticle?
}

private enum WatchComplicationLoader {
    static func loadArticle() -> WatchComplicationArticle? {
        let defaults = WatchComplicationStore.defaults()
        guard let data = defaults.data(forKey: WatchComplicationStore.cachedSnapshotKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let snapshot = try? decoder.decode(WatchComplicationSnapshot.self, from: data),
              !snapshot.entries.isEmpty else {
            return nil
        }

        let sortedEntries = snapshot.entries.sorted { lhs, rhs in
            lhs.parsedDate > rhs.parsedDate
        }

        guard let selected = sortedEntries.first(where: { !$0.isRead }) ?? sortedEntries.first else {
            return nil
        }

        let rawPreview = WatchComplicationHTML.strip(selected.content)
        let preview: String
        if rawPreview.isEmpty {
            if let host = URL(string: selected.link)?.host, !host.isEmpty {
                preview = host
            } else {
                preview = "Zum Lesen öffnen"
            }
        } else {
            preview = rawPreview
        }

        let date = selected.parsedDate == .distantPast ? Date() : selected.parsedDate
        let feedTitle = selected.sourceDisplayTitle

        return WatchComplicationArticle(
            title: selected.displayTitle,
            preview: preview,
            feedTitle: feedTitle,
            link: selected.link,
            date: date,
            isUnread: !selected.isRead,
            feedColor: FeedTintPalette.color(for: feedTitle)
        )
    }
}

struct WatchComplicationProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: Date(), article: previewArticle)
    }

    func snapshot(for configuration: WatchComplicationConfigurationIntent, in context: Context) async -> WatchComplicationEntry {
        WatchComplicationEntry(date: Date(), article: WatchComplicationLoader.loadArticle() ?? previewArticle)
    }

    func timeline(for configuration: WatchComplicationConfigurationIntent, in context: Context) async -> Timeline<WatchComplicationEntry> {
        let entry = WatchComplicationEntry(date: Date(), article: WatchComplicationLoader.loadArticle())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    func recommendations() -> [AppIntentRecommendation<WatchComplicationConfigurationIntent>] {
        [
            AppIntentRecommendation(
                intent: WatchComplicationConfigurationIntent(),
                description: "Neuester Artikel"
            )
        ]
    }

    private var previewArticle: WatchComplicationArticle {
        WatchComplicationArticle(
            title: "Neuer Artikel: Fokus im RSS-Workflow",
            preview: "Kurze Tipps fuer bessere Priorisierung im Feed.",
            feedTitle: "NotiFeeder",
            link: "https://example.com/notifeeder",
            date: Date().addingTimeInterval(-900),
            isUnread: true,
            feedColor: FeedTintPalette.color(for: "NotiFeeder")
        )
    }
}

struct NotiFeeder_WidgetExtension_AWEntryView: View {
    var entry: WatchComplicationEntry

    var body: some View {
        Group {
            if let article = entry.article {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(article.feedTitle)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 4)

                        HStack(spacing: 3) {
                            Image(systemName: article.isUnread ? "rays" : "eye.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(article.isUnread ? article.feedColor : .secondary)
                                .widgetAccentable()

                            Text(dateLabel(for: article.date))
                                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Text(article.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)

                    Text(article.preview)
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.secondary)
                }
                .widgetURL(articleDeepLink(for: article.link))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NotiFeeder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Keine Artikel")
                        .font(.system(size: 13, weight: .semibold))

                    Text("Watch-App kurz öffnen, um zu synchronisieren.")
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func articleDeepLink(for link: String) -> URL? {
        guard !link.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "notifeeder"
        components.host = "article"
        components.queryItems = [URLQueryItem(name: "link", value: link)]
        return components.url
    }

    private func dateLabel(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_DE")))
        }
        return DateFormatter.dayMonth.string(from: date)
    }
}

struct NotiFeeder_WidgetExtension_AW: Widget {
    static let kind = "NotiFeeder_WidgetExtension_AW_Rectangular"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind,
            intent: WatchComplicationConfigurationIntent.self,
            provider: WatchComplicationProvider()
        ) { entry in
            NotiFeeder_WidgetExtension_AWEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("NotiFeeder (Watch)")
        .description("Zeigt den neuesten Artikel als rechteckige Watch-Complication.")
        .supportedFamilies([.accessoryRectangular])
    }
}

private enum WatchComplicationDateParser {
    private static let isoFormatter: ISO8601DateFormatter = {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso
    }()

    private static let formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        ]

        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
    }()

    static func parse(_ value: String) -> Date? {
        for formatter in formatters {
            if let parsed = formatter.date(from: value) {
                return parsed
            }
        }

        return isoFormatter.date(from: value)
    }
}

private enum WatchComplicationHTML {
    static func strip(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withoutTags = trimmed.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decodedEntities = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return normalize(decodedEntities)
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum FeedTintPalette {
    private static let colors: [Color] = [
        Color(red: 0.97, green: 0.74, blue: 0.80),
        Color(red: 0.99, green: 0.82, blue: 0.67),
        Color(red: 0.98, green: 0.90, blue: 0.61),
        Color(red: 0.77, green: 0.93, blue: 0.74),
        Color(red: 0.73, green: 0.90, blue: 0.96),
        Color(red: 0.78, green: 0.85, blue: 0.99)
    ]

    static func color(for key: String) -> Color {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return colors[0] }
        let index = abs(normalized.hashValue) % colors.count
        return colors[index]
    }
}

private extension DateFormatter {
    static let dayMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM"
        return formatter
    }()
}

#Preview(as: .accessoryRectangular) {
    NotiFeeder_WidgetExtension_AW()
} timeline: {
    WatchComplicationEntry(
        date: Date(),
        article: WatchComplicationArticle(
            title: "Neuer Artikel: Fokus im RSS-Workflow",
            preview: "Kurze Tipps fuer bessere Priorisierung im Feed.",
            feedTitle: "NotiFeeder",
            link: "https://example.com/notifeeder",
            date: Date().addingTimeInterval(-900),
            isUnread: true,
            feedColor: FeedTintPalette.color(for: "NotiFeeder")
        )
    )
}
