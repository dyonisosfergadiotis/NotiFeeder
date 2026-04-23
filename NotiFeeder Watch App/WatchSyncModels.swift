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
