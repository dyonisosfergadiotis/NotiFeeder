import Foundation

#if canImport(ActivityKit)
import ActivityKit
import CryptoKit
import OSLog
import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class ReadingLiveActivityManager {
    static let shared = ReadingLiveActivityManager()

    private static let persistedProgressKey = "nf_reading_progress_by_article_v1"

    private var activity: Activity<ReadingActivityAttributes>?
    private var lastProgressUpdateTime: TimeInterval = 0
    private var lastReadingProgress: Double = -1
    private var persistedProgressByArticleID: [String: Double]
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]

    private init() {
        persistedProgressByArticleID = FeedStorage.defaults
            .dictionary(forKey: Self.persistedProgressKey)?
            .compactMapValues { value in
                if let number = value as? NSNumber {
                    return number.doubleValue
                }
                return value as? Double
            } ?? [:]
    }

    func startOrUpdate(entry: FeedEntry, feedColor: Color) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let thumbnailURL = ArticleImagePipeline.resolvedThumbnailURL(
            imageURL: entry.imageURL,
            articleLink: entry.link
        )
        let initialThumbnailBlobKey = cachedThumbnailBlobKey(for: thumbnailURL, articleLink: entry.link)
        let attributes = ReadingActivityAttributes(
            title: entry.displayTitle,
            sourceTitle: entry.sourceTitle ?? "Feed",
            link: entry.link,
            feedColorHex: feedColor.hexString,
            feedURLString: entry.feedURL,
            faviconURLString: faviconURLString(for: entry.feedURL),
            thumbnailURLString: thumbnailURL?.absoluteString,
            readingTimeLabel: readingTimeLabel(for: entry),
            publishedAt: entry.parsedPubDate
        )
        let state = ReadingActivityAttributes.ContentState(
            updatedAt: Date(),
            readingProgress: currentProgress(for: entry.link),
            thumbnailBlobKey: initialThumbnailBlobKey
        )

        if activity == nil {
            activity = Activity<ReadingActivityAttributes>.activities.first {
                $0.attributes.link == entry.link
            }
        }

        if let activity {
            if activity.attributes.link == entry.link {
                Task {
                    await activity.update(ActivityContent(state: state, staleDate: nil))
                }
                updateThumbnailIfNeeded(
                    for: activity,
                    thumbnailURL: thumbnailURL,
                    articleLink: entry.link
                )
                return
            }
            end()
        }

        endExistingActivities(except: entry.link)

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            if let activity {
                updateThumbnailIfNeeded(
                    for: activity,
                    thumbnailURL: thumbnailURL,
                    articleLink: entry.link
                )
            }
        } catch {
            AppLogger.app.debug("Unable to start reading Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    func updateReadingProgress(_ progress: Double, for link: String) {
        let clamped = min(1, max(0, progress))
        persistReadingProgress(clamped, for: link)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let now = CACurrentMediaTime()
        guard abs(clamped - lastReadingProgress) >= 0.015 || now - lastProgressUpdateTime >= 2.5 else {
            return
        }
        lastProgressUpdateTime = now
        lastReadingProgress = clamped

        if activity == nil {
            activity = Activity<ReadingActivityAttributes>.activities.first {
                $0.attributes.link == link
            }
        }
        guard let activity, activity.attributes.link == link else { return }

        let state = ReadingActivityAttributes.ContentState(
            updatedAt: Date(),
            readingProgress: clamped,
            thumbnailBlobKey: activity.content.state.thumbnailBlobKey
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func currentReadingProgress(for link: String) -> Double {
        currentProgress(for: link)
    }

    func end() {
        guard let activity else {
            endExistingActivities()
            return
        }
        self.activity = nil
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        lastProgressUpdateTime = 0
        lastReadingProgress = -1
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func endExistingActivities(except keptLink: String? = nil) {
        let activities = Activity<ReadingActivityAttributes>.activities.filter {
            $0.attributes.link != keptLink
        }
        guard !activities.isEmpty else { return }
        Task {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func currentProgress(for link: String) -> Double {
        guard activity?.attributes.link == link else {
            return persistedProgressByArticleID[link] ?? 0
        }
        return activity?.content.state.readingProgress ?? max(0, lastReadingProgress)
    }

    private func persistReadingProgress(_ progress: Double, for link: String) {
        guard !link.isEmpty else { return }

        let previous = persistedProgressByArticleID[link] ?? 0
        let shouldPersist = abs(progress - previous) >= 0.01
            || (progress <= 0.001 && previous > 0)
            || (progress >= 0.999 && previous < 1)
        guard shouldPersist else { return }

        persistedProgressByArticleID[link] = progress
        FeedStorage.defaults.set(persistedProgressByArticleID, forKey: Self.persistedProgressKey)
    }

    private func updateThumbnailIfNeeded(
        for activity: Activity<ReadingActivityAttributes>,
        thumbnailURL: URL?,
        articleLink: String
    ) {
        guard activity.content.state.thumbnailBlobKey == nil,
              let thumbnailURL else {
            return
        }
        guard thumbnailTasks[articleLink] == nil else { return }

        thumbnailTasks[articleLink] = Task { [weak self] in
            let image = await ArticleImagePipeline.shared.thumbnailImage(
                for: thumbnailURL,
                maxPixelSize: 360,
                priority: .userInitiated
            )
            guard !Task.isCancelled,
                  let image,
                  let thumbnailBlobKey = Self.writeThumbnailBlob(image, articleLink: articleLink) else {
                await MainActor.run {
                    self?.thumbnailTasks[articleLink] = nil
                }
                return
            }

            var state = activity.content.state
            state.updatedAt = Date()
            state.thumbnailBlobKey = thumbnailBlobKey
            await activity.update(ActivityContent(state: state, staleDate: nil))

            await MainActor.run {
                self?.thumbnailTasks[articleLink] = nil
            }
        }
    }

    private func cachedThumbnailBlobKey(for thumbnailURL: URL?, articleLink: String) -> String? {
        guard let thumbnailURL,
              let image = ArticleImagePipeline.shared.cachedImage(for: thumbnailURL) else {
            return nil
        }
        return Self.writeThumbnailBlob(image, articleLink: articleLink)
    }

    private static func writeThumbnailBlob(_ image: UIImage, articleLink: String) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.82) ?? image.pngData() else {
            return nil
        }
        let key = "readingActivityThumbnail-\(stableHash(for: articleLink))"
        AppGroupBlobStore.write(data, forKey: key)
        return key
    }

    private static func stableHash(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func faviconURLString(for feedURLString: String?) -> String? {
        guard
            let feedURLString,
            let feedURL = URL(string: feedURLString),
            let host = feedURL.host
        else {
            return nil
        }
        return URL(string: "https://\(host)/favicon.ico")?.absoluteString
    }

    private func readingTimeLabel(for entry: FeedEntry) -> String {
        let source = (entry.contentRaw?.isEmpty == false) ? entry.contentRaw! : entry.content
        let plainText = HTMLText.stripHTML(source)
        let wordCount = plainText.split { $0.isWhitespace || $0.isNewline }.count
        let imageCount = countImages(in: source)
        let wordsPerMinute = 210.0
        let textMinutes = Double(wordCount) / wordsPerMinute
        let imageMinutes = min(Double(imageCount) * 12.0 / 60.0, 1.0)
        let minutes = max(1, Int(ceil(textMinutes + imageMinutes)))
        return "\(minutes) Min."
    }

    private func countImages(in html: String) -> Int {
        let pattern = "<img\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.numberOfMatches(in: html, options: [], range: range)
    }
}

private extension Color {
    var hexString: String? {
        guard let components = rgbComponents else { return nil }
        return String(
            format: "#%02X%02X%02X",
            components.red,
            components.green,
            components.blue
        )
    }
}
#else
@MainActor
final class ReadingLiveActivityManager {
    static let shared = ReadingLiveActivityManager()

    private init() {}

    func startOrUpdate(entry: FeedEntry, feedColor: Any) {}
    func updateReadingProgress(_ progress: Double, for link: String) {}
    func currentReadingProgress(for link: String) -> Double { 0 }
    func end() {}
}
#endif
