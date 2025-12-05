//
//  FaviconCache.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.12.25.
//


import SwiftUI

struct FaviconCache {
    static let refreshInterval: TimeInterval = 24 * 60 * 60 // 24h

    static func cacheURL(for feedURL: URL) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let hash = String(feedURL.absoluteString.hashValue)
        return caches.appendingPathComponent("favicon_\(hash).png")
    }

    static func cachedImage(for feedURL: URL) -> UIImage? {
        guard let url = cacheURL(for: feedURL),
              FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        if !needsRefresh(since: modificationDate, threshold: refreshInterval),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        return nil
    }

    static func store(data: Data, for feedURL: URL) {
        guard let url = cacheURL(for: feedURL) else { return }
        try? data.write(to: url)
    }

    static func needsRefresh(since date: Date, threshold: TimeInterval) -> Bool {
        return Date().timeIntervalSince(date) > threshold
    }

    static func downloadAndCacheFavicon(from feedURL: URL) async -> UIImage? {
        guard let faviconURL = FeedSource.faviconURL(for: feedURL) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: faviconURL)
            if let image = UIImage(data: data) {
                store(data: data, for: feedURL)
                return image
            }
        } catch {
            return nil
        }
        return nil
    }
}