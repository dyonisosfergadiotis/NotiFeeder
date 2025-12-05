import Foundation

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

    func parse(data: Data) -> [FeedEntry] {
        entries.removeAll()
        
        // 🧹 RSS-Inhalt als String bereinigen
        guard var xmlString = String(data: data, encoding: .utf8) else { return [] }

        // Fehlerhafte Entities & offene Tags reparieren
        xmlString = xmlString.replacingOccurrences(of: "&nbsp;", with: "")
        xmlString = xmlString.replacingOccurrences(of: "&(?!(amp|lt|gt|quot|apos|#\\d+);)", with: "&amp;", options: .regularExpression)
        xmlString = xmlString.replacingOccurrences(of: "&amp;", with: "&")
        xmlString = xmlString.replacingOccurrences(of: "&#(0|1|2|3|4|5|6|7|8|9)(0|1|2|3|4|5|6|7|8|9);", with: "", options: .regularExpression)
        xmlString = xmlString.replacingOccurrences(of: "&[A-Za-z]+;", with: "", options: .regularExpression)
        xmlString = xmlString.replacingOccurrences(of: "<br>", with: "<br/>")

        // Neue Parser-Instanz mit bereinigten Daten
        guard let cleanData = xmlString.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: cleanData)
        parser.delegate = self

        if !parser.parse() {
            print("❌ Parser error: \(parser.parserError?.localizedDescription ?? "unknown error")")
        }

        return entries
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
            if currentImageURL.isEmpty {
                if let regex = try? NSRegularExpression(pattern: "<img[^>]+src\\s*=\\s*['\"]([^'\"]+)['\"][^>]*>", options: .caseInsensitive) {
                    let range = NSRange(location: 0, length: currentDescription.utf16.count)
                    if let match = regex.firstMatch(in: currentDescription, options: [], range: range),
                       let imgRange = Range(match.range(at: 1), in: currentDescription) {
                        currentImageURL = String(currentDescription[imgRange])
                    }
                }
            }

            // HTML-Tags aus Beschreibung entfernen (optional)
            let cleanDescription = currentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTitle = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let entry = FeedEntry(
                title: cleanTitle,
                shortTitle: generateShortTitle(for: cleanTitle),
                link: currentLink.trimmingCharacters(in: .whitespacesAndNewlines),
                content: cleanDescription,
                imageURL: currentImageURL.isEmpty ? nil : currentImageURL,
                author: currentAuthor.isEmpty ? nil : currentAuthor.trimmingCharacters(in: .whitespacesAndNewlines),
                pubDateString: currentPubDate.isEmpty ? nil : currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            entries.append(entry)
        }
    }
}
