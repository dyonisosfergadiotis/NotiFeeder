import Foundation

enum HTMLText {
    nonisolated private static let namedEntityRegex = try? NSRegularExpression(
        pattern: "&([A-Za-z][A-Za-z0-9]{1,31});"
    )
    nonisolated private static let mojibakeMarkers: [String] = [
        "â€™",
        "â€˜",
        "â€œ",
        "â€",
        "â€“",
        "â€”",
        "â€¦",
        "â„¢",
        "Â",
        "Ã"
    ]
    nonisolated private static let visibleMojibakeReplacements: [(artifact: String, replacement: String)] = [
        ("â€™", "’"),
        ("â€˜", "‘"),
        ("â€œ", "“"),
        ("â€\u{009C}", "“"),
        ("â€\u{009D}", "”"),
        ("â€“", "–"),
        ("â€”", "—"),
        ("â€¦", "…"),
        ("â„¢", "™"),
        ("â€¢", "•")
    ]

    nonisolated private static let namedEntityMap: [String: String] = [
        // Spacing/formatting entities that often leak from feed content.
        "nbsp": " ",
        "ensp": " ",
        "emsp": " ",
        "thinsp": " ",
        "hairsp": " ",
        "numsp": " ",
        "puncsp": " ",
        "zwnj": "",
        "zwj": "",
        "lrm": "",
        "rlm": "",
        "shy": "",
        "ZeroWidthSpace": "",
        // Common punctuation/symbol fallbacks.
        "copy": "©",
        "reg": "®",
        "trade": "™",
        "ndash": "–",
        "mdash": "—",
        "hellip": "…",
        "bull": "•"
    ]

    nonisolated private static let invisibleFormattingScalars: Set<UInt32> = [
        0x00AD, // Soft hyphen
        0x034F, // Combining grapheme joiner
        0x061C, // Arabic letter mark
        0x180E, // Mongolian vowel separator (deprecated)
        0x200B, // Zero width space
        0x200C, // Zero width non-joiner
        0x200D, // Zero width joiner
        0x200E, // Left-to-right mark
        0x200F, // Right-to-left mark
        0x202A, // Left-to-right embedding
        0x202B, // Right-to-left embedding
        0x202C, // Pop directional formatting
        0x202D, // Left-to-right override
        0x202E, // Right-to-left override
        0x2060, // Word joiner
        0x2061, // Function application
        0x2062, // Invisible times
        0x2063, // Invisible separator
        0x2064, // Invisible plus
        0x2066, // Left-to-right isolate
        0x2067, // Right-to-left isolate
        0x2068, // First strong isolate
        0x2069, // Pop directional isolate
        0xFEFF  // Zero width no-break space / BOM
    ]

    nonisolated static func stripHTML(_ html: String) -> String {
        var text = decodeHTMLEntities(in: html)
            // Strip tags after decoding.
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalizePreviewSpacing(in: text)
    }

    nonisolated static func normalizePreviewSpacing(in input: String) -> String {
        let normalized = repairEncodingArtifacts(in: input)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+,", with: ",", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func normalizeHTMLContent(_ html: String) -> String {
        removeInvisibleFormattingCharacters(from: repairEncodingArtifacts(in: html))
    }

    nonisolated private static func decodeHTMLEntities(in input: String) -> String {
        var text = repairEncodingArtifacts(in: input)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")

        // Decode numeric HTML entities like &#36; and &#x24;.
        guard let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") else {
            return removeInvisibleFormattingCharacters(from: text)
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

        text = decodeNamedEntities(in: text)
        return removeInvisibleFormattingCharacters(from: repairEncodingArtifacts(in: text))
    }

    nonisolated private static func decodeNamedEntities(in input: String) -> String {
        guard let regex = namedEntityRegex else { return input }

        var text = input
        while true {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, options: [], range: range)
            guard !matches.isEmpty else { break }

            var decoded = text
            var didReplace = false

            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let fullRange = Range(match.range(at: 0), in: decoded),
                      let valueRange = Range(match.range(at: 1), in: decoded) else {
                    continue
                }

                let entityName = String(decoded[valueRange])
                let replacement = namedEntityMap[entityName] ?? namedEntityMap[entityName.lowercased()]
                guard let replacement else { continue }

                decoded.replaceSubrange(fullRange, with: replacement)
                didReplace = true
            }

            guard didReplace else { break }
            text = decoded
        }

        return text
    }

    nonisolated private static func removeInvisibleFormattingCharacters(from input: String) -> String {
        let filteredScalars = input.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                return true
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F:
                return false
            default:
                return !invisibleFormattingScalars.contains(scalar.value)
            }
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    nonisolated private static func repairEncodingArtifacts(in input: String) -> String {
        let roundTripped = repairMisdecodedUTF8(in: input)
        return repairResidualMojibakeFragments(in: roundTripped)
    }

    nonisolated private static func repairMisdecodedUTF8(in input: String) -> String {
        var current = input

        for _ in 0..<2 {
            let currentMarkerCount = mojibakeMarkerCount(in: current)
            guard currentMarkerCount > 0,
                  let candidateData = current.data(using: .windowsCP1252),
                  let candidate = String(data: candidateData, encoding: .utf8),
                  candidate != current else {
                break
            }

            let candidateMarkerCount = mojibakeMarkerCount(in: candidate)
            guard candidateMarkerCount <= currentMarkerCount else {
                break
            }

            current = candidate
        }

        return current
    }

    nonisolated private static func repairResidualMojibakeFragments(in input: String) -> String {
        var repaired = input

        for pair in visibleMojibakeReplacements {
            repaired = repaired.replacingOccurrences(of: pair.artifact, with: pair.replacement)
        }

        repaired = repaired.replacingOccurrences(
            of: "â€(?=\\s|[\\.,;:!?\\)\\]\\}]|$)",
            with: "”",
            options: .regularExpression
        )
        repaired = repaired.replacingOccurrences(
            of: "Â(?=\\s|[\\.,;:!?\\)\\]\\}£€¥©®°»«”’–—…]|$)",
            with: "",
            options: .regularExpression
        )

        return repaired
    }

    nonisolated private static func mojibakeMarkerCount(in input: String) -> Int {
        mojibakeMarkers.reduce(into: 0) { total, marker in
            total += input.components(separatedBy: marker).count - 1
        }
    }
}
