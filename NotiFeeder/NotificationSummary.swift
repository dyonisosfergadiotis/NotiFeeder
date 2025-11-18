import Foundation
import NaturalLanguage

struct NotificationSummary {
    static func summarize(entry: FeedEntry, limit: Int = 160) -> String {
        let candidate = sourceText(from: entry)
        let sentences = tokenizeSentences(in: candidate)

        var selectedSentences: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            selectedSentences.append(trimmed)
            if selectedSentences.count == 2 {
                break
            }
        }

        let summaryText = selectedSentences.joined(separator: " ")
        if !summaryText.isEmpty {
            return trimmed(summaryText, limit: limit)
        }

        return fallbackText(for: entry, original: candidate, limit: limit)
    }

    private static func sourceText(from entry: FeedEntry) -> String {
        if !entry.shortTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return entry.shortTitle
        }

        if !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return entry.content
        }

        return entry.title
    }

    private static func tokenizeSentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(String(text[range]))
            return true
        }
        return sentences
    }

    private static func fallbackText(for entry: FeedEntry, original: String, limit: Int) -> String {
        let stripped = HTMLText.stripHTML(original)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !stripped.isEmpty {
            return trimmed(stripped, limit: limit)
        }

        if let author = entry.author, !author.isEmpty {
            return "Von \(author)"
        }

        if let feed = entry.sourceTitle, !feed.isEmpty {
            return "Neuer Artikel auf \(feed)"
        }

        return "Neuer Artikel verfügbar"
    }

    static func trimmed(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        var candidate = String(text[..<idx])
        if let lastSpace = candidate.lastIndex(of: " ") {
            candidate = String(candidate[..<lastSpace])
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
