import Foundation

struct WatchFeedSnapshot: Codable {
    let generatedAt: Date
    let lastRefreshDate: Date?
    let feeds: [WatchFeedSource]
    let entries: [WatchFeedEntry]
}

struct WatchFeedSource: Codable, Hashable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
}

struct WatchFeedEntry: Codable, Hashable, Identifiable {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var id: String { link }
    let title: String
    let shortTitle: String
    let link: String
    let content: String
    let sourceTitle: String?
    let feedURL: String?
    let pubDateString: String?
    let isRead: Bool
    let isBookmarked: Bool

    private enum CodingKeys: String, CodingKey {
        case title
        case shortTitle
        case link
        case content
        case sourceTitle
        case feedURL
        case pubDateString
        case isRead
        case isBookmarked
    }

    init(
        title: String,
        shortTitle: String,
        link: String,
        content: String,
        sourceTitle: String?,
        feedURL: String?,
        pubDateString: String?,
        isRead: Bool,
        isBookmarked: Bool
    ) {
        self.title = title
        self.shortTitle = shortTitle
        self.link = link
        self.content = content
        self.sourceTitle = sourceTitle
        self.feedURL = feedURL
        self.pubDateString = pubDateString
        self.isRead = isRead
        self.isBookmarked = isBookmarked
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        shortTitle = try container.decode(String.self, forKey: .shortTitle)
        link = try container.decode(String.self, forKey: .link)
        content = try container.decode(String.self, forKey: .content)
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        feedURL = try container.decodeIfPresent(String.self, forKey: .feedURL)
        pubDateString = try container.decodeIfPresent(String.self, forKey: .pubDateString)
        isRead = try container.decode(Bool.self, forKey: .isRead)
        isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
    }

    var displayTitle: String {
        let trimmed = shortTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    var sourceDisplayTitle: String {
        let trimmed = sourceTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Feed" : trimmed
    }

    var previewText: String {
        WatchHTML.strip(content)
    }

    var parsedDate: Date? {
        guard let pubDateString else { return nil }
        return WatchDateParser.parse(pubDateString)
    }

    var relativeDateText: String {
        guard let parsedDate else { return "" }
        return Self.relativeFormatter.localizedString(for: parsedDate, relativeTo: Date())
    }

    var isToday: Bool {
        guard let parsedDate else { return false }
        return Calendar.current.isDateInToday(parsedDate)
    }

    var watchPriority: Int {
        var score = 0
        if !isRead { score += 4 }
        if isBookmarked { score += 3 }
        if isToday { score += 2 }
        return score
    }

    func toggledBookmark() -> WatchFeedEntry {
        WatchFeedEntry(
            title: title,
            shortTitle: shortTitle,
            link: link,
            content: content,
            sourceTitle: sourceTitle,
            feedURL: feedURL,
            pubDateString: pubDateString,
            isRead: isRead,
            isBookmarked: !isBookmarked
        )
    }
}

enum WatchDateParser {
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

private enum WatchHTML {
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
