import Foundation
import OSLog

nonisolated enum RSSParserError: Error, Equatable, Sendable {
    case invalidEncoding
    case invalidSanitizedData
    case xmlParsingFailed
    case emptyItems
}

nonisolated final class RSSParser: NSObject, XMLParserDelegate {
    private struct Item {
        var isAtom = false
        var title = ""
        var link = ""
        var identifier = ""
        var summary = ""
        var content = ""
        var author = ""
        var published = ""
        var updated = ""
        var imageURL = ""
    }

    private static let imageSourceRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "<img[^>]+(?:src|data-src|data-original|data-lazy-src|data-orig-file)\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>",
            options: .caseInsensitive
        )
    }()

    private static let imageSrcsetRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "<img[^>]+srcset\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>",
            options: .caseInsensitive
        )
    }()

    private static let unsupportedEntityRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "&([A-Za-z][A-Za-z0-9]{1,31});"
        )
    }()

    private static let bareAmpersandRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: "&(?!#\\d+;|#x[0-9A-Fa-f]+;|amp;|lt;|gt;|quot;|apos;)"
        )
    }()

    private static let entityReplacements: [String: String] = [
        "nbsp": "&#160;",
        "ensp": "&#8194;",
        "emsp": "&#8195;",
        "thinsp": "&#8201;",
        "copy": "&#169;",
        "reg": "&#174;",
        "trade": "&#8482;",
        "ndash": "&#8211;",
        "mdash": "&#8212;",
        "hellip": "&#8230;",
        "bull": "&#8226;",
        "lsquo": "&#8216;",
        "rsquo": "&#8217;",
        "ldquo": "&#8220;",
        "rdquo": "&#8221;",
        "laquo": "&#171;",
        "raquo": "&#187;",
        "euro": "&#8364;",
        "pound": "&#163;"
    ]

    private static let textElements = Set([
        "title", "link", "guid", "id", "description", "summary", "encoded", "content",
        "creator", "author", "name", "pubdate", "published", "issued", "created",
        "updated", "modified", "date", "url"
    ])

    private var entries: [FeedEntry] = []
    private var currentItem: Item?
    private var elementStack: [String] = []
    private var baseURL: URL?

    func parseResult(data: Data, baseURL: URL? = nil) -> Result<[FeedEntry], RSSParserError> {
        self.baseURL = baseURL

        if parse(data) {
            return entries.isEmpty ? .failure(.emptyItems) : .success(deduplicatedEntries())
        }

        guard let repairedData = Self.repairedXMLData(from: data) else {
            return .failure(.invalidEncoding)
        }

        if parse(repairedData) {
            return entries.isEmpty ? .failure(.emptyItems) : .success(deduplicatedEntries())
        }

        return .failure(.xmlParsingFailed)
    }

    private func parse(_ data: Data) -> Bool {
        entries.removeAll(keepingCapacity: true)
        currentItem = nil
        elementStack.removeAll(keepingCapacity: true)

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "unknown error"
            AppLogger.parsing.error("XML parser failed: \(message, privacy: .public)")
            entries.removeAll(keepingCapacity: true)
            currentItem = nil
            elementStack.removeAll(keepingCapacity: true)
            return false
        }
        return true
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = Self.localName(qName ?? elementName)
        elementStack.append(element)

        if element == "item" || element == "entry" {
            currentItem = Item(isAtom: element == "entry")
            return
        }

        guard currentItem != nil else { return }
        let attributes = Self.normalizedAttributes(attributeDict)

        switch element {
        case "link":
            guard let href = attributes["href"], !href.isEmpty else { return }
            let relation = attributes["rel"]?.lowercased() ?? "alternate"
            if relation == "alternate" || relation.isEmpty {
                currentItem?.link = href
            } else if currentItem?.link.isEmpty == true, relation != "enclosure" {
                currentItem?.link = href
            }
        case "enclosure":
            let type = attributes["type"]?.lowercased() ?? ""
            if let url = attributes["url"],
               type.hasPrefix("image/") || (type.isEmpty && Self.looksLikeImageURL(url)) {
                currentItem?.imageURL = url
            }
        case "thumbnail":
            if let url = attributes["url"] {
                currentItem?.imageURL = url
            }
        case "content":
            let medium = attributes["medium"]?.lowercased() ?? ""
            let type = attributes["type"]?.lowercased() ?? ""
            if let url = attributes["url"],
               medium == "image"
                || type.hasPrefix("image/")
                || (medium.isEmpty && type.isEmpty && Self.looksLikeImageURL(url)) {
                currentItem?.imageURL = url
            }
        case "image":
            if let href = attributes["href"] {
                currentItem?.imageURL = href
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            appendText(string)
        } else if let string = String(data: CDATABlock, encoding: .isoLatin1) {
            appendText(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = Self.localName(qName ?? elementName)
        if element == "item" || element == "entry" {
            if let item = currentItem, let entry = makeEntry(from: item) {
                entries.append(entry)
            }
            currentItem = nil
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
    }

    private func appendText(_ string: String) {
        guard var item = currentItem, let currentElement = elementStack.last else { return }
        let element = Self.textElements.contains(currentElement)
            ? currentElement
            : elementStack.reversed().first(where: Self.textElements.contains)
        guard let element else { return }
        let parent = elementStack.dropLast().last

        switch element {
        case "title":
            item.title += string
        case "link":
            if !item.isAtom {
                item.link += string
            }
        case "guid", "id":
            item.identifier += string
        case "description", "summary":
            item.summary += string
        case "encoded", "content":
            item.content += string
        case "creator":
            item.author += string
        case "author":
            if parent != "channel" {
                item.author += string
            }
        case "name":
            if parent == "author" {
                item.author += string
            }
        case "pubdate", "published", "issued", "created":
            item.published += string
        case "updated", "modified", "date":
            item.updated += string
        case "url":
            if elementStack.dropLast().last == "image" {
                item.imageURL += string
            }
        default:
            break
        }

        currentItem = item
    }

    private func makeEntry(from item: Item) -> FeedEntry? {
        let rawTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawContent = preferredContent(for: item)
        let normalizedHTML = HTMLText.normalizeHTMLContent(rawContent)
        let cleanDescription = HTMLText.stripHTML(normalizedHTML)
        let cleanTitle = HTMLText.normalizePreviewSpacing(in: HTMLText.stripHTML(rawTitle))

        guard !cleanTitle.isEmpty || !cleanDescription.isEmpty else { return nil }

        var imageURL = item.imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if imageURL.isEmpty {
            imageURL = Self.firstImageURL(in: normalizedHTML) ?? ""
        }

        let rawLink = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawIdentifier = item.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLink = resolveURLString(rawLink)
            ?? resolveURLString(rawIdentifier)
            ?? (rawIdentifier.isEmpty
                ? fallbackIdentifier(title: cleanTitle, date: item.published + item.updated)
                : rawIdentifier)

        let resolvedImageURL = resolveURLString(imageURL)
        let author = HTMLText.normalizePreviewSpacing(
            in: HTMLText.stripHTML(item.author.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        let date = item.published.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDate = item.updated.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = cleanTitle.isEmpty ? "Ohne Titel" : cleanTitle

        return FeedEntry(
            title: displayTitle,
            shortTitle: generateShortTitle(for: displayTitle),
            link: resolvedLink,
            content: cleanDescription,
            contentRaw: normalizedHTML,
            imageURL: resolvedImageURL,
            author: author.isEmpty ? nil : author,
            pubDateString: date.isEmpty ? (fallbackDate.isEmpty ? nil : fallbackDate) : date
        )
    }

    private func preferredContent(for item: Item) -> String {
        let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            return content
        }
        return item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveURLString(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("//"), let scheme = baseURL?.scheme {
            return "\(scheme):\(value)"
        }
        if let url = URL(string: value, relativeTo: baseURL) {
            return url.absoluteURL.absoluteString
        }
        if let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: encoded, relativeTo: baseURL) {
            return url.absoluteURL.absoluteString
        }
        return value
    }

    private func fallbackIdentifier(title: String, date: String) -> String {
        let base = baseURL?.absoluteString ?? "notifeeder:feed"
        let escaped = (title + date)
            .unicodeScalars
            .map { String($0.value, radix: 16) }
            .joined(separator: "-")
        return "\(base)#entry-\(escaped.prefix(160))"
    }

    private func deduplicatedEntries() -> [FeedEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.link).inserted }
    }

    private func generateShortTitle(for title: String) -> String {
        var result = title
        if let colonIndex = result.firstIndex(of: ":") {
            result = String(result[..<colonIndex])
        }
        result = result.replacingOccurrences(
            of: "(?i)\\b(news|update|report|breaking)\\b",
            with: "",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > 45 {
            result = String(result.prefix(45)) + "…"
        }
        return result
    }

    private static func localName(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    private static func normalizedAttributes(_ attributes: [String: String]) -> [String: String] {
        attributes.reduce(into: [:]) { result, pair in
            result[localName(pair.key)] = pair.value
        }
    }

    private static func firstImageURL(in html: String) -> String? {
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        if let regex = imageSourceRegex,
           let match = regex.firstMatch(in: html, options: [], range: range),
           let imageRange = Range(match.range(at: 1), in: html) {
            return String(html[imageRange])
        }

        guard let srcsetRegex = imageSrcsetRegex,
              let match = srcsetRegex.firstMatch(in: html, options: [], range: range),
              let srcsetRange = Range(match.range(at: 1), in: html) else {
            return nil
        }

        return preferredImageURL(inSrcset: String(html[srcsetRange]))
    }

    private static func preferredImageURL(inSrcset srcset: String) -> String? {
        srcset
            .split(separator: ",")
            .compactMap { candidate -> String? in
                candidate
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0.isWhitespace })
                    .first
                    .map(String.init)
            }
            .last
    }

    private static func looksLikeImageURL(_ value: String) -> Bool {
        let pathExtension = URL(string: value)?.pathExtension.lowercased() ?? ""
        return ["avif", "gif", "heic", "jpeg", "jpg", "png", "webp"].contains(pathExtension)
    }

    private static func repairedXMLData(from data: Data) -> Data? {
        guard var xml = decodeXML(data) else { return nil }

        xml = xml.replacingOccurrences(
            of: "(?i)<\\?xml([^>]*?)encoding\\s*=\\s*['\"][^'\"]+['\"]([^>]*?)\\?>",
            with: "<?xml$1encoding=\"UTF-8\"$2?>",
            options: .regularExpression
        )
        xml = xml.replacingOccurrences(
            of: "(?i)<br\\s*>",
            with: "<br/>",
            options: .regularExpression
        )
        xml = replacingUnsupportedEntities(in: xml)

        if let regex = bareAmpersandRegex {
            let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
            xml = regex.stringByReplacingMatches(in: xml, options: [], range: range, withTemplate: "&amp;")
        }

        let validScalars = xml.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                return true
            default:
                return false
            }
        }
        return String(String.UnicodeScalarView(validScalars)).data(using: .utf8)
    }

    private static func decodeXML(_ data: Data) -> String? {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        let prefix = String(decoding: data.prefix(256), as: Unicode.ASCII.self).lowercased()
        let declaredEncoding: String.Encoding?
        if prefix.contains("windows-1252") || prefix.contains("cp1252") {
            declaredEncoding = .windowsCP1252
        } else if prefix.contains("iso-8859-1") || prefix.contains("latin1") {
            declaredEncoding = .isoLatin1
        } else if prefix.contains("utf-16") {
            declaredEncoding = .utf16
        } else {
            declaredEncoding = nil
        }

        for encoding in [declaredEncoding, .windowsCP1252, .isoLatin1, .utf16].compactMap({ $0 }) {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }
        return nil
    }

    private static func replacingUnsupportedEntities(in input: String) -> String {
        guard let regex = unsupportedEntityRegex else { return input }
        let matches = regex.matches(
            in: input,
            options: [],
            range: NSRange(input.startIndex..<input.endIndex, in: input)
        )
        guard !matches.isEmpty else { return input }

        let xmlEntities = Set(["amp", "lt", "gt", "quot", "apos"])
        var result = input
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let name = String(result[nameRange])
            if xmlEntities.contains(name) {
                continue
            }
            let replacement = entityReplacements[name.lowercased()] ?? "&amp;\(name);"
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }
}
