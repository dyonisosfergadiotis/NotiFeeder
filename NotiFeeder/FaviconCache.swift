//
//  FaviconCache.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.12.25.
//


import SwiftUI
import CryptoKit

struct FaviconCache {
    static let refreshInterval: TimeInterval = 24 * 60 * 60 // 24h

    static func cacheURL(for feedURL: URL) -> URL? {
        guard let directory = iconCacheDirectory() else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(stableCacheKey(for: feedURL)).png")
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

    static func cachedImageAllowingStale(for feedURL: URL) -> UIImage? {
        guard let url = cacheURL(for: feedURL),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    static func cachedModificationDate(for feedURL: URL) -> Date? {
        guard let url = cacheURL(for: feedURL),
              FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return modificationDate
    }

    static func store(data: Data, for feedURL: URL) {
        guard let url = cacheURL(for: feedURL) else { return }
        try? data.write(to: url, options: [.atomic])
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

    static func prefetchFavicon(for feedURLString: String) {
        guard let feedURL = URL(string: feedURLString) else { return }
        if cachedImageAllowingStale(for: feedURL) != nil { return }

        Task.detached(priority: .utility) {
            _ = await downloadAndCacheFavicon(from: feedURL)
        }
    }

    private static func iconCacheDirectory() -> URL? {
        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return baseDirectory?
            .appendingPathComponent("NotiFeeder", isDirectory: true)
            .appendingPathComponent("FeedIcons", isDirectory: true)
    }

    private static func stableCacheKey(for feedURL: URL) -> String {
        let normalized = normalizedFeedURLString(feedURL)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedFeedURLString(_ feedURL: URL) -> String {
        var components = URLComponents(url: feedURL, resolvingAgainstBaseURL: false)
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        return components?.string ?? feedURL.absoluteString.lowercased()
    }
}
