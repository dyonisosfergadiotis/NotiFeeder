import Foundation
import OSLog

enum RSSParserError: Error, Equatable {
    case invalidEncoding
    case invalidSanitizedData
    case xmlParsingFailed
    case emptyItems
}

class RSSParser: NSObject, XMLParserDelegate {
    private var entries: [FeedEntry] = []
    private var currentTitle = ""
    private var currentLink = ""
    private var currentDescription = ""
    private var currentImageURL = ""
    private var currentElement = ""
    private var currentAuthor = ""
    private var currentPubDate = ""

    private func generateShortTitle(for title: String) -> String {
        var result = title
        if let colonIndex = result.firstIndex(of: ":") {
            result = String(result[..<colonIndex])
        }
        result = result.replacingOccurrences(of: "(?i)\\b(news|update|report|breaking)\\b", with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > 45 {
            result = String(result.prefix(45)) + "…"
        }
        return result
    }

    func parseResult(data: Data) -> Result<[FeedEntry], RSSParserError> {
        entries.removeAll()
        
        // 🧹 RSS-Inhalt minimal bereinigen (XMLParser akzeptiert z. B. kein &nbsp;)
        guard var xmlString = String(data: data, encoding: .utf8) else { return .failure(.invalidEncoding) }
        xmlString = xmlString.replacingOccurrences(of: "&nbsp;", with: " ")
        xmlString = xmlString.replacingOccurrences(of: "<br>", with: "<br/>")

        guard let cleanData = xmlString.data(using: .utf8) else { return .failure(.invalidSanitizedData) }
        let parser = XMLParser(data: cleanData)
        parser.delegate = self

        if !parser.parse() {
            let message = parser.parserError?.localizedDescription ?? "unknown error"
            AppLogger.parsing.error("XML parser failed: \(message, privacy: .public)")
            return .failure(.xmlParsingFailed)
        }

        guard !entries.isEmpty else {
            return .failure(.emptyItems)
        }

        return .success(entries)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if elementName == "item" {
            currentTitle = ""
            currentLink = ""
            currentDescription = ""
            currentImageURL = ""
            currentAuthor = ""
            currentPubDate = ""
        }
        if elementName == "media:content", let url = attributeDict["url"] {
            currentImageURL = url
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "title": currentTitle += string
        case "link": currentLink += string
        case "description", "content:encoded": currentDescription += string
        case "dc:creator", "author": currentAuthor += string
        case "pubDate": currentPubDate += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item" {
            // Falls kein Bild direkt angegeben ist, versuche es aus <img src="..."> herauszulesen
            let rawDescription = currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentImageURL.isEmpty {
                if let regex = try? NSRegularExpression(pattern: "<img[^>]+src\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>", options: .caseInsensitive) {
                    let range = NSRange(location: 0, length: rawDescription.utf16.count)
                    if let match = regex.firstMatch(in: rawDescription, options: [], range: range),
                       let imgRange = Range(match.range(at: 1), in: rawDescription) {
                        currentImageURL = String(rawDescription[imgRange])
                    }
                }
            }

            // HTML-Tags aus Beschreibung entfernen
            let cleanDescription = HTMLText.stripHTML(rawDescription)
            let cleanTitle = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let entry = FeedEntry(
                title: cleanTitle,
                shortTitle: generateShortTitle(for: cleanTitle),
                link: currentLink.trimmingCharacters(in: .whitespacesAndNewlines),
                content: cleanDescription,
                contentRaw: rawDescription,
                imageURL: currentImageURL.isEmpty ? nil : currentImageURL,
                author: currentAuthor.isEmpty ? nil : currentAuthor.trimmingCharacters(in: .whitespacesAndNewlines),
                pubDateString: currentPubDate.isEmpty ? nil : currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            entries.append(entry)
        }
    }
}
