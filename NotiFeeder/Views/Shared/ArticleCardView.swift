import SwiftUI
import Foundation

struct ArticleCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var unreadTintProgress: CGFloat

    let feedTitle: String
    let feedColor: Color
    let articleLink: String?
    let title: String
    let summary: String?
    let imageURL: String?
    let isRead: Bool
    let date: Date?
    let isBookmarked: Bool
    let isActiveArticle: Bool
    let highlightTerm: String?
    let highlightColor: Color
    let useFullColorBackground: Bool

    private let titleFont = Font.system(size: 16, weight: .semibold)
    private let summaryFont = Font.system(size: 13)
    private let titleLineHeight: CGFloat = 19
    private let summaryLineHeight: CGFloat = 16

    init(feedTitle: String,
         feedColor: Color,
         articleLink: String? = nil,
         title: String,
         summary: String?,
         imageURL: String? = nil,
         isRead: Bool,
         date: Date?,
         isBookmarked: Bool,
         isActiveArticle: Bool = false,
         highlightTerm: String? = nil,
         highlightColor: Color = .accentColor,
         useFullColorBackground: Bool = false) {
        self.feedTitle = feedTitle
        self.feedColor = feedColor
        self.articleLink = articleLink
        self.title = title
        self.summary = summary
        self.imageURL = imageURL
        self.isRead = isRead
        self.date = date
        self.isBookmarked = isBookmarked
        self.isActiveArticle = isActiveArticle
        self.highlightTerm = highlightTerm
        self.highlightColor = highlightColor
        self.useFullColorBackground = useFullColorBackground
        _unreadTintProgress = State(initialValue: isRead ? 0 : 1)
    }

    private var hasSummary: Bool {
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    private var thumbnailURL: URL? {
        ArticleImagePipeline.resolvedThumbnailURL(
            imageURL: imageURL,
            articleLink: articleLink
        )
    }

    private var articleTimeText: String? {
        guard let date, date != .distantPast else { return nil }
        return DateFormatter.timeOnly.string(from: date)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArticleCardThumbnailView(url: thumbnailURL,
                                     feedColor: feedColor,
                                     readProgress: CGFloat(readProgress))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(feedTitle)
                        .font(.caption)
                        .fontWeight(isRead ? .regular : .semibold)
                        .foregroundStyle(feedColor)
                        .lineLimit(1)

                    if let articleTimeText {
                        Text(articleTimeText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if isActiveArticle {
                        Image(systemName: "book.pages.fill")
                            .font(.caption)
                            .foregroundStyle(feedColor)
                    }

                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(UIStylePolicy.neutralIcon)
                    }
                }

                highlightableText(for: title, baseColor: titleColor)
                    .font(titleFont)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .allowsTightening(true)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: titleLineHeight * 2, alignment: .topLeading)
                    .layoutPriority(1)

                if hasSummary, let summary {
                    highlightableText(for: summary, baseColor: summaryColor)
                        .font(summaryFont)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity,
                               maxHeight: summaryLineHeight * 2,
                               alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onChange(of: isRead) { _, newIsRead in
            withAnimation(.easeInOut(duration: 0.24)) {
                unreadTintProgress = newIsRead ? 0 : 1
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
        let opacity = colorSchemeContrast == .increased
        ? min(1.0, UIStylePolicy.summaryTextOpacity + 0.18)
        : UIStylePolicy.summaryTextOpacity
        return isRead ? Color.secondary.opacity(opacity) : Color.primary.opacity(opacity)
    }

    private var unreadProgress: Double {
        min(1.0, max(0.0, Double(unreadTintProgress)))
    }

    private var readProgress: Double {
        1.0 - unreadProgress
    }

    private func interpolate(unread: Double, read: Double) -> Double {
        unread + (read - unread) * readProgress
    }
    
    private func highlightableText(for content: String, baseColor: Color) -> Text {
        let tokens = normalizedHighlightTokens
        guard !tokens.isEmpty else {
            return Text(content).foregroundColor(baseColor)
        }

        let ranges = mergedHighlightRanges(in: content, tokens: tokens)
        var attributed = AttributedString(content)
        attributed.foregroundColor = baseColor

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

private struct ArticleCardThumbnailView: View {
    let url: URL?
    let feedColor: Color
    let readProgress: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var loadedImage: UIImage?
    @State private var loadedImageURL: URL?

    init(url: URL?, feedColor: Color, readProgress: CGFloat) {
        self.url = url
        self.feedColor = feedColor
        self.readProgress = readProgress
        let cachedImage = url.flatMap { ArticleImagePipeline.shared.cachedImage(for: $0) }
        _loadedImage = State(initialValue: cachedImage)
        _loadedImageURL = State(initialValue: cachedImage == nil ? nil : url)
    }

    var body: some View {
        Group {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                thumbnailPlaceholder
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(feedColor.opacity(interpolate(unread: 0.38, read: 0.22)), lineWidth: 1)
        )
        .task(id: url, priority: .userInitiated) {
            guard let url else {
                loadedImage = nil
                loadedImageURL = nil
                return
            }

            if loadedImageURL == url, loadedImage != nil {
                return
            }
            if let cachedImage = ArticleImagePipeline.shared.cachedImage(for: url) {
                loadedImage = cachedImage
                loadedImageURL = url
                return
            }
            guard !ArticleImagePipeline.shared.isTemporarilyMissing(url) else {
                return
            }

            loadedImage = nil
            loadedImageURL = nil
            let maxPixelSize = max(120, 76 * displayScale)
            let image = await ArticleImagePipeline.shared.thumbnailImage(
                for: url,
                maxPixelSize: maxPixelSize,
                priority: .userInitiated
            )
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadedImageURL = image == nil ? nil : url
        }
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(feedColor.opacity(0.12))
            Image(systemName: "photo")
                .font(.system(size: 18))
                .fontWeight(.light)
                .foregroundStyle(feedColor.opacity(0.9))
        }
    }

    private func interpolate(unread: Double, read: Double) -> Double {
        let clampedReadProgress = min(1.0, max(0.0, Double(readProgress)))
        return unread + (read - unread) * clampedReadProgress
    }

}
