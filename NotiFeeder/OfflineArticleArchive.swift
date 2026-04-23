import Foundation
import CryptoKit
import OSLog

enum OfflineArticleArchive {
    nonisolated static let preloader = OfflineArticlePreloader()

    nonisolated private static let archiveDirectoryName = "OfflineArticleArchive"
    nonisolated private static let assetsDirectoryName = "assets"
    nonisolated private static let articlesDirectoryName = "articles"
    nonisolated private static let mediaAttributeRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(src|poster)\s*=\s*(["'])([^"']+)\2"#,
        options: []
    )
    nonisolated private static let hrefAttributeRegex = try? NSRegularExpression(
        pattern: #"(?i)\bhref\s*=\s*(["'])([^"']+)\1"#,
        options: []
    )
    nonisolated private static let srcsetAttributeRegex = try? NSRegularExpression(
        pattern: #"(?i)\bsrcset\s*=\s*(["'])([^"']+)\1"#,
        options: []
    )

    nonisolated static func readAccessURL() -> URL? {
        rootDirectoryURL
    }

    nonisolated static func articleHTMLFileURL(forArticleLink articleLink: String) -> URL? {
        guard let articlesDirectoryURL else { return nil }
        return articlesDirectoryURL
            .appendingPathComponent(articleStorageFileName(for: articleLink))
            .appendingPathExtension("html")
    }

    nonisolated static func cachedAssetFileURL(for remoteURL: URL) -> URL? {
        if remoteURL.isFileURL {
            return FileManager.default.fileExists(atPath: remoteURL.path) ? remoteURL : nil
        }

        guard let fileURL = assetFileURL(for: remoteURL),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return fileURL
    }

    nonisolated static func prepareOfflineHTMLDocument(
        forArticleLink articleLink: String,
        articleURL: URL?,
        htmlDocument: String
    ) -> URL? {
        guard let fileURL = articleHTMLFileURL(forArticleLink: articleLink),
              let articlesDirectoryURL else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: articlesDirectoryURL, withIntermediateDirectories: true)
            let rewritten = rewriteDocumentForLocalRendering(htmlDocument, relativeTo: articleURL)
            try rewritten.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            AppLogger.persistence.warning("Failed to prepare offline article HTML for \(articleLink, privacy: .public)")
            return nil
        }
    }

    nonisolated static func mediaURLs(for entry: FeedEntry) -> [URL] {
        let articleURL = URL(string: entry.link)
        var collected: [URL] = []

        if let rawImageURL = entry.imageURL,
           let resolvedImageURL = resolveMediaReference(rawImageURL, relativeTo: articleURL) {
            collected.append(resolvedImageURL)
        }

        if let rawHTML = entry.contentRaw, !rawHTML.isEmpty {
            collected.append(contentsOf: mediaURLs(in: rawHTML, relativeTo: articleURL))
        }

        return deduplicatedURLs(collected)
    }

    nonisolated static func uniqueMediaURLs(for entries: [FeedEntry]) -> [URL] {
        deduplicatedURLs(entries.flatMap(mediaURLs(for:)))
    }

    nonisolated fileprivate static func assetStorageKey(for remoteURL: URL) -> String {
        assetFileName(for: remoteURL)
    }

    nonisolated fileprivate static func articleStorageFileName(for articleLink: String) -> String {
        stableHash(for: articleLink)
    }

    nonisolated fileprivate static func assetFileURL(for remoteURL: URL) -> URL? {
        guard let assetsDirectoryURL else { return nil }
        return assetsDirectoryURL.appendingPathComponent(assetFileName(for: remoteURL))
    }

    nonisolated private static var rootDirectoryURL: URL? {
        guard let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let url = applicationSupportURL.appendingPathComponent(archiveDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            AppLogger.persistence.warning("Failed to create offline archive root directory")
            return nil
        }
    }

    nonisolated private static var assetsDirectoryURL: URL? {
        guard let rootDirectoryURL else { return nil }
        let url = rootDirectoryURL.appendingPathComponent(assetsDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            AppLogger.persistence.warning("Failed to create offline asset directory")
            return nil
        }
    }

    nonisolated private static var articlesDirectoryURL: URL? {
        guard let rootDirectoryURL else { return nil }
        let url = rootDirectoryURL.appendingPathComponent(articlesDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            AppLogger.persistence.warning("Failed to create offline article directory")
            return nil
        }
    }

    nonisolated private static func stableHash(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func assetFileName(for remoteURL: URL) -> String {
        let canonicalURL = normalizedRemoteURL(remoteURL)
        let hash = stableHash(for: canonicalURL.absoluteString)
        let fileExtension = canonicalURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fileExtension.isEmpty else { return hash }
        return "\(hash).\(fileExtension.lowercased())"
    }

    nonisolated private static func normalizedRemoteURL(_ remoteURL: URL) -> URL {
        guard var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false) else {
            return remoteURL
        }
        if let host = components.host {
            components.host = host.lowercased()
        }
        if components.scheme?.isEmpty == true {
            components.scheme = "https"
        }
        return components.url ?? remoteURL
    }

    nonisolated private static func mediaURLs(in html: String, relativeTo articleURL: URL?) -> [URL] {
        var collected: [URL] = []

        if let mediaAttributeRegex {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = mediaAttributeRegex.matches(in: html, options: [], range: range)
            for match in matches {
                guard match.numberOfRanges >= 4,
                      let valueRange = Range(match.range(at: 3), in: html),
                      let resolvedURL = resolveMediaReference(String(html[valueRange]), relativeTo: articleURL) else {
                    continue
                }
                collected.append(resolvedURL)
            }
        }

        if let srcsetAttributeRegex {
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = srcsetAttributeRegex.matches(in: html, options: [], range: range)
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let valueRange = Range(match.range(at: 2), in: html) else {
                    continue
                }
                collected.append(contentsOf: mediaURLs(inSrcset: String(html[valueRange]), relativeTo: articleURL))
            }
        }

        return deduplicatedURLs(collected)
    }

    nonisolated private static func mediaURLs(inSrcset srcset: String, relativeTo articleURL: URL?) -> [URL] {
        srcset
            .split(separator: ",")
            .compactMap { candidate -> URL? in
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let components = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                guard let rawURL = components.first else { return nil }
                return resolveMediaReference(String(rawURL), relativeTo: articleURL)
            }
    }

    nonisolated private static func rewriteDocumentForLocalRendering(_ html: String, relativeTo articleURL: URL?) -> String {
        var rewritten = rewriteSrcsetAttributes(in: html, relativeTo: articleURL)
        rewritten = rewriteMediaAttributes(in: rewritten, relativeTo: articleURL)
        rewritten = rewriteHrefAttributes(in: rewritten, relativeTo: articleURL)
        return rewritten
    }

    nonisolated private static func rewriteMediaAttributes(in html: String, relativeTo articleURL: URL?) -> String {
        guard let mediaAttributeRegex else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = mediaAttributeRegex.matches(in: html, options: [], range: range)
        guard !matches.isEmpty else { return html }

        var rewritten = html
        for match in matches.reversed() {
            guard match.numberOfRanges >= 4,
                  let fullRange = Range(match.range(at: 0), in: rewritten),
                  let attributeNameRange = Range(match.range(at: 1), in: rewritten),
                  let quoteRange = Range(match.range(at: 2), in: rewritten),
                  let valueRange = Range(match.range(at: 3), in: rewritten) else {
                continue
            }

            let attributeName = String(rewritten[attributeNameRange])
            let quote = String(rewritten[quoteRange])
            let rawValue = String(rewritten[valueRange])

            guard let replacementValue = resolvedMediaReferenceString(for: rawValue, relativeTo: articleURL) else {
                continue
            }

            let replacement = "\(attributeName)=\(quote)\(replacementValue)\(quote)"
            rewritten.replaceSubrange(fullRange, with: replacement)
        }

        return rewritten
    }

    nonisolated private static func rewriteHrefAttributes(in html: String, relativeTo articleURL: URL?) -> String {
        guard let hrefAttributeRegex else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = hrefAttributeRegex.matches(in: html, options: [], range: range)
        guard !matches.isEmpty else { return html }

        var rewritten = html
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range(at: 0), in: rewritten),
                  let quoteRange = Range(match.range(at: 1), in: rewritten),
                  let valueRange = Range(match.range(at: 2), in: rewritten) else {
                continue
            }

            let quote = String(rewritten[quoteRange])
            let rawValue = String(rewritten[valueRange])
            guard let replacementValue = absolutizedReferenceString(for: rawValue, relativeTo: articleURL) else {
                continue
            }

            let replacement = "href=\(quote)\(replacementValue)\(quote)"
            rewritten.replaceSubrange(fullRange, with: replacement)
        }

        return rewritten
    }

    nonisolated private static func rewriteSrcsetAttributes(in html: String, relativeTo articleURL: URL?) -> String {
        guard let srcsetAttributeRegex else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = srcsetAttributeRegex.matches(in: html, options: [], range: range)
        guard !matches.isEmpty else { return html }

        var rewritten = html
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let fullRange = Range(match.range(at: 0), in: rewritten),
                  let quoteRange = Range(match.range(at: 1), in: rewritten),
                  let valueRange = Range(match.range(at: 2), in: rewritten) else {
                continue
            }

            let quote = String(rewritten[quoteRange])
            let rawValue = String(rewritten[valueRange])
            let replacementValue = rawValue
                .split(separator: ",")
                .map { candidate -> String in
                    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return "" }

                    let components = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                    let rawURL = components.first.map(String.init) ?? trimmed
                    let descriptor = components.count > 1 ? String(components[1]) : ""
                    let resolvedURL = resolvedMediaReferenceString(for: rawURL, relativeTo: articleURL) ?? rawURL

                    guard !descriptor.isEmpty else { return resolvedURL }
                    return "\(resolvedURL) \(descriptor)"
                }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")

            let replacement = "srcset=\(quote)\(replacementValue)\(quote)"
            rewritten.replaceSubrange(fullRange, with: replacement)
        }

        return rewritten
    }

    nonisolated private static func resolvedMediaReferenceString(for rawValue: String, relativeTo articleURL: URL?) -> String? {
        guard let resolvedURL = resolveMediaReference(rawValue, relativeTo: articleURL) else {
            return absolutizedReferenceString(for: rawValue, relativeTo: articleURL)
        }

        if let cachedAssetURL = cachedAssetFileURL(for: resolvedURL) {
            return "../\(assetsDirectoryName)/\(cachedAssetURL.lastPathComponent)"
        }

        return resolvedURL.absoluteString
    }

    nonisolated private static func absolutizedReferenceString(for rawValue: String, relativeTo articleURL: URL?) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("data:"),
              !trimmed.hasPrefix("blob:"),
              !trimmed.hasPrefix("about:") else {
            return trimmed
        }

        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute.absoluteString
        }

        guard let articleURL else { return trimmed }
        return URL(string: trimmed, relativeTo: articleURL)?.absoluteURL.absoluteString ?? trimmed
    }

    nonisolated private static func resolveMediaReference(_ rawValue: String, relativeTo articleURL: URL?) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("data:"),
              !trimmed.hasPrefix("blob:"),
              !trimmed.hasPrefix("javascript:"),
              !trimmed.hasPrefix("mailto:"),
              !trimmed.hasPrefix("tel:"),
              !trimmed.hasPrefix("about:") else {
            return nil
        }

        let candidate: URL?
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            candidate = absolute
        } else if let articleURL {
            candidate = URL(string: trimmed, relativeTo: articleURL)?.absoluteURL
        } else {
            candidate = URL(string: trimmed)
        }

        guard let resolvedURL = candidate else { return nil }

        if resolvedURL.isFileURL {
            return resolvedURL
        }

        guard let scheme = resolvedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return normalizedRemoteURL(resolvedURL)
    }

    nonisolated private static func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []

        for url in urls {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                result.append(url)
            }
        }

        return result
    }
}

