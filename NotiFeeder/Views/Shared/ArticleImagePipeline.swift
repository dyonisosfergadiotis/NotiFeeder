import Foundation
import UIKit
import ImageIO

nonisolated private final class ArticleThumbnailMemoryCache: @unchecked Sendable {
    private let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 220
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private let lock = NSLock()
    private var missingUntil: [NSURL: Date] = [:]

    func image(for url: URL) -> UIImage? {
        images.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL, cost: Int) {
        let key = url as NSURL
        images.setObject(image, forKey: key, cost: cost)
        lock.withLock {
            missingUntil[key] = nil
        }
    }

    func isTemporarilyMissing(_ url: URL, now: Date = Date()) -> Bool {
        let key = url as NSURL
        return lock.withLock {
            guard let deadline = missingUntil[key] else { return false }
            if deadline > now {
                return true
            }
            missingUntil[key] = nil
            return false
        }
    }

    func recordTemporaryMiss(for url: URL, duration: TimeInterval) {
        let key = url as NSURL
        lock.withLock {
            missingUntil[key] = Date().addingTimeInterval(duration)
        }
    }
}

actor ArticleImagePipeline {
    static let shared = ArticleImagePipeline()

    private let session: URLSession
    nonisolated private let memoryCache = ArticleThumbnailMemoryCache()
    private var inFlightTasks: [NSURL: Task<UIImage?, Never>] = [:]
    private let temporaryMissDuration: TimeInterval = 3

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.urlCache = .shared
        self.session = URLSession(configuration: configuration)
    }

    nonisolated static func resolvedThumbnailURL(
        imageURL: String?,
        articleLink: String?
    ) -> URL? {
        guard let imageURL else { return nil }
        let trimmed = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard let articleLink,
              let articleURL = URL(string: articleLink) else {
            return URL(string: trimmed)
        }

        return URL(string: trimmed, relativeTo: articleURL)?.absoluteURL
    }

    nonisolated func cachedImage(for url: URL) -> UIImage? {
        memoryCache.image(for: url)
    }

    nonisolated func isTemporarilyMissing(_ url: URL) -> Bool {
        memoryCache.isTemporarilyMissing(url)
    }

    func thumbnailImage(
        for remoteURL: URL,
        maxPixelSize: CGFloat,
        priority: TaskPriority = .utility
    ) async -> UIImage? {
        if let cached = memoryCache.image(for: remoteURL) {
            return cached
        }
        guard !memoryCache.isTemporarilyMissing(remoteURL) else {
            return nil
        }

        let effectiveURL = OfflineArticleArchive.cachedAssetFileURL(for: remoteURL) ?? remoteURL
        guard let image = await image(for: effectiveURL, maxPixelSize: maxPixelSize, priority: priority) else {
            memoryCache.recordTemporaryMiss(for: remoteURL, duration: temporaryMissDuration)
            return nil
        }

        memoryCache.store(image, for: remoteURL, cost: Self.cacheCost(for: image))
        return image
    }

    func prefetchThumbnailImages(
        for remoteURLs: [URL],
        maxPixelSize: CGFloat
    ) async {
        let urls = Array(remoteURLs.prefix(12))
        guard !urls.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var iterator = urls.makeIterator()

            for _ in 0..<min(4, urls.count) {
                guard let remoteURL = iterator.next() else { break }
                group.addTask(priority: .utility) {
                    _ = await self.thumbnailImage(
                        for: remoteURL,
                        maxPixelSize: maxPixelSize,
                        priority: .utility
                    )
                }
            }

            while await group.next() != nil {
                guard !Task.isCancelled else { return }
                guard let remoteURL = iterator.next() else { continue }
                group.addTask(priority: .utility) {
                    _ = await self.thumbnailImage(
                        for: remoteURL,
                        maxPixelSize: maxPixelSize,
                        priority: .utility
                    )
                }
            }
        }
    }

    func image(
        for url: URL,
        maxPixelSize: CGFloat,
        priority: TaskPriority = .utility
    ) async -> UIImage? {
        let key = url as NSURL

        if let cached = memoryCache.image(for: url) {
            return cached
        }

        if let runningTask = inFlightTasks[key] {
            return await runningTask.value
        }

        let task = Task<UIImage?, Never>(priority: priority) {
            do {
                let data: Data
                if url.isFileURL {
                    data = try Data(contentsOf: url, options: [.mappedIfSafe])
                } else {
                    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
                    request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                    if let host = url.host {
                        request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
                    }
                    let (remoteData, _) = try await session.data(for: request)
                    data = remoteData
                }
                guard !Task.isCancelled else { return nil }
                return Self.downsampledImage(from: data, maxPixelSize: maxPixelSize)
            } catch {
                return nil
            }
        }

        inFlightTasks[key] = task
        let result = await task.value
        inFlightTasks[key] = nil

        if let result {
            memoryCache.store(result, for: url, cost: Self.cacheCost(for: result))
        }
        return result
    }

    nonisolated private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let cfData = data as CFData
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(cfData, sourceOptions) else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func cacheCost(for image: UIImage) -> Int {
        let pixelCount = image.size.width * image.size.height * image.scale * image.scale
        return Int(max(1, pixelCount) * 4)
    }
}
