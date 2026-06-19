import Foundation

#if canImport(ActivityKit)
import ActivityKit

public struct ReadingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var updatedAt: Date
        public var readingProgress: Double
        public var thumbnailBlobKey: String?

        public init(
            updatedAt: Date = Date(),
            readingProgress: Double = 0,
            thumbnailBlobKey: String? = nil
        ) {
            self.updatedAt = updatedAt
            self.readingProgress = readingProgress
            self.thumbnailBlobKey = thumbnailBlobKey
        }
    }

    public var title: String
    public var sourceTitle: String
    public var link: String
    public var feedColorHex: String?
    public var feedURLString: String?
    public var faviconURLString: String?
    public var thumbnailURLString: String?
    public var readingTimeLabel: String
    public var publishedAt: Date?

    public init(
        title: String,
        sourceTitle: String,
        link: String,
        feedColorHex: String? = nil,
        feedURLString: String? = nil,
        faviconURLString: String? = nil,
        thumbnailURLString: String? = nil,
        readingTimeLabel: String = "1 Min.",
        publishedAt: Date? = nil
    ) {
        self.title = title
        self.sourceTitle = sourceTitle
        self.link = link
        self.feedColorHex = feedColorHex
        self.feedURLString = feedURLString
        self.faviconURLString = faviconURLString
        self.thumbnailURLString = thumbnailURLString
        self.readingTimeLabel = readingTimeLabel
        self.publishedAt = publishedAt
    }
}
#endif
