import Foundation
import CryptoKit
import OSLog

nonisolated private final class OfflineAssetFileURLCache: @unchecked Sendable {
    private let paths = NSCache<NSURL, NSURL>()
    private let existingFiles = NSCache<NSURL, NSURL>()
    private let lock = NSLock()
    private var missingUntil: [NSURL: Date] = [:]

    func fileURL(for remoteURL: URL) -> URL? {
        paths.object(forKey: remoteURL as NSURL) as URL?
    }

    func existingFileURL(for remoteURL: URL) -> URL? {
        existingFiles.object(forKey: remoteURL as NSURL) as URL?
    }

    func isTemporarilyMissing(_ remoteURL: URL, now: Date = Date()) -> Bool {
        let key = remoteURL as NSURL
        return lock.withLock {
            guard let deadline = missingUntil[key] else { return false }
            if deadline > now {
                return true
            }
            missingUntil[key] = nil
            return false
        }
    }

    func storePath(_ fileURL: URL, for remoteURL: URL) {
        paths.setObject(fileURL as NSURL, forKey: remoteURL as NSURL)
    }

    func storeExistingFile(_ fileURL: URL, for remoteURL: URL) {
        let key = remoteURL as NSURL
        paths.setObject(fileURL as NSURL, forKey: key)
        existingFiles.setObject(fileURL as NSURL, forKey: key)
        lock.withLock {
            missingUntil[key] = nil
        }
    }

    func recordMissing(_ remoteURL: URL, duration: TimeInterval) {
        let key = remoteURL as NSURL
        lock.withLock {
            missingUntil[key] = Date().addingTimeInterval(duration)
        }
    }
}

nonisolated private final class OfflineReaderHTMLPreparationCache: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightContentIDs: Set<String> = []

    func beginPreparing(contentID: String) -> Bool {
        lock.withLock {
            guard !inFlightContentIDs.contains(contentID) else { return false }
            inFlightContentIDs.insert(contentID)
            return true
        }
    }

    func finishPreparing(contentID: String) {
        lock.withLock {
            _ = inFlightContentIDs.remove(contentID)
        }
    }
}

enum OfflineArticleArchive {
    nonisolated static let preloader = OfflineArticlePreloader()

