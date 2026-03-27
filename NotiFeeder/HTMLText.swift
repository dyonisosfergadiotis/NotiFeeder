import Foundation

enum HTMLText {
    nonisolated static func stripHTML(_ html: String) -> String {
        var text = decodeHTMLEntities(in: html)
            // Strip tags after decoding.
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func decodeHTMLEntities(in input: String) -> String {
        var text = input
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")

        // Decode numeric HTML entities like &#36; and &#x24;.
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else {
            return text
        }

        while true {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            guard !matches.isEmpty else { break }

            var decoded = text
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let fullRange = Range(match.range(at: 0), in: decoded),
                      let valueRange = Range(match.range(at: 1), in: decoded) else {
                    continue
                }

                let token = String(decoded[valueRange])
                let scalarValue: UInt32?
                if token.lowercased().hasPrefix("x") {
                    scalarValue = UInt32(token.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(token, radix: 10)
                }

                if let scalarValue,
                   let scalar = UnicodeScalar(scalarValue) {
                    decoded.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }

            if decoded == text { break }
            text = decoded
        }

        return text
    }
}
