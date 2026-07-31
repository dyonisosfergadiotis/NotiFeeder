import SwiftUI
import Foundation

struct ArticleCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var unreadTintProgress: CGFloat
    @State private var textColumnHeight: CGFloat = ArticleCardLayout.fallbackThumbnailHeight

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
    let isSelected: Bool
    let selectionAccent: Color
    let highlightTerm: String?
    let highlightColor: Color
    let useFullColorBackground: Bool

    private let titleFont = Font.system(size: 15, weight: .semibold)
    private let summaryFont = Font.system(size: 12.5)

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
         isSelected: Bool = false,
         selectionAccent: Color = .accentColor,
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
        self.isSelected = isSelected
        self.selectionAccent = selectionAccent
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
        HStack(alignment: .top, spacing: ArticleCardLayout.thumbnailTextSpacing) {
            ArticleCardThumbnailView(url: thumbnailURL,
                                     feedColor: feedColor,
                                     readProgress: CGFloat(readProgress),
                                     height: textColumnHeight)

            VStack(alignment: .leading, spacing: 3) {
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsTightening(true)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .layoutPriority(1)

                Group {
                    if hasSummary, let summary {
                        highlightableText(for: summary, baseColor: summaryColor)
                    } else {
                        Text("\n")
                            .foregroundStyle(.clear)
                            .accessibilityHidden(true)
                    }
                }
                .font(summaryFont)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity,
                       alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: ArticleCardTextHeightPreferenceKey.self,
                                    value: proxy.size.height)
                }
            }
        }
        .padding(ArticleCardLayout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: ArticleCardLayout.cardCornerRadius, style: .continuous)
                    .fill(selectionAccent.opacity(colorScheme == .dark ? 0.10 : 0.065))
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .shadow(
            color: isSelected ? selectionAccent.opacity(colorScheme == .dark ? 0.24 : 0.14) : .clear,
            radius: isSelected ? 9 : 0,
            y: isSelected ? 3 : 0
        )
        .contentShape(RoundedRectangle(cornerRadius: ArticleCardLayout.cardCornerRadius, style: .continuous))
        .onPreferenceChange(ArticleCardTextHeightPreferenceKey.self) { newHeight in
            let measuredHeight = max(1, newHeight)
            guard abs(textColumnHeight - measuredHeight) > 0.5 else { return }
            textColumnHeight = measuredHeight
        }
        .onChange(of: isRead) { _, newIsRead in
            withAnimation(.easeInOut(duration: 0.24)) {
                unreadTintProgress = newIsRead ? 0 : 1
            }
        }
        .animation(.smooth(duration: 0.24, extraBounce: 0.02), value: isSelected)
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: ArticleCardLayout.cardCornerRadius, style: .continuous)
            .fill(cardFill)
            .overlay {
                RoundedRectangle(cornerRadius: ArticleCardLayout.cardCornerRadius, style: .continuous)
                    .strokeBorder(cardStroke, lineWidth: 1)
            }
    }

    private var cardFill: some ShapeStyle {
        LinearGradient(
            colors: [
                feedColor.opacity(cardTintOpacity),
                feedColor.opacity(cardTintOpacity * 0.55),
                Color(.secondarySystemBackground).opacity(cardNeutralOpacity)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardTintOpacity: Double {
        let contrastBoost = colorSchemeContrast == .increased ? 0.05 : 0
        if useFullColorBackground {
            return min(1, interpolate(unread: colorScheme == .dark ? 0.28 : 0.26,
                                      read: colorScheme == .dark ? 0.18 : 0.16) + contrastBoost)
        }
        return min(1, interpolate(unread: colorScheme == .dark ? 0.16 : 0.15,
                                  read: colorScheme == .dark ? 0.10 : 0.10) + contrastBoost)
    }

    private var cardNeutralOpacity: Double {
        useFullColorBackground
        ? (colorScheme == .dark ? 0.28 : 0.58)
        : (colorScheme == .dark ? 0.46 : 0.74)
    }

    private var cardStroke: Color {
        let contrastBoost = colorSchemeContrast == .increased ? 0.12 : 0
        let base = useFullColorBackground
        ? interpolate(unread: colorScheme == .dark ? 0.50 : 0.48,
                      read: colorScheme == .dark ? 0.30 : 0.30)
        : interpolate(unread: colorScheme == .dark ? 0.34 : 0.34,
                      read: colorScheme == .dark ? 0.20 : 0.22)
        return feedColor.opacity(min(1, base + contrastBoost))
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

private enum ArticleCardLayout {
    static let thumbnailWidth: CGFloat = 76
    static let fallbackThumbnailHeight: CGFloat = 76
    static let thumbnailCornerRadius: CGFloat = 10
    static let thumbnailTextSpacing: CGFloat = 10
    static let cardInset: CGFloat = 8
    static let cardCornerRadius: CGFloat = 15
}

private struct ArticleCardTextHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = ArticleCardLayout.fallbackThumbnailHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ArticleCardThumbnailView: View {
    let url: URL?
    let feedColor: Color
    let readProgress: CGFloat
    let height: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var loadedImage: UIImage?
    @State private var loadedImageURL: URL?

    init(url: URL?, feedColor: Color, readProgress: CGFloat, height: CGFloat) {
        self.url = url
        self.feedColor = feedColor
        self.readProgress = readProgress
        self.height = height
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
        .frame(width: ArticleCardLayout.thumbnailWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: ArticleCardLayout.thumbnailCornerRadius, style: .continuous))
        .overlay(thumbnailEdgeFade)
        .overlay(
            RoundedRectangle(cornerRadius: ArticleCardLayout.thumbnailCornerRadius, style: .continuous)
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
            let maxPixelSize = max(120, max(ArticleCardLayout.thumbnailWidth, height) * displayScale)
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
            RoundedRectangle(cornerRadius: ArticleCardLayout.thumbnailCornerRadius, style: .continuous)
                .fill(feedColor.opacity(0.12))
            Image(systemName: "photo")
                .font(.system(size: 18))
                .fontWeight(.light)
                .foregroundStyle(feedColor.opacity(0.9))
        }
    }

    private var thumbnailEdgeFade: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(0.16), Color.clear],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: 12)

                Spacer(minLength: 0)

                LinearGradient(colors: [Color.clear, Color.black.opacity(0.14)],
                               startPoint: .top,
                               endPoint: .bottom)
                    .frame(height: 12)
            }

            HStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(0.12), Color.clear],
                               startPoint: .leading,
                               endPoint: .trailing)
                    .frame(width: 10)

                Spacer(minLength: 0)

                LinearGradient(colors: [Color.clear, Color.black.opacity(0.12)],
                               startPoint: .leading,
                               endPoint: .trailing)
                    .frame(width: 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: ArticleCardLayout.thumbnailCornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }

    private func interpolate(unread: Double, read: Double) -> Double {
        let clampedReadProgress = min(1.0, max(0.0, Double(readProgress)))
        return unread + (read - unread) * clampedReadProgress
    }

}