    nonisolated private static let archiveDirectoryName = "OfflineArticleArchive"
    nonisolated private static let assetsDirectoryName = "assets"
    nonisolated private static let articlesDirectoryName = "articles"
    nonisolated private static let cachedRootDirectoryURL: URL? = createDirectory(
        named: archiveDirectoryName,
        below: FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
    )
    nonisolated private static let cachedAssetsDirectoryURL: URL? = createDirectory(
        named: assetsDirectoryName,
        below: cachedRootDirectoryURL
    )
    nonisolated private static let cachedArticlesDirectoryURL: URL? = createDirectory(
        named: articlesDirectoryName,
        below: cachedRootDirectoryURL
    )
    nonisolated private static let assetFileURLCache = OfflineAssetFileURLCache()
    nonisolated private static let readerHTMLPreparationCache = OfflineReaderHTMLPreparationCache()
    nonisolated private static let mediaAttributeRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(src|poster|data-src|data-original|data-lazy-src|data-orig-file)\s*=\s*(["'])([^"']+)\2"#,
        options: []
    )
    nonisolated private static let hrefAttributeRegex = try? NSRegularExpression(
        pattern: #"(?i)\bhref\s*=\s*(["'])([^"']+)\1"#,
        options: []
    )
    nonisolated private static let srcsetAttributeRegex = try? NSRegularExpression(
        pattern: #"(?i)\b(srcset|data-srcset)\s*=\s*(["'])([^"']+)\2"#,
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

        if let cachedURL = assetFileURLCache.existingFileURL(for: remoteURL) {
            return cachedURL
        }
        guard !assetFileURLCache.isTemporarilyMissing(remoteURL),
              let fileURL = assetFileURL(for: remoteURL) else {
            return nil
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            assetFileURLCache.recordMissing(remoteURL, duration: 5)
            return nil
        }
        assetFileURLCache.storeExistingFile(fileURL, for: remoteURL)
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

    nonisolated static func existingPreparedReaderHTMLDocumentURL(forContentID contentID: String) -> URL? {
        guard let fileURL = readerHTMLFileURL(forContentID: contentID),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return fileURL
    }

    nonisolated static func prepareReaderHTMLDocumentIfNeeded(
        forContentID contentID: String,
        articleURL: URL?,
        htmlDocument: String
    ) {
        guard existingPreparedReaderHTMLDocumentURL(forContentID: contentID) == nil else { return }
        guard readerHTMLPreparationCache.beginPreparing(contentID: contentID) else { return }
        defer {
            readerHTMLPreparationCache.finishPreparing(contentID: contentID)
        }

        guard let fileURL = readerHTMLFileURL(forContentID: contentID),
              let articlesDirectoryURL else {
            return
        }

        do {
            try FileManager.default.createDirectory(at: articlesDirectoryURL, withIntermediateDirectories: true)
            let rewritten = rewriteDocumentForLocalRendering(htmlDocument, relativeTo: articleURL)
            try rewritten.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            AppLogger.persistence.warning("Failed to prepare reader HTML for \(contentID, privacy: .private)")
        }
    }

    @discardableResult
    nonisolated static func prepareOfflineHTMLDocument(for entry: FeedEntry) -> URL? {
        prepareOfflineHTMLDocument(
            forArticleLink: entry.link,
            articleURL: URL(string: entry.link),
            htmlDocument: offlineHTMLDocument(for: entry)
        )
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

    nonisolated private static func readerHTMLFileURL(forContentID contentID: String) -> URL? {
        guard let articlesDirectoryURL else { return nil }
        return articlesDirectoryURL
            .appendingPathComponent("reader-\(stableHash(for: "reader|\(contentID)"))")
            .appendingPathExtension("html")
    }

    nonisolated fileprivate static func assetFileURL(for remoteURL: URL) -> URL? {
        guard let assetsDirectoryURL else { return nil }
        if let cached = assetFileURLCache.fileURL(for: remoteURL) {
            return cached
        }

        let fileURL = assetsDirectoryURL.appendingPathComponent(assetFileName(for: remoteURL))
        assetFileURLCache.storePath(fileURL, for: remoteURL)
        return fileURL
    }

    nonisolated private static var rootDirectoryURL: URL? {
        cachedRootDirectoryURL
    }

    nonisolated private static var assetsDirectoryURL: URL? {
        cachedAssetsDirectoryURL
    }

    nonisolated private static var articlesDirectoryURL: URL? {
        cachedArticlesDirectoryURL
    }

    nonisolated private static func createDirectory(named name: String, below parent: URL?) -> URL? {
        guard let parent else { return nil }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            AppLogger.persistence.warning("Failed to create offline archive directory \(name, privacy: .public)")
            return nil
        }
    }

    nonisolated private static func offlineHTMLDocument(for entry: FeedEntry) -> String {
        let title = escapedHTML(entry.displayTitle)
        let bodySource = entry.contentRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (bodySource?.isEmpty == false) ? bodySource! : "<p>\(escapedHTML(entry.content))</p>"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        </head>
        <body>
        <article>
        <h1>\(title)</h1>
        \(body)
        </article>
        </body>
        </html>
        """
    }

    nonisolated private static func escapedHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
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
                guard match.numberOfRanges >= 4,
                      let valueRange = Range(match.range(at: 3), in: html) else {
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

            let replacement = "\(attributeName)=\(quote)\(replacementValue)\(quote)"
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

nonisolated enum OfflineArticleRetentionLimit: Int, CaseIterable, Identifiable {
    case ten = 10
    case twentyFive = 25
    case fifty = 50
    case hundred = 100
    case allNewest = -1

    static let defaultValue = OfflineArticleRetentionLimit.fifty

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .ten:
            return "10"
        case .twentyFive:
            return "25"
        case .fifty:
            return "50"
        case .hundred:
            return "100"
        case .allNewest:
            return "Alle neuesten"
        }
    }

    var articleLimit: Int? {
        switch self {
        case .allNewest:
            return nil
        case .ten, .twentyFive, .fifty, .hundred:
            return rawValue
        }
    }

    static func storedValue(in defaults: UserDefaults = FeedStorage.defaults) -> OfflineArticleRetentionLimit {
        let rawValue = defaults.integer(forKey: FeedStorage.Keys.offlineRetainedFetchedArticleLimit)
        return OfflineArticleRetentionLimit(rawValue: rawValue) ?? defaultValue
    }
}

nonisolated enum OfflineArticleRetentionPolicy {
    static func retainedEntries(
        from entries: [FeedEntry],
        readIDs: Set<String>,
        bookmarkedLinks: Set<String>,
        limit: OfflineArticleRetentionLimit = .storedValue()
    ) -> [FeedEntry] {
        let newestEntries = deduplicated(entries).sorted { lhs, rhs in
            let lhsDate = DateParser.parse(lhs.pubDateString)
            let rhsDate = DateParser.parse(rhs.pubDateString)
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        guard let regularLimit = limit.articleLimit else {
            return newestEntries
        }

        var retained: [FeedEntry] = []
        retained.reserveCapacity(newestEntries.count)
        var retainedLinks: Set<String> = []

        for entry in newestEntries where isProtected(entry, readIDs: readIDs, bookmarkedLinks: bookmarkedLinks) {
            if retainedLinks.insert(entry.link).inserted {
                retained.append(entry)
            }
        }

        var regularCount = 0
        for entry in newestEntries where !isProtected(entry, readIDs: readIDs, bookmarkedLinks: bookmarkedLinks) {
            guard regularCount < regularLimit else { break }
            if retainedLinks.insert(entry.link).inserted {
                retained.append(entry)
                regularCount += 1
            }
        }

        return retained
    }

    private static func isProtected(_ entry: FeedEntry, readIDs: Set<String>, bookmarkedLinks: Set<String>) -> Bool {
        bookmarkedLinks.contains(entry.link) || !readIDs.contains(entry.link)
    }

    private static func deduplicated(_ entries: [FeedEntry]) -> [FeedEntry] {
        var seen: Set<String> = []
        var result: [FeedEntry] = []
        result.reserveCapacity(entries.count)

        for entry in entries where seen.insert(entry.link).inserted {
            result.append(entry)
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
        for entry in entries {
            OfflineArticleArchive.prepareOfflineHTMLDocument(for: entry)
        }

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
            if fileURL.lastPathComponent.hasPrefix("reader-") {
                continue
            }
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
