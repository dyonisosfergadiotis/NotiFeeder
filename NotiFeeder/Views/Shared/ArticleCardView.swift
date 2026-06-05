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
    let highlightTerm: String?
    let highlightColor: Color
    let useFullColorBackground: Bool
    @ScaledMetric(relativeTo: .headline) private var titleLineHeight: CGFloat = 20

    init(feedTitle: String,
         feedColor: Color,
         articleLink: String? = nil,
         title: String,
         summary: String?,
         imageURL: String? = nil,
         isRead: Bool,
         date: Date?,
         isBookmarked: Bool,
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
        guard let imageURL else { return nil }
        let trimmed = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard let articleLink,
              let articleURL = URL(string: articleLink) else {
            return URL(string: trimmed)
        }

        return URL(string: trimmed, relativeTo: articleURL)?.absoluteURL
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 12) {
                ArticleCardThumbnailView(url: thumbnailURL,
                                         feedColor: feedColor,
                                         readProgress: CGFloat(readProgress))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        highlightableText(for: title, baseColor: titleColor)
                            .appTitle()
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .allowsTightening(true)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(minHeight: titleLineHeight * 2, alignment: .topLeading)
                            .layoutPriority(1)

                        if isBookmarked {
                            Spacer(minLength: 0)
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .fontWeight(.light)
                                .foregroundStyle(UIStylePolicy.neutralIcon)
                        }
                    }

                    if hasSummary, let summary {
                        highlightableText(for: summary, baseColor: summaryColor)
                            .appSecondary()
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                cardSurface
            }
            .compositingGroup()
            .shadow(color: .black.opacity(primaryShadowOpacity),
                    radius: primaryShadowRadius,
                    x: 0,
                    y: primaryShadowYOffset)
            .shadow(color: feedColor.opacity(accentShadowOpacity),
                    radius: accentShadowRadius,
                    x: 0,
                    y: accentShadowYOffset)
        }
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

    private var readCardBackground: Color {
        Color(feedColor).opacity(readBackgroundOpacity)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    @ViewBuilder
    private var cardSurface: some View {
        cardShape
            .fill(cardBaseSurface)
            .overlay { cardBaseTint }
            .overlay { cardTintOverlay }
            .overlay {
                cardShape
                    .strokeBorder(feedColor.opacity(cardBorderOpacity), lineWidth: 1)
                    .clipped()
            }
            .overlay {
                cardShape
                    .strokeBorder(Color.primary.opacity(cardInnerStrokeOpacity), lineWidth: 1)
            }
    }

    private var cardBaseSurface: Color {
        colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemBackground)
    }

    @ViewBuilder
    private var cardBaseTint: some View {
        if useFullColorBackground {
            cardShape
                .fill(Color(feedColor).opacity(currentBackgroundOpacity))
        } else {
            cardShape
                .fill(readCardBackground)
        }
    }

    private var currentBackgroundOpacity: Double {
        interpolate(unread: unreadBackgroundOpacity, read: readBackgroundOpacity)
    }

    private var fullColorEdgeBoostOpacity: Double {
        max(0.0, currentBackgroundOpacity - UIStylePolicy.fullColorCardInteriorOpacity)
    }

    private var fullColorEdgeTransitionWidth: CGFloat {
        colorSchemeContrast == .increased ? 5.2 : 3.2
    }

    private var fullColorEdgeBlurRadius: CGFloat {
        colorSchemeContrast == .increased ? 1.8 : 1.1
    }

    @ViewBuilder
    private var cardTintOverlay: some View {
        if !useFullColorBackground {
            unreadTintOverlay
        }
    }

    @ViewBuilder
    private var fullColorEdgeOverlay: some View {
        if fullColorEdgeBoostOpacity > 0.001 {
            cardShape
                .strokeBorder(Color(feedColor).opacity(fullColorEdgeBoostOpacity),
                              lineWidth: fullColorEdgeTransitionWidth)
                .blur(radius: fullColorEdgeBlurRadius)
                .clipShape(cardShape)
                .allowsHitTesting(false)
        }
    }

    private var unreadTintOverlayOpacity: Double {
        max(0, unreadBackgroundOpacity - readBackgroundOpacity)
    }

    @ViewBuilder
    private var unreadTintOverlay: some View {
        let currentOpacity = unreadTintOverlayOpacity * unreadProgress
        if currentOpacity > 0.001 {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(feedColor).opacity(currentOpacity))
                .allowsHitTesting(false)
        }
    }

    private var readBackgroundOpacity: Double {
        let contrastBoost = colorSchemeContrast == .increased ? 0.06 : 0
        if !useFullColorBackground {
            let lightModeBoost = colorScheme == .light ? 0.07 : 0
            return min(1.0, UIStylePolicy.cardTintOpacityRead + contrastBoost + lightModeBoost)
        }
        let lightModeBoost = colorScheme == .light ? 0.06 : 0
        return min(1.0, UIStylePolicy.fullColorCardTintOpacityRead + contrastBoost + lightModeBoost)
    }

    private var unreadBackgroundOpacity: Double {
        let contrastBoost = colorSchemeContrast == .increased ? 0.06 : 0
        if !useFullColorBackground {
            let lightModeBoost = colorScheme == .light ? 0.10 : 0
            return min(1.0, UIStylePolicy.cardTintOpacity + contrastBoost + lightModeBoost)
        }
        let lightModeBoost = colorScheme == .light ? 0.08 : 0
        return min(1.0, UIStylePolicy.fullColorCardTintOpacity + contrastBoost + lightModeBoost)
    }

    private var cardBorderOpacity: Double {
        if colorScheme == .light {
            return interpolate(unread: 0.56, read: 0.24)
        }
        return interpolate(unread: UIStylePolicy.cardBorderOpacityUnread,
                           read: UIStylePolicy.cardBorderOpacityRead)
    }

    private var cardInnerStrokeOpacity: Double {
        let unreadOpacity = colorScheme == .light ? 0.12 : UIStylePolicy.cardInnerStrokeOpacityUnread
        return unreadOpacity * unreadProgress
    }

    private var primaryShadowOpacity: Double {
        interpolate(unread: 0.08, read: 0.035)
    }

    private var primaryShadowRadius: CGFloat {
        CGFloat(interpolate(unread: 7, read: 3))
    }

    private var primaryShadowYOffset: CGFloat {
        CGFloat(interpolate(unread: 4, read: 1.5))
    }

    private var accentShadowOpacity: Double {
        interpolate(unread: 0.08, read: 0)
    }

    private var accentShadowRadius: CGFloat {
        CGFloat(interpolate(unread: 7, read: 0))
    }

    private var accentShadowYOffset: CGFloat {
        CGFloat(interpolate(unread: 3, read: 0))
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

private struct ArticleCardThumbnailView: View {
    let url: URL?
    let feedColor: Color
    let readProgress: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                thumbnailPlaceholder(showsLoadingStyle: isLoading)
            }
        }
        .frame(width: 90, height: 90)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(feedColor.opacity(interpolate(unread: 0.38, read: 0.22)), lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(interpolate(unread: 0.09, read: 0.045)),
                radius: interpolateCGFloat(unread: 7, read: 3),
                x: 0,
                y: interpolateCGFloat(unread: 3, read: 1))
        .shadow(color: feedColor.opacity(interpolate(unread: 0.10, read: 0)),
                radius: interpolateCGFloat(unread: 7, read: 0),
                x: 0,
                y: interpolateCGFloat(unread: 3, read: 0))
        .task(id: url) {
            guard let url else {
                loadedImage = nil
                isLoading = false
                return
            }

            loadedImage = nil
            let effectiveURL = OfflineArticleArchive.cachedAssetFileURL(for: url) ?? url
            if !effectiveURL.isFileURL {
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
            }

            isLoading = true
            defer { isLoading = false }
            let maxPixelSize = max(140, 90 * displayScale * 2)
            let image = await ArticleImagePipeline.shared.image(for: effectiveURL, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            loadedImage = image
        }
    }

    @ViewBuilder
    private func thumbnailPlaceholder(showsLoadingStyle: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(feedColor.opacity(showsLoadingStyle ? 0.16 : 0.12))
            Image(systemName: "photo")
                .font(.system(size: 18))
                .fontWeight(.light)
                .foregroundStyle(feedColor.opacity(showsLoadingStyle ? 1.0 : 0.9))
        }
    }

    private func interpolate(unread: Double, read: Double) -> Double {
        let clampedReadProgress = min(1.0, max(0.0, Double(readProgress)))
        return unread + (read - unread) * clampedReadProgress
    }

    private func interpolateCGFloat(unread: CGFloat, read: CGFloat) -> CGFloat {
        let clampedReadProgress = min(1.0, max(0.0, readProgress))
        return unread + (read - unread) * clampedReadProgress
    }
}
