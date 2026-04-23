import Foundation

nonisolated public struct FeedSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String { url }
    public var title: String
    public var url: String
    
    public var faviconURL: URL? {
        guard let url = URL(string: self.url), let host = url.host else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }

    static func faviconURL(for feedURL: URL) -> URL? {
        guard let host = feedURL.host else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

nonisolated public struct FeedEntry: Identifiable, Hashable, Codable, Sendable {
    public var id: String { link }
    public var title: String
    public var shortTitle: String
    public var link: String
    public var content: String
    public var contentRaw: String?
    public var imageURL: String?
    public var author: String?
    public var sourceTitle: String?
    public var feedURL: String?
    public var pubDateString: String?
    public var isRead: Bool = false
    public var isNew: Bool = false

    public init(title: String,
                shortTitle: String? = nil,
                link: String,
                content: String,
                contentRaw: String? = nil,
                imageURL: String? = nil,
                author: String? = nil,
                sourceTitle: String? = nil,
                feedURL: String? = nil,
                pubDateString: String? = nil,
                isRead: Bool = false,
                isNew: Bool = false) {
        let normalizedTitle = Self.normalizedPlainText(title)
        self.title = normalizedTitle
        self.shortTitle = Self.normalizedPlainText(shortTitle ?? normalizedTitle)
        self.link = link
        self.content = Self.normalizedPlainText(content)
        self.contentRaw = Self.normalizedHTML(contentRaw)
        self.imageURL = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.author = author.map(Self.normalizedPlainText)
        self.sourceTitle = sourceTitle.map(Self.normalizedPlainText)
        self.feedURL = feedURL
        self.pubDateString = pubDateString
        self.isRead = isRead
        self.isNew = isNew
    }

    public var parsedPubDate: Date? {
        let parsed = DateParser.parse(pubDateString)
        return parsed == .distantPast ? nil : parsed
    }

    // Nutzbarer Anzeige-Titel (voller Titel bevorzugt, shortTitle nur als Fallback)
    public var displayTitle: String {
        let full = Self.sanitizedTitle(title)
        if !full.isEmpty {
            return full
        }

        let short = Self.sanitizedTitle(shortTitle)
        if !short.isEmpty {
            return short
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Deep link for widgets and external launches.
    public var deepLinkURL: URL? {
        var components = URLComponents()
        components.scheme = "notifeeder"
        components.host = "article"
        components.queryItems = [
            URLQueryItem(name: "link", value: link)
        ]
        return components.url
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case shortTitle
        case link
        case content
        case contentRaw
        case imageURL
        case author
        case sourceTitle
        case feedURL
        case pubDateString
        case isRead
        case isNew
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedTitle = try container.decode(String.self, forKey: .title)
        title = Self.normalizedPlainText(decodedTitle)
        shortTitle = Self.normalizedPlainText(try container.decodeIfPresent(String.self, forKey: .shortTitle) ?? title)
        link = try container.decode(String.self, forKey: .link)
        content = Self.normalizedPlainText(try container.decodeIfPresent(String.self, forKey: .content) ?? "")
        contentRaw = Self.normalizedHTML(try container.decodeIfPresent(String.self, forKey: .contentRaw))
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)?.trimmingCharacters(in: .whitespacesAndNewlines)
        author = try container.decodeIfPresent(String.self, forKey: .author).map(Self.normalizedPlainText)
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle).map(Self.normalizedPlainText)
        feedURL = try container.decodeIfPresent(String.self, forKey: .feedURL)
        pubDateString = try container.decodeIfPresent(String.self, forKey: .pubDateString)
        let decodedIsRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isRead = decodedIsRead
        let decodedIsNew = try container.decodeIfPresent(Bool.self, forKey: .isNew) ?? !decodedIsRead
        isNew = decodedIsRead ? false : decodedIsNew
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(shortTitle, forKey: .shortTitle)
        try container.encode(link, forKey: .link)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(contentRaw, forKey: .contentRaw)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(sourceTitle, forKey: .sourceTitle)
        try container.encodeIfPresent(feedURL, forKey: .feedURL)
        try container.encodeIfPresent(pubDateString, forKey: .pubDateString)
        try container.encode(isRead, forKey: .isRead)
        try container.encode(isNew, forKey: .isNew)
    }

    private static func sanitizedTitle(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        result = result.replacingOccurrences(
            of: "(?i)apple\\s*intelligence\\s*[:\\-–—|]?\\s*titel\\s*zusammenfassen",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?i)\\btitel\\s*zusammenfassen\\b",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ":-–—|"))
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedPlainText(_ raw: String) -> String {
        HTMLText.normalizePreviewSpacing(in: raw)
    }

    private static func normalizedHTML(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return HTMLText.normalizeHTMLContent(trimmed)
    }
}
