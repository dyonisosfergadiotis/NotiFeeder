import Foundation

enum HTMLText {
    static func stripHTML(_ html: String) -> String {
        // Try using NSAttributedString HTML conversion first for better decoding of entities
        if let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
           ) {
            return attributed.string
        }
        // Fallback: regex strip of tags
        return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