actor OfflineArticlePreloader {
    private let session: URLSession
    private let maxConcurrentDownloads = 6
    private let maxAssetBytes = 24 * 1024 * 1024
    private var inFlightAssetKeys: Set<String> = []

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = .shared
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    func preload(entries: [FeedEntry]) async {
        let uniqueAssetURLs = OfflineArticleArchive.uniqueMediaURLs(for: entries)
        let validAssetKeys = Set(uniqueAssetURLs.map(OfflineArticleArchive.assetStorageKey(for:)))
        let validArticleKeys = Set(entries.map { OfflineArticleArchive.articleStorageFileName(for: $0.link) + ".html" })

        pruneStaleFiles(validAssetKeys: validAssetKeys, validArticleFileNames: validArticleKeys)

        var pendingDownloads: [(key: String, url: URL)] = []
        pendingDownloads.reserveCapacity(uniqueAssetURLs.count)

        for url in uniqueAssetURLs {
            let key = OfflineArticleArchive.assetStorageKey(for: url)
            guard OfflineArticleArchive.cachedAssetFileURL(for: url) == nil,
                  !inFlightAssetKeys.contains(key) else {
                continue
            }

            inFlightAssetKeys.insert(key)
            pendingDownloads.append((key: key, url: url))
        }

        guard !pendingDownloads.isEmpty else { return }

        let session = self.session
        let maxAssetBytes = self.maxAssetBytes
        let maxConcurrentDownloads = self.maxConcurrentDownloads
        var iterator = pendingDownloads.makeIterator()

        await withTaskGroup(of: String.self) { group in
            for _ in 0..<min(maxConcurrentDownloads, pendingDownloads.count) {
                guard let next = iterator.next() else { break }
                group.addTask {
                    await Self.downloadAsset(from: next.url, session: session, maxAssetBytes: maxAssetBytes)
                    return next.key
                }
            }

            while let completedKey = await group.next() {
                inFlightAssetKeys.remove(completedKey)

                if let next = iterator.next() {
                    group.addTask {
                        await Self.downloadAsset(from: next.url, session: session, maxAssetBytes: maxAssetBytes)
                        return next.key
                    }
                }
            }
        }
    }

    private func pruneStaleFiles(validAssetKeys: Set<String>, validArticleFileNames: Set<String>) {
        pruneContents(of: OfflineArticleArchive.readAccessURL()?.appendingPathComponent("assets", isDirectory: true),
                      keepingFileNames: validAssetKeys)
        pruneContents(of: OfflineArticleArchive.readAccessURL()?.appendingPathComponent("articles", isDirectory: true),
                      keepingFileNames: validArticleFileNames)
    }

    private func pruneContents(of directoryURL: URL?, keepingFileNames validFileNames: Set<String>) {
        guard let directoryURL else { return }

        let fileManager = FileManager.default
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in fileURLs {
            guard validFileNames.contains(fileURL.lastPathComponent) == false else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private static func downloadAsset(from remoteURL: URL, session: URLSession, maxAssetBytes: Int) async {
        guard let destinationURL = OfflineArticleArchive.assetFileURL(for: remoteURL) else { return }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }

        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 30
            request.cachePolicy = .returnCacheDataElseLoad

            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return
            }

            if response.expectedContentLength > Int64(maxAssetBytes) {
                return
            }

            if isSupportedMediaResponse(mimeType: response.mimeType, remoteURL: remoteURL) == false {
                return
            }

            var data = Data()
            if response.expectedContentLength > 0, response.expectedContentLength < Int64(maxAssetBytes) {
                data.reserveCapacity(Int(response.expectedContentLength))
            }

            for try await byte in bytes {
                data.append(byte)
                if data.count > maxAssetBytes {
                    return
                }
            }

            guard !data.isEmpty else { return }

            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            return
        }
    }

    private static func isSupportedMediaResponse(mimeType: String?, remoteURL: URL) -> Bool {
        if let mimeType {
            let normalized = mimeType.lowercased()
            if normalized.hasPrefix("image/") || normalized.hasPrefix("video/") || normalized.hasPrefix("audio/") {
                return true
            }
            if normalized == "application/octet-stream" {
                return true
            }
            return false
        }

        let fileExtension = remoteURL.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "mp4", "m4v", "mov", "mp3", "aac", "wav", "ogg"].contains(fileExtension)
    }
}
