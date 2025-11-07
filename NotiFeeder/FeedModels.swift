import Foundation

public struct FeedSource: Codable, Hashable, Identifiable {
    public var id: String { url }
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public struct FeedEntry: Identifiable, Hashable, Codable {
    public var id: String { link }
    public var title: String
    public var shortTitle: String
    public var link: String
    public var content: String
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
        self.imageURL = imageURL
        self.author = author
        self.sourceTitle = sourceTitle
        self.feedURL = feedURL
        self.pubDateString = pubDateString
        self.isRead = isRead
    }
}
