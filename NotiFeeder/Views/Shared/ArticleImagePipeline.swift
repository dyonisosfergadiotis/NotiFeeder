import Foundation
import UIKit
import ImageIO

actor ArticleImagePipeline {
    static let shared = ArticleImagePipeline()

    private let session: URLSession
    private let memoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 220
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private var inFlightTasks: [NSURL: Task<UIImage?, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = .shared
        self.session = URLSession(configuration: configuration)
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = url as NSURL

        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        if let runningTask = inFlightTasks[key] {
            return await runningTask.value
        }

        let task = Task<UIImage?, Never> {
            do {
                let data: Data
                if url.isFileURL {
                    data = try Data(contentsOf: url, options: [.mappedIfSafe])
                } else {
                    let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 20)
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
            memoryCache.setObject(result, forKey: key, cost: Self.cacheCost(for: result))
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
