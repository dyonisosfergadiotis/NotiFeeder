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
                isRead: Bool = false) {
        self.title = title
        self.shortTitle = shortTitle ?? title
        self.link = link
        self.content = content
        self.contentRaw = contentRaw
        self.imageURL = imageURL
        self.author = author
        self.sourceTitle = sourceTitle
        self.feedURL = feedURL
        self.pubDateString = pubDateString
        self.isRead = isRead
    }

    public var parsedPubDate: Date? {
        let parsed = DateParser.parse(pubDateString)
        return parsed == .distantPast ? nil : parsed
    }

    // Nutzbarer Anzeige-Titel (shortTitle fällt zurück auf title)
    public var displayTitle: String {
        let t = shortTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? title : t
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
}
