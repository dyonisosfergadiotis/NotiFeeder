import SwiftUI
import Foundation

struct ArticleCardView: View {
    let feedTitle: String
    let feedColor: Color
    let title: String
    let summary: String?
    let isRead: Bool
    let date: Date?
    let isBookmarked: Bool
    let highlightTerm: String?
    let highlightColor: Color
    let previewLineCount: Int
    let useFullColorBackground: Bool

    init(feedTitle: String,
         feedColor: Color,
         title: String,
         summary: String?,
         isRead: Bool,
         date: Date?,
         isBookmarked: Bool,
         highlightTerm: String? = nil,
         highlightColor: Color = .accentColor,
         previewLineCount: Int = 3,
         useFullColorBackground: Bool = false) {
        self.feedTitle = feedTitle
        self.feedColor = feedColor
        self.title = title
        self.summary = summary
        self.isRead = isRead
        self.date = date
        self.isBookmarked = isBookmarked
        self.highlightTerm = highlightTerm
        self.highlightColor = highlightColor
        self.previewLineCount = previewLineCount
        self.useFullColorBackground = useFullColorBackground
    }

    private var hasSummary: Bool {
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    private var formattedDate: String? {
        guard let date else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return DateFormatter.timeOnly.string(from: date)
        } else {
            return DateFormatter.dateOnly.string(from: date)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(feedTitle)
                            .appSectionLabel()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(pillBackground, in: Capsule())
                            .foregroundStyle(Color.white.opacity(0.95))

                        Spacer()

                        HStack(spacing: 6) {
                            if isBookmarked {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption)
                                    .foregroundColor(feedColor)
                            }
                            if let formattedDate {
                                Text(formattedDate)
                                    .appMeta()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        highlightableText(for: title, baseColor: titleColor)
                            .appTitle()

                        if hasSummary, let summary {
                            highlightableText(for: summary, baseColor: summaryColor)
                                .appSecondary()
                                .lineLimit(previewLineCount)
                        }
                    }
                    .padding(.leading, 10)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(cardBackground)
                    //.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1).clipped()
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }

    private var normalizedHighlightTokens: [String] {
        guard let highlightTerm else { return [] }
        let trimmed = highlightTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private var titleColor: Color {
        isRead ? Color.secondary : Color.primary
    }

    private var summaryColor: Color {
        isRead ? Color.secondary.opacity(0.75) : Color.primary.opacity(0.75)
    }

    private var cardBackground: Color {
        if !useFullColorBackground {
            return Color(feedColor).opacity(0.12)
        }
        return isRead ? Color(feedColor).opacity(0.15) : Color(feedColor).opacity(0.5)
    }
    
    private var pillBackground: Color {
        !isRead ? Color(feedColor).opacity(0.5) : Color("#E5E5E7")
    }

    private func highlightableText(for content: String, baseColor: Color) -> Text {
        var attributed = AttributedString(content)
        attributed.foregroundColor = baseColor

        let tokens = normalizedHighlightTokens
        guard !tokens.isEmpty else {
            return Text(attributed)
        }

        let ranges = mergedHighlightRanges(in: content, tokens: tokens)
        guard !ranges.isEmpty else {
            return Text(attributed)
        }

        for range in ranges {
            if let attrRange = Range(range, in: attributed) {
                attributed[attrRange].foregroundColor = highlightColor
            }
        }

        return Text(attributed)
    }

    private func mergedHighlightRanges(in content: String, tokens: [String]) -> [Range<String.Index>] {
        var collected: [Range<String.Index>] = []
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        for token in tokens {
            var searchRange = content.startIndex..<content.endIndex
            while let match = content.range(of: token, options: options, range: searchRange) {
                collected.append(match)
                searchRange = match.upperBound..<content.endIndex
            }
        }

        guard !collected.isEmpty else { return [] }
        let sorted = collected.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []

        for range in sorted {
            guard var last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                if range.upperBound > last.upperBound {
                    last = last.lowerBound..<range.upperBound
                    merged[merged.count - 1] = last
                }
            } else {
                merged.append(range)
            }
        }

        return merged
    }
}
