import Foundation
import UIKit

public struct FeedSource: Codable, Hashable, Identifiable {
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

    public var cachedFaviconURL: URL? {
        let fileName = "favicon_\(url.hashValue).ico"
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return caches?.appendingPathComponent(fileName)
    }

    public static func cachedFaviconURL(for feed: FeedSource) -> URL? {
        guard let cachedURL = feed.cachedFaviconURL else {
            return nil
        }
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        return nil
    }

    public static func downloadAndCacheFavicon(for feed: FeedSource) async -> UIImage? {
        guard let faviconURL = feed.faviconURL else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: faviconURL)
            guard let image = UIImage(data: data) else {
                return nil
            }
            if let cachedURL = feed.cachedFaviconURL {
                try? data.write(to: cachedURL)
            }
            return image
        } catch {
            return nil
        }
    }

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
