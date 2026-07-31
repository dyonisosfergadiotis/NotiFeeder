import WebKit
import SwiftUI
import Foundation
import FoundationModels
import SwiftData
import UIKit
import CryptoKit
import Observation

extension Color {
    var rgbComponents: (red: Int, green: Int, blue: Int)? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        let resolvedColor = UIColor(self).resolvedColor(with: UITraitCollection.current)
        if !resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let components = resolvedColor.cgColor.components ?? []
            switch components.count {
            case 2:
                red = components[0]
                green = components[0]
                blue = components[0]
            case 3, 4:
                red = components[0]
                green = components[1]
                blue = components[2]
            default:
                return nil
            }
        }

        return (
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

private enum FeedDetailLayout {
    static let expandedHeaderHeight: CGFloat = 128
    static let headerCollapseOffset: CGFloat = 40
    static let headerMetadataHeight: CGFloat = 18
    static let headerDateHeight: CGFloat = 16
    static let navigationBarHeight: CGFloat = 64
    static let navigationRevealDistance: CGFloat = 0.48
    static let compactPresentationSingleLineHeight: CGFloat = 78
    static let compactPresentationDoubleLineHeight: CGFloat = 96
    static let presentationTransitionDistance: CGFloat = 180
    static let compactHorizontalInset: CGFloat = 20
    static let compactTopInset: CGFloat = 17
    static let compactBottomInset: CGFloat = 12
    static let compactToolbarHitTarget: CGFloat = 40
    static let headerCollapseRange: CGFloat = 150

    static func clampedProgress(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    static func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = clampedProgress(value)
        return t * t * (3 - 2 * t)
    }
}

private struct FeedDetailHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = FeedDetailLayout.expandedHeaderHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FeedDetailHeaderTitleHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@Observable
private final class FeedDetailScrollState {
    var collapseProgress: CGFloat = 0

    func reset(collapseProgress: CGFloat = 0) {
        self.collapseProgress = FeedDetailLayout.clampedProgress(collapseProgress)
    }
}

private struct FeedDetailCollapsingNavigationBar: View {
    let title: String
    let tint: Color
    let isSummaryMode: Bool
    let scrollState: FeedDetailScrollState

    private var revealProgress: CGFloat {
        let collapseProgress = isSummaryMode ? 0 : scrollState.collapseProgress
        return FeedDetailLayout.smoothstep(
            collapseProgress / FeedDetailLayout.navigationRevealDistance
        )
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: FeedDetailLayout.navigationBarHeight)
            .background(tint)
            .overlay(alignment: .bottom) {
                Divider()
                    .opacity(0.35)
            }
            .offset(
                y: -FeedDetailLayout.navigationBarHeight
                    * (1 - revealProgress)
            )
            .opacity(revealProgress)
            .allowsHitTesting(false)
            .zIndex(3)
    }
}

private struct FeedDetailCollapsingHeader<Content: View>: View {
    let scrollState: FeedDetailScrollState
    let isSummaryMode: Bool
    let headerHeight: CGFloat
    let content: Content

    init(
        scrollState: FeedDetailScrollState,
        isSummaryMode: Bool,
        headerHeight: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.scrollState = scrollState
        self.isSummaryMode = isSummaryMode
        self.headerHeight = headerHeight
        self.content = content()
    }

    private var visibleCollapseProgress: CGFloat {
        isSummaryMode ? 0 : scrollState.collapseProgress
    }

    var body: some View {
        content
            .offset(y: -headerHeight * visibleCollapseProgress)
            .zIndex(2)
    }
}

struct FeedDetailView: View {
    static func compactPresentationHeight(for title: String, availableWidth: CGFloat) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let measuredHeight = (title as NSString).boundingRect(
            with: CGSize(width: max(1, availableWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        return measuredHeight > font.lineHeight * 1.35
            ? FeedDetailLayout.compactPresentationDoubleLineHeight
            : FeedDetailLayout.compactPresentationSingleLineHeight
    }

    static func compactPresentationDetent(height: CGFloat) -> PresentationDetent {
        .height(height)
    }

    private static let imageTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "<img\\b", options: [.caseInsensitive])
    }()
    private static let readerImageTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive])
    }()
    private static let readerIframeTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<iframe\b[\s\S]*?</iframe\s*>|<iframe\b[^>]*?/?>"#, options: [.caseInsensitive])
    }()
    private static let readerVideoTagRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"<video\b[\s\S]*?</video\s*>|<video\b[^>]*?/?>"#, options: [.caseInsensitive])
    }()
    private static let readingTimeCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 512
        return cache
    }()
    private static let formattedHTMLCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 64
        cache.totalCostLimit = 24 * 1_024 * 1_024
        return cache
    }()
    private static let readerHTMLRenderVersion = "reader-rollout-v5"

    var entry: FeedEntry
    var feedColor: Color?
    var entriesProvider: () -> [FeedEntry] = { [] }
    var onNavigateToEntry: (FeedEntry, NavigationDirection) -> Void = { _, _ in }
    /// Optional callback invoked when the read/unread state is toggled in this detail view.
    var onToggleRead: ((Bool) -> Void)? = nil
    /// Optional callback invoked when bookmark state changes in this detail view.
    var onToggleBookmark: ((Bool) -> Void)? = nil
    var initialHeaderCollapseProgress: CGFloat = 0
    var isCompactPresentation: Bool = false
    var compactPresentationHeight: CGFloat = FeedDetailLayout.compactPresentationDoubleLineHeight
    var onExpandPresentation: () -> Void = {}
    var onMinimizePresentation: () -> Void = {}
    var onClosePresentation: () -> Void = {}

    enum NavigationDirection {
        case previous
        case next
    }

    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var store: ArticleStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var scrollState = FeedDetailScrollState()
    @State private var headerHeight: CGFloat = FeedDetailLayout.expandedHeaderHeight
    @State private var isHeaderTitleSingleLine = false
    @State private var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.underPageBackgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.showsHorizontalScrollIndicator = false
        return wv
    }()
    
    @State private var activeSheet: ActiveSheet?
    @State private var isSummaryMode = false
    @State private var isSummaryGenerating = false
    @State private var showsAppleAILabel = false
    @State private var appleAILabelRequestID = 0
    @State private var summaryRainbowRevealProgress: CGFloat = 0
    @State private var summaryRainbowCompletionProgress: CGFloat = 0
    @State private var summaryContentVisibility: Double = 0
    @State private var articleCollapseProgressBeforeSummary: CGFloat = 0
    @State private var summaryDismissRequestID = 0
    @State private var summaryRegenerationRequestID = 0
    @State private var summarySharePayload: String?
    @State private var isSummaryDismissAnimating = false
    @State private var isReadLocal: Bool = false
    @State private var isBookmarked: Bool = false
    @State private var pendingNavigationDirection: NavigationDirection?
    @State private var pendingInitialHeaderCollapseProgress: CGFloat
    @State private var contentOffset: CGFloat = 0
    @State private var contentOpacity: Double = 1
    @State private var hasAppeared = false
    @State private var measuredPresentationExpansion: CGFloat = 1
    @AppStorage("readerFontScale") private var readerFontScale: Double = 1.0
    @AppStorage("readerFontFamily") private var readerFontFamily: String = ReaderFontFamily.rounded.rawValue
    @AppStorage("readerLineSpacing") private var readerLineSpacing: Double = 1.4
    @AppStorage("readerTextAlignment") private var readerTextAlignmentRaw: String = "left"
    @AppStorage("readerParagraphSpacing") private var readerParagraphSpacing: Double = 0.72
    @AppStorage("readerContentWidth") private var readerContentWidth: Double = 720

    private enum ActiveSheet: Identifiable {
        case share(payload: String, token: UUID = UUID())
        case readerSettings
        var id: UUID {
            switch self {
            case .share(_, let token): return token
            case .readerSettings: return ActiveSheet.readerSettingsID
            }
        }
        private static let readerSettingsID = UUID()
    }

    init(entry: FeedEntry,
         feedColor: Color? = nil,
         onToggleRead: ((Bool) -> Void)? = nil,
         onToggleBookmark: ((Bool) -> Void)? = nil,
         initialHeaderCollapseProgress: CGFloat = 0,
         isCompactPresentation: Bool = false,
         compactPresentationHeight: CGFloat = FeedDetailLayout.compactPresentationDoubleLineHeight,
         onExpandPresentation: @escaping () -> Void = {},
         onMinimizePresentation: @escaping () -> Void = {},
         onClosePresentation: @escaping () -> Void = {}) {
        self.entry = entry
        self.feedColor = feedColor
        self.onToggleRead = onToggleRead
        self.onToggleBookmark = onToggleBookmark
        self.initialHeaderCollapseProgress = FeedDetailLayout.clampedProgress(initialHeaderCollapseProgress)
        self.isCompactPresentation = isCompactPresentation
        self.compactPresentationHeight = compactPresentationHeight
        self.onExpandPresentation = onExpandPresentation
        self.onMinimizePresentation = onMinimizePresentation
        self.onClosePresentation = onClosePresentation
        _pendingInitialHeaderCollapseProgress = State(
            initialValue: FeedDetailLayout.clampedProgress(initialHeaderCollapseProgress)
        )
    }

    init(entry: FeedEntry,
         feedColor: Color? = nil,
         entriesProvider: @escaping () -> [FeedEntry],
         onNavigateToEntry: @escaping (FeedEntry, NavigationDirection) -> Void,
         onToggleRead: ((Bool) -> Void)? = nil,
         onToggleBookmark: ((Bool) -> Void)? = nil,
         initialHeaderCollapseProgress: CGFloat = 0,
         isCompactPresentation: Bool = false,
         compactPresentationHeight: CGFloat = FeedDetailLayout.compactPresentationDoubleLineHeight,
         onExpandPresentation: @escaping () -> Void = {},
         onMinimizePresentation: @escaping () -> Void = {},
         onClosePresentation: @escaping () -> Void = {}) {
        self.entry = entry
        self.feedColor = feedColor
        self.entriesProvider = entriesProvider
        self.onNavigateToEntry = onNavigateToEntry
        self.onToggleRead = onToggleRead
        self.onToggleBookmark = onToggleBookmark
        self.initialHeaderCollapseProgress = FeedDetailLayout.clampedProgress(initialHeaderCollapseProgress)
        self.isCompactPresentation = isCompactPresentation
        self.compactPresentationHeight = compactPresentationHeight
        self.onExpandPresentation = onExpandPresentation
        self.onMinimizePresentation = onMinimizePresentation
        self.onClosePresentation = onClosePresentation
        _pendingInitialHeaderCollapseProgress = State(
            initialValue: FeedDetailLayout.clampedProgress(initialHeaderCollapseProgress)
        )
    }

    private func currentIndex(in list: [FeedEntry]) -> Int? {
        list.firstIndex(where: { $0.link == entry.link })
    }

    private func goToPrevious() {
        let list = entriesProvider()
        guard !list.isEmpty, let currentIndex = currentIndex(in: list), currentIndex > list.startIndex else { return }
        let target = list[list.index(before: currentIndex)]
        pendingNavigationDirection = .previous
        AppHaptics.softImpact()
        resetArticlePosition(animated: true)
        withAnimation(.smooth(duration: 0.22)) { onNavigateToEntry(target, .previous) }
    }

    private func goToNext() {
        let list = entriesProvider()
        guard !list.isEmpty, let currentIndex = currentIndex(in: list) else { return }
        let nextIndex = list.index(after: currentIndex)
        guard nextIndex < list.endIndex else { return }
        let target = list[nextIndex]
        pendingNavigationDirection = .next
        AppHaptics.softImpact()
        resetArticlePosition(animated: true)
        withAnimation(.smooth(duration: 0.22)) { onNavigateToEntry(target, .next) }
    }

    private var publishDateLabel: String? {
        guard let dateString = entry.pubDateString, !dateString.isEmpty else { return nil }
        let parsed = DateParser.parse(dateString)
        return parsed != Date.distantPast ? DateFormatter.localized.string(from: parsed) : dateString
    }

    private var readingTimeLabel: String {
        let source = (entry.contentRaw?.isEmpty == false) ? entry.contentRaw! : entry.content
        let cacheKey = "\(entry.link)|\(source.count)" as NSString
        if let cached = Self.readingTimeCache.object(forKey: cacheKey) {
            return cached as String
        }

        let plainText = HTMLText.stripHTML(source)
        let wordCount = plainText.split { $0.isWhitespace || $0.isNewline }.count
        let imageCount = countImages(in: source)
        let wordsPerMinute = 210.0
        let textMinutes = Double(wordCount) / wordsPerMinute
        let imageMinutes = min(Double(imageCount) * 12.0 / 60.0, 1.0)
        let minutes = max(1, Int(ceil(textMinutes + imageMinutes)))
        let label = "\(minutes) Min."
        Self.readingTimeCache.setObject(label as NSString, forKey: cacheKey)
        return label
    }

    private func countImages(in html: String) -> Int {
        guard let regex = Self.imageTagRegex else {
            return 0
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.numberOfMatches(in: html, options: [], range: range)
    }

    private func animateEntryTransition() {
        let direction = pendingNavigationDirection
        pendingNavigationDirection = nil

        let startOffset: CGFloat
        switch direction {
        case .next:
            startOffset = 26
        case .previous:
            startOffset = -26
        case .none:
            startOffset = 14
        }

        contentOffset = startOffset
        contentOpacity = 0
        withAnimation(.easeOut(duration: 0.24)) {
            contentOffset = 0
            contentOpacity = 1
        }
    }

    private var effectiveHeaderHeight: CGFloat {
        max(FeedDetailLayout.expandedHeaderHeight, headerHeight)
    }

    private var articleSummarySourceText: String {
        let rawSummary = entry.contentRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preferredSource = rawSummary.isEmpty ? entry.content : HTMLText.stripHTML(rawSummary)
        return HTMLText.normalizePreviewSpacing(in: preferredSource)
    }

    private var headerTitleLineHeight: CGFloat {
        let preferredFont = UIFont.preferredFont(forTextStyle: .title3)
        return UIFont.systemFont(ofSize: preferredFont.pointSize, weight: .semibold).lineHeight
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: FeedDetailHeaderTitleHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .frame(
                    minHeight: headerTitleLineHeight * 2,
                    alignment: .topLeading
                )

            HStack(spacing: 4) {
                Text("\(entry.author ?? "Unbekannt")")
                Text("·")
                Text(entry.sourceTitle ?? "Unbekannte Quelle")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: FeedDetailLayout.headerMetadataHeight, alignment: .leading)

            HStack(spacing: 8) {
                if let publishDateLabel {
                    Text(publishDateLabel)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    if isSummaryMode {
                        Button(action: revealAppleAILabel) {
                            Image(systemName: "sparkles")
                                .fontWeight(.medium)
                                .foregroundStyle(resolvedFeedColor)
                                .symbolEffect(
                                    .variableColor.iterative,
                                    options: .repeating,
                                    isActive: isSummaryGenerating
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Apple AI-Information anzeigen")

                        if showsAppleAILabel {
                            Text("Generiert mit Apple AI")
                                .transition(.opacity)
                        }
                    } else {
                        Image(systemName: "eyeglasses")
                            .fontWeight(.light)
                        Text(readingTimeLabel)
                    }
                }
                .multilineTextAlignment(.trailing)
            }
            .font(.footnote)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(height: FeedDetailLayout.headerDateHeight, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.bottom)
        .frame(height: FeedDetailLayout.expandedHeaderHeight, alignment: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .padding(.top)
        .onPreferenceChange(FeedDetailHeaderTitleHeightKey.self) { measuredHeight in
            guard measuredHeight > 0 else { return }
            isHeaderTitleSingleLine = measuredHeight < headerTitleLineHeight * 1.5
        }
    }

    @ToolbarContentBuilder
    private var dynamicBottomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            toolbarReadButton
            toolbarBookmarkButton
            summaryToolbarButton
            if isSummaryMode {
                regenerateSummaryToolbarButton
            }
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            minimizePresentationButton
        }

        ToolbarSpacer(.fixed, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            secondaryActionsMenu
        }
    }

    private var minimizePresentationButton: some View {
        Button {
            AppHaptics.selection()
            onMinimizePresentation()
        } label: {
            Image(systemName: "tray.and.arrow.down")
                .fontWeight(.light)
                .foregroundStyle(resolvedFeedColor)
        }
        .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
        .accessibilityLabel("Reader minimieren")
    }

    private var toolbarBookmarkButton: some View {
        Button(action: toggleBookmark) {
            ZStack {
                Image(systemName: "bookmark")
                    .font(.system(size: 18))
                    .fontWeight(.light)
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 18))
                    .fontWeight(.light)
                    .mask(Rectangle().scaleEffect(y: isBookmarked ? 1 : 0, anchor: .top))
            }
        }
        .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
        .accessibilityLabel(isBookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen")
        .foregroundStyle(isBookmarked ? resolvedFeedColor : UIStylePolicy.neutralIcon)
    }

    private var toolbarReadButton: some View {
        Button(action: { onToggleReadAction() }) {
            Image(systemName: isReadLocal ? "eye.slash" : "eye")
                .fontWeight(.light)
                .foregroundStyle(isReadLocal ? resolvedFeedColor : UIStylePolicy.neutralIcon)
        }
        .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
        .accessibilityLabel(isReadLocal ? "Als ungelesen markieren" : "Als gelesen markieren")
    }

    private var summaryToolbarButton: some View {
        Button {
            AppHaptics.selection()
            toggleSummaryMode()
        } label: {
            Image(systemName: "text.line.3.summary")
                .fontWeight(.light)
                .foregroundStyle(isSummaryMode ? resolvedFeedColor : UIStylePolicy.neutralIcon)
        }
        .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
        .accessibilityLabel(isSummaryMode ? "Artikel anzeigen" : "Zusammenfassung anzeigen")
    }

    private var regenerateSummaryToolbarButton: some View {
        Button {
            AppHaptics.selection()
            prepareSummaryForRegeneration()
            summaryRegenerationRequestID += 1
        } label: {
            Image(systemName: "arrow.clockwise")
                .fontWeight(.light)
                .foregroundStyle(isSummaryGenerating ? UIStylePolicy.neutralIcon : resolvedFeedColor)
        }
        .disabled(isSummaryGenerating)
        .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
        .accessibilityLabel("Zusammenfassung neu erstellen")
    }

    private var secondaryActionsMenu: some View {
        Menu {
            Button {
                AppHaptics.selection()
                activeSheet = .readerSettings
            } label: {
                Label("Lesedarstellung", systemImage: "textformat.size")
                    .foregroundStyle(resolvedFeedColor)
            }

            Button {
                AppHaptics.lightImpact()
                if let url = URL(string: entry.link) { UIApplication.shared.open(url) }
            } label: {
                Label("In Safari öffnen", systemImage: "safari")
                    .foregroundStyle(resolvedFeedColor)
            }

            Button {
                AppHaptics.selection()
                shareCurrentContent()
            } label: {
                Label("Teilen", systemImage: "square.and.arrow.up")
                    .foregroundStyle(resolvedFeedColor)
            }
            .disabled(isSummaryMode && summarySharePayload == nil)
        } label: {
            Image(systemName: "ellipsis")
                .fontWeight(.light)
                .foregroundStyle(resolvedFeedColor)
        }
        .tint(resolvedFeedColor)
        .minimumHitTarget()
        .simultaneousGesture(
            TapGesture().onEnded {
                AppHaptics.selection()
            }
        )
        .accessibilityLabel("Weitere Aktionen")
    }

    private var showsBottomToolbar: Bool {
        !isCompactPresentation && measuredPresentationExpansion >= 0.9
    }

    private var ignoredContainerEdges: Edge.Set {
        [.top, .bottom]
    }
    
    private func onToggleReadAction() {
        isReadLocal.toggle()
        AppHaptics.selection()
        store.setRead(isReadLocal, articleID: entry.link)
        onToggleRead?(isReadLocal)
    }
    
    private func webAccentHexString() -> String {
        guard let components = resolvedFeedColor.rgbComponents else {
            return "#007AFF"
        }
        return String(format: "#%02X%02X%02X", components.red, components.green, components.blue)
    }

    var body: some View {
        let accentHex = webAccentHexString()
        let htmlContentID = formattedHTMLContentID(accentHex: accentHex)
        let htmlDocument = formattedHTML(
            accentHex: accentHex,
            contentID: htmlContentID
        )
        GeometryReader { proxy in
            let expansionProgress = presentationExpansionProgress(
                height: proxy.size.height,
                bottomSafeAreaInset: proxy.safeAreaInsets.bottom
            )
            let compactOpacity = compactPresentationOpacity(for: expansionProgress)
            let detailOpacity = detailPresentationOpacity(for: expansionProgress)
            let showsReaderBackToTop = showsReaderBackToTopButton(for: expansionProgress)

            ZStack(alignment: .top) {
                articleSurfaceBackground
                    .ignoresSafeArea()

                observedDetailRoot(
                    htmlDocument: htmlDocument,
                    htmlContentID: htmlContentID
                )
                    .opacity(detailOpacity)
                    .allowsHitTesting(expansionProgress > 0.82)
                    .accessibilityHidden(expansionProgress < 0.82)

                compactPresentationView
                    .frame(height: compactPresentationHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(compactOpacity)
                    .allowsHitTesting(expansionProgress < 0.58)
                    .accessibilityHidden(expansionProgress >= 0.58)

                if showsReaderBackToTop {
                    readerBackToTopButton
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(
                            .bottom,
                            readerBackToTopBottomPadding(
                                bottomSafeAreaInset: proxy.safeAreaInsets.bottom,
                                expansionProgress: expansionProgress
                            )
                        )
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .bottom)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.92)),
                                removal: .move(edge: .bottom)
                                    .combined(with: .opacity)
                            )
                        )
                        .zIndex(5)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
            .animation(.easeInOut(duration: 0.18), value: showsReaderBackToTop)
            .onChange(of: expansionProgress, initial: true) { _, newValue in
                guard abs(newValue - measuredPresentationExpansion) > 0.002 else { return }
                if measuredPresentationExpansion < 0.82 && newValue >= 0.82 {
                    synchronizeChromeWithCurrentScrollPosition(animated: false)
                }
                measuredPresentationExpansion = newValue
            }
        }
        .ignoresSafeArea(.container, edges: ignoredContainerEdges)
        .toolbar {
            if showsBottomToolbar {
                dynamicBottomToolbar
            }
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
        .toolbarVisibility(
            showsBottomToolbar ? .visible : .hidden,
            for: .bottomBar
        )
    }

    private func showsReaderBackToTopButton(for expansionProgress: CGFloat) -> Bool {
        !isCompactPresentation
            && expansionProgress >= 0.82
            && !isSummaryMode
            && scrollState.collapseProgress > 0.64
    }

    private func readerBackToTopBottomPadding(
        bottomSafeAreaInset: CGFloat,
        expansionProgress: CGFloat
    ) -> CGFloat {
        bottomSafeAreaInset + (expansionProgress >= 0.9 ? 68 : 18)
    }

    private var readerBackToTopButton: some View {
        Button {
            scrollReaderToTop()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(resolvedFeedColor)
                .frame(width: 32, height: 32)
                .glassEffect(readerBackToTopGlass, in: Circle())
                .background {
                    Circle()
                        .fill(Color(.systemBackground).opacity(0.42))
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                }
                .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .minimumHitTarget()
        .accessibilityLabel("Nach oben")
        .accessibilityHint("Scrollt zurück zum Artikelanfang")
    }

    private var readerBackToTopGlass: Glass {
        Glass.regular
            .interactive(true)
    }

    private func scrollReaderToTop() {
        AppHaptics.lightImpact()
        let scrollView = webView.scrollView
        let minimumOffsetY = -scrollView.adjustedContentInset.top
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: minimumOffsetY),
            animated: true
        )
        withAnimation(.smooth(duration: 0.18)) {
            scrollState.collapseProgress = 0
        }
    }

    private func toggleSummaryMode() {
        if isSummaryMode {
            guard !isSummaryDismissAnimating else { return }
            isSummaryDismissAnimating = true
            summaryDismissRequestID += 1
        } else {
            articleCollapseProgressBeforeSummary = scrollState.collapseProgress
            isSummaryGenerating = true
            summaryRainbowRevealProgress = 0
            summaryRainbowCompletionProgress = 0
            summaryContentVisibility = 0
            summaryDismissRequestID = 0
            isSummaryDismissAnimating = false
            withAnimation(.smooth(duration: 0.42)) {
                scrollState.collapseProgress = 0
                isSummaryMode = true
            }
            withAnimation(.easeOut(duration: 0.85).delay(0.08)) {
                summaryRainbowRevealProgress = 1
            }
        }
    }

    private func exitSummaryMode(animated: Bool) {
        let updates = {
            isSummaryMode = false
            isSummaryGenerating = false
            summaryRainbowRevealProgress = 0
            summaryRainbowCompletionProgress = 0
            summaryContentVisibility = 0
            summarySharePayload = nil
            showsAppleAILabel = false
            appleAILabelRequestID += 1
            scrollState.collapseProgress = articleCollapseProgressBeforeSummary
            isSummaryDismissAnimating = false
        }
        if animated {
            withAnimation(.smooth(duration: 0.3)) {
                updates()
            }
        } else {
            updates()
        }
    }

    private func revealAppleAILabel() {
        appleAILabelRequestID += 1
        let requestID = appleAILabelRequestID

        withAnimation(.easeInOut(duration: 0.22)) {
            showsAppleAILabel = true
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard requestID == appleAILabelRequestID else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                showsAppleAILabel = false
            }
        }
    }

    private func handleSummaryGenerationState(_ isGenerating: Bool) {
        if isGenerating {
            withAnimation(.easeInOut(duration: 0.28)) {
                isSummaryGenerating = true
            }
            withAnimation(.easeInOut(duration: 0.52)) {
                summaryRainbowCompletionProgress = 0
                summaryContentVisibility = 0
            }
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                isSummaryGenerating = false
            }
            withAnimation(.easeInOut(duration: 0.46)) {
                summaryRainbowCompletionProgress = 1
                summaryContentVisibility = 1
            }
        }
    }

    private func prepareSummaryForRegeneration() {
        withAnimation(.easeInOut(duration: 0.28)) {
            isSummaryGenerating = true
        }
        withAnimation(.easeInOut(duration: 0.52)) {
            summaryRainbowCompletionProgress = 0
            summaryContentVisibility = 0
        }
    }

    private func presentationExpansionProgress(
        height: CGFloat,
        bottomSafeAreaInset: CGFloat
    ) -> CGFloat {
        let compactHeight = compactPresentationHeight + bottomSafeAreaInset
        let linearProgress = (height - compactHeight) / FeedDetailLayout.presentationTransitionDistance
        return smoothstep(min(1, max(0, linearProgress)))
    }

    private func compactPresentationOpacity(for expansionProgress: CGFloat) -> Double {
        let fadeProgress = smoothstep(min(1, max(0, expansionProgress / 0.52)))
        return Double(1 - fadeProgress)
    }

    private func detailPresentationOpacity(for expansionProgress: CGFloat) -> Double {
        let linearProgress = (expansionProgress - 0.18) / 0.64
        return Double(smoothstep(min(1, max(0, linearProgress))))
    }

    private var compactPresentationView: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.sourceTitle ?? "Unbekannte Quelle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(resolvedFeedColor)
                    .lineLimit(1)

                Text(entry.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)

            }

            Button {
                AppHaptics.lightImpact()
                onClosePresentation()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .minimumHitTarget()
            .accessibilityLabel("Reader schließen")
        }
        .padding(.horizontal, FeedDetailLayout.compactHorizontalInset)
        .padding(.top, FeedDetailLayout.compactTopInset)
        .padding(.bottom, FeedDetailLayout.compactBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            AppHaptics.selection()
            onExpandPresentation()
        }
        .accessibilityHint("Doppeltippen, um den Artikel wieder zu öffnen")
    }

    private func observedDetailRoot(
        htmlDocument: String,
        htmlContentID: String
    ) -> AnyView {
        let root = detailRoot(
            htmlDocument: htmlDocument,
            htmlContentID: htmlContentID
        )
        let appeared = root.onAppear {
            handleAppear()
        }
        let entryObserved = appeared.onChange(of: entry.link) { _, _ in
            handleEntryLinkChange()
        }
        let headerObserved = entryObserved.onPreferenceChange(FeedDetailHeaderHeightKey.self) { newValue in
            handleHeaderHeightChange(newValue)
        }
        let fontScaleObserved = headerObserved.onChange(of: readerFontScale) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerFontScale)
        }
        let fontFamilyObserved = fontScaleObserved.onChange(of: readerFontFamily) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerFontFamily)
        }
        let lineSpacingObserved = fontFamilyObserved.onChange(of: readerLineSpacing) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerLineSpacing)
        }
        let textAlignmentObserved = lineSpacingObserved.onChange(of: readerTextAlignmentRaw) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerTextAlignment)
        }
        let paragraphSpacingObserved = textAlignmentObserved.onChange(of: readerParagraphSpacing) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerParagraphSpacing)
        }
        let contentWidthObserved = paragraphSpacingObserved.onChange(of: readerContentWidth) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerContentWidth)
        }
        return AnyView(contentWidthObserved)
    }

    private func detailRoot(
        htmlDocument: String,
        htmlContentID: String
    ) -> AnyView {
        let content = detailContent(
            htmlDocument: htmlDocument,
            htmlContentID: htmlContentID
        )
        let animatedContent = content
            .offset(x: contentOffset)

        return AnyView(
            ZStack(alignment: .top) {
                // Keep the cover opaque while article content fades or slides.
                // Otherwise the feed list underneath flashes through between entries.
                articleSurfaceBackground
                    .ignoresSafeArea()

                animatedContent

                collapsingNavigationBar
            }
            .opacity(contentOpacity)
        )
    }

    private func detailContent(
        htmlDocument: String,
        htmlContentID: String
    ) -> some View {
        ZStack(alignment: .top) {
            webLayer(
                htmlDocument: htmlDocument,
                htmlContentID: htmlContentID
            )
                .opacity(isSummaryMode ? 0 : 1)
                .allowsHitTesting(!isSummaryMode)
                .accessibilityHidden(isSummaryMode)

            if isSummaryMode {
                summaryRainbowSheetGlow
                    .zIndex(0.5)

                ArticleSummaryView(
                    title: entry.displayTitle,
                    sourceText: articleSummarySourceText,
                    link: entry.link,
                    feedColor: resolvedFeedColor,
                    topInset: effectiveHeaderHeight,
                    dismissRequestID: summaryDismissRequestID,
                    regenerationRequestID: summaryRegenerationRequestID,
                    onGenerationStateChange: handleSummaryGenerationState,
                    onSharePayloadChange: { summarySharePayload = $0 },
                    onDismissAnimationComplete: {
                        exitSummaryMode(animated: true)
                    }
                )
                .environmentObject(store)
                .mask(alignment: .top) {
                    Rectangle()
                        .scaleEffect(
                            y: max(0, CGFloat(summaryContentVisibility)),
                            anchor: .top
                        )
                        .blur(radius: 8)
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .trailing))
                    )
                )
                .zIndex(1)
            }

            headerLayer
            sheetPresenter
        }
    }

    private var collapsingNavigationBar: some View {
        FeedDetailCollapsingNavigationBar(
            title: entry.displayTitle,
            tint: navigationBarTint,
            isSummaryMode: isSummaryMode,
            scrollState: scrollState
        )
    }

    private func webLayer(
        htmlDocument: String,
        htmlContentID: String
    ) -> some View {
        WebView(webView: webView,
                articleLink: entry.link,
                articleURL: URL(string: entry.link),
                htmlContent: htmlDocument,
                htmlContentID: htmlContentID,
                topInset: effectiveHeaderHeight,
                scrollState: scrollState,
                initialHeaderCollapseProgress: pendingInitialHeaderCollapseProgress,
                onSwipeLeft: goToNext,
                onSwipeRight: goToPrevious)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            //.ignoresSafeArea(.container, edges: .bottom)
    }

    private var headerLayer: some View {
        FeedDetailCollapsingHeader(
            scrollState: scrollState,
            isSummaryMode: isSummaryMode,
            headerHeight: effectiveHeaderHeight
        ) {
            headerView
                .background(alignment: .top) {
                    ZStack {
                        headerOverlayGradient

                        if isSummaryMode {
                            activeSummaryRainbowGlow
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .opacity(
                                    0.82
                                        * Double(summaryRainbowRevealProgress)
                                        * Double(1 - summaryRainbowCompletionProgress)
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(
                        height: effectiveHeaderHeight + headerGradientBottomExtension,
                        alignment: .top
                    )
                }
        }
    }

    private var summaryRainbowSheetGlow: some View {
        GeometryReader { proxy in
            restingSummaryRainbowGlow
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(
                    0.264
                        * Double(summaryRainbowRevealProgress)
                        * Double(summaryRainbowCompletionProgress)
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var activeSummaryRainbowGlow: some View {
        staticSummaryRainbow
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .opacity(colorScheme == .dark ? 0.82 : 0.74)
            .blur(radius: 5)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.28), location: 0.42),
                        .init(color: .black.opacity(0.72), location: 0.78),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }

    private var restingSummaryRainbowGlow: some View {
        staticSummaryRainbow
            .frame(maxWidth: .infinity)
            .frame(height: 360)
            .opacity(colorScheme == .dark ? 0.638 : 0.55)
            .blur(radius: 8)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.04), location: 0.34),
                        .init(color: .black.opacity(0.18), location: 0.62),
                        .init(color: .black.opacity(0.55), location: 0.84),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }

    private var staticSummaryRainbow: some View {
        return LinearGradient(
            colors: [
                Color(red: 1.00, green: 0.25, blue: 0.37),
                Color(red: 1.00, green: 0.66, blue: 0.20),
                Color(red: 0.32, green: 0.84, blue: 0.48),
                Color(red: 0.20, green: 0.68, blue: 1.00),
                Color(red: 0.55, green: 0.38, blue: 1.00),
                Color(red: 1.00, green: 0.25, blue: 0.62)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .saturation(0.82)
        .brightness(colorScheme == .dark ? -0.12 : 0)
    }

    private var headerOverlayGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: headerTint, location: 0),
                .init(color: headerTint.opacity(headerOverlaySecondaryOpacity), location: 0.9),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var headerGradientBottomExtension: CGFloat {
        isHeaderTitleSingleLine ? headerTitleLineHeight : 0
    }

    private var articleSurfaceBackground: some View {
        ZStack {
            Color(.systemBackground)

            LinearGradient(
                stops: [
                    .init(color: headerTint.opacity(surfaceTopTintOpacity), location: 0),
                    .init(color: headerTint.opacity(surfaceHeaderTintOpacity), location: 0.18),
                    .init(color: headerTint.opacity(surfaceContentTintOpacity), location: 0.42),
                    .init(color: headerTint.opacity(surfaceTailTintOpacity), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0), location: 0),
                    .init(color: .clear, location: 0.38)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func handleAppear() {
        isReadLocal = store.isRead(articleID: entry.link)
        isBookmarked = isCurrentlyBookmarked()
        resetArticlePosition(animated: false)
        hasAppeared = true
    }

    private func handleEntryLinkChange() {
        guard hasAppeared else { return }
        exitSummaryMode(animated: false)
        isReadLocal = store.isRead(articleID: entry.link)
        isBookmarked = isCurrentlyBookmarked()
        resetArticlePosition(animated: true)
        animateEntryTransition()
    }

    private func resetArticlePosition(animated: Bool) {
        let initialCollapseProgress = pendingInitialHeaderCollapseProgress
        let updates = {
            scrollState.reset(collapseProgress: initialCollapseProgress)
        }
        pendingInitialHeaderCollapseProgress = 0

        if animated {
            withAnimation(.smooth(duration: 0.24)) {
                updates()
            }
        } else {
            updates()
        }

        let minimumOffsetY = -webView.scrollView.adjustedContentInset.top
        webView.scrollView.setContentOffset(
            CGPoint(x: webView.scrollView.contentOffset.x, y: minimumOffsetY),
            animated: animated
        )
    }

    private func synchronizeChromeWithCurrentScrollPosition(animated: Bool) {
        let scrollView = webView.scrollView
        let currentOffset = scrollView.contentOffset.y
        let topInset = scrollView.adjustedContentInset.top
        let bottomInset = scrollView.adjustedContentInset.bottom
        let minOffsetY = -topInset
        let maxOffsetY = max(
            minOffsetY,
            scrollView.contentSize.height - scrollView.bounds.height + bottomInset
        )
        let clampedOffsetY = min(max(currentOffset, minOffsetY), maxOffsetY)
        let scrollDistanceFromTop = max(0, clampedOffsetY - minOffsetY)
        let collapseProgress = FeedDetailLayout.clampedProgress(
            scrollDistanceFromTop / FeedDetailLayout.headerCollapseRange
        )

        let updates = {
            scrollState.collapseProgress = collapseProgress
        }

        if animated {
            withAnimation(.smooth(duration: 0.18)) {
                updates()
            }
        } else {
            updates()
        }
    }

    private func handleHeaderHeightChange(_ newValue: CGFloat) {
        let clampedValue = max(FeedDetailLayout.expandedHeaderHeight, newValue)
        guard abs(clampedValue - headerHeight) > 0.5 else { return }
        headerHeight = clampedValue
    }

    private var sheetPresenter: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: $activeSheet) { sheet in
                activeSheetView(sheet)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func activeSheetView(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .share(let payload, _):
            ShareSheet(items: [payload])
                .presentationDetents([UIStylePolicy.Sheet.mediumDetent])
        case .readerSettings:
            ReaderSettingsPanel(textAlignment: $readerTextAlignmentRaw,
                                fontScale: $readerFontScale,
                                fontFamily: $readerFontFamily,
                                lineSpacing: $readerLineSpacing,
                                paragraphSpacing: $readerParagraphSpacing,
                                contentWidth: $readerContentWidth,
                                feedColor: .constant(resolvedFeedColor))
                .presentationDetents([UIStylePolicy.Sheet.mediumDetent, .large])
        }
    }

    private func fixYouTubeIframes(in html: String) -> String {
        let pattern = "<iframe\\b([^>]*?)\\bsrc\\s*=\\s*([\"'])([^\"']+)\\2([^>]*)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: fullRange)
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            guard
                match.numberOfRanges >= 5,
                let openTagRange = Range(match.range(at: 0), in: result),
                let leadingAttributesRange = Range(match.range(at: 1), in: result),
                let srcRange = Range(match.range(at: 3), in: result),
                let trailingAttributesRange = Range(match.range(at: 4), in: result)
            else {
                continue
            }

            let source = String(result[srcRange])
            guard let normalizedSource = normalizedYouTubeEmbedURL(from: source) else {
                continue
            }

            let rawAttributes = String(result[leadingAttributesRange]) + String(result[trailingAttributesRange])
            let cleanedAttributes = cleanYouTubeIframeAttributes(rawAttributes)
            let replacement = """
            <iframe\(cleanedAttributes) src="\(normalizedSource)" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen playsinline loading="eager" referrerpolicy="strict-origin-when-cross-origin">
            """
            result.replaceSubrange(openTagRange, with: replacement)
        }

        return result
    }

    private func fixHTML5VideoTags(in html: String) -> String {
        let pattern = "<video\\b([^>]*)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: fullRange)
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            guard
                match.numberOfRanges >= 2,
                let openTagRange = Range(match.range(at: 0), in: result),
                let attributesRange = Range(match.range(at: 1), in: result)
            else {
                continue
            }

            let rawAttributes = String(result[attributesRange])
            let cleanedAttributes = cleanHTML5VideoAttributes(rawAttributes)
            let replacement = """
            <video\(cleanedAttributes) playsinline webkit-playsinline preload="metadata">
            """
            result.replaceSubrange(openTagRange, with: replacement)
        }

        return result
    }

    private func cleanHTML5VideoAttributes(_ rawAttributes: String) -> String {
        var cleaned = rawAttributes
            .replacingOccurrences(of: "\\s*\\/", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let removablePatterns = [
            "\\sautoplay\\b",
            "\\splaysinline\\b",
            "\\swebkit-playsinline\\b",
            "\\salign\\s*=\\s*\"[^\"]*\"",
            "\\salign\\s*=\\s*'[^']*'",
            "\\sstyle\\s*=\\s*\"[^\"]*\"",
            "\\sstyle\\s*=\\s*'[^']*'",
            "\\swidth\\s*=\\s*\"[^\"]*\"",
            "\\swidth\\s*=\\s*'[^']*'",
            "\\sheight\\s*=\\s*\"[^\"]*\"",
            "\\sheight\\s*=\\s*'[^']*'",
            "\\spreload\\s*=\\s*\"[^\"]*\"",
            "\\spreload\\s*=\\s*'[^']*'"
        ]

        for pattern in removablePatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        cleaned = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "" : " \(cleaned)"
    }

    private func cleanYouTubeIframeAttributes(_ rawAttributes: String) -> String {
        var cleaned = rawAttributes
            .replacingOccurrences(of: "\\s*\\/", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let removablePatterns = [
            "\\sallow\\s*=\\s*\"[^\"]*\"",
            "\\sallow\\s*=\\s*'[^']*'",
            "\\sallowfullscreen\\b",
            "\\splaysinline\\b",
            "\\swidth\\s*=\\s*\"[^\"]*\"",
            "\\swidth\\s*=\\s*'[^']*'",
            "\\sheight\\s*=\\s*\"[^\"]*\"",
            "\\sheight\\s*=\\s*'[^']*'",
            "\\sloading\\s*=\\s*\"[^\"]*\"",
            "\\sloading\\s*=\\s*'[^']*'",
            "\\sreferrerpolicy\\s*=\\s*\"[^\"]*\"",
            "\\sreferrerpolicy\\s*=\\s*'[^']*'"
        ]

        for pattern in removablePatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        cleaned = cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "" : " \(cleaned)"
    }

    private func normalizedYouTubeEmbedURL(from source: String) -> String? {
        guard let components = URLComponents(string: source), let host = components.host?.lowercased() else {
            return nil
        }

        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard normalizedHost == "youtube.com"
                || normalizedHost == "m.youtube.com"
                || normalizedHost == "youtube-nocookie.com"
                || normalizedHost == "youtu.be" else {
            return nil
        }

        let pathParts = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        let videoID: String?
        if normalizedHost == "youtu.be" {
            videoID = pathParts.first
        } else if pathParts.first == "embed", pathParts.count > 1 {
            videoID = pathParts[1]
        } else if pathParts.first == "watch" {
            videoID = components.queryItems?.first(where: { $0.name.lowercased() == "v" })?.value
        } else if (pathParts.first == "shorts" || pathParts.first == "live"), pathParts.count > 1 {
            videoID = pathParts[1]
        } else {
            videoID = components.queryItems?.first(where: { $0.name.lowercased() == "v" })?.value
        }

        guard let rawID = videoID, !rawID.isEmpty else {
            return nil
        }

        let sanitizedID = rawID.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "", options: .regularExpression)
        guard !sanitizedID.isEmpty else { return nil }

        var embedComponents = URLComponents()
        embedComponents.scheme = "https"
        embedComponents.host = "www.youtube.com"
        embedComponents.path = "/embed/\(sanitizedID)"

        let startSeconds = extractStartSeconds(from: components.queryItems)
        let supportedQueryItems = components.queryItems?.filter {
            let name = $0.name.lowercased()
            return name == "list" || name == "si" || name == "end"
        } ?? []

        var outputQueryItems = supportedQueryItems
        if let startSeconds {
            outputQueryItems.append(URLQueryItem(name: "start", value: String(startSeconds)))
        }
        embedComponents.queryItems = outputQueryItems.isEmpty ? nil : outputQueryItems

        return embedComponents.string
    }

    private func extractStartSeconds(from queryItems: [URLQueryItem]?) -> Int? {
        guard let queryItems else { return nil }
        let directStart = queryItems.first { item in
            let key = item.name.lowercased()
            return key == "start" || key == "time_continue"
        }?.value
        if let directStart, let seconds = Int(directStart), seconds > 0 {
            return seconds
        }

        if let tValue = queryItems.first(where: { $0.name.lowercased() == "t" })?.value {
            return parseYouTubeTime(tValue)
        }

        return nil
    }

    private func parseYouTubeTime(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if let seconds = Int(trimmed), seconds > 0 {
            return seconds
        }

        guard let regex = try? NSRegularExpression(pattern: "(\\d+)([hms])", options: []) else {
            return nil
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = regex.matches(in: trimmed, options: [], range: range)
        guard !matches.isEmpty else { return nil }

        var total = 0
        for match in matches {
            guard
                match.numberOfRanges == 3,
                let amountRange = Range(match.range(at: 1), in: trimmed),
                let unitRange = Range(match.range(at: 2), in: trimmed),
                let amount = Int(trimmed[amountRange])
            else {
                continue
            }

            switch trimmed[unitRange].first {
            case "h": total += amount * 3600
            case "m": total += amount * 60
            case "s": total += amount
            default: break
            }
        }

        return total > 0 ? total : nil
    }

    private func sanitizedReaderBody(from html: String) -> String {
        var sanitized = removeReaderBlockedElements(in: html)
        sanitized = removeTrackingImages(in: sanitized)
        sanitized = removeUnsupportedIframes(in: sanitized)
        sanitized = removeEmptyVideos(in: sanitized)
        sanitized = fixHTML5VideoTags(in: fixYouTubeIframes(in: sanitized))
        return sanitized
    }

    private func removeReaderBlockedElements(in html: String) -> String {
        let blockedPatterns = [
            #"<script\b[\s\S]*?</script\s*>"#,
            #"<style\b[\s\S]*?</style\s*>"#,
            #"<noscript\b[\s\S]*?</noscript\s*>"#,
            #"<amp-iframe\b[\s\S]*?</amp-iframe\s*>"#
        ]

        var result = html
        for pattern in blockedPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    private func removeTrackingImages(in html: String) -> String {
        replaceMatches(in: html, regex: Self.readerImageTagRegex) { tag in
            shouldRemoveImageTag(tag) ? "" : tag
        }
    }

    private func removeUnsupportedIframes(in html: String) -> String {
        replaceMatches(in: html, regex: Self.readerIframeTagRegex) { tag in
            guard let source = htmlAttribute("src", in: tag), !source.isEmpty else {
                return ""
            }
            if isTrackingOrAdURL(source) {
                return ""
            }
            return isSupportedReaderEmbedSource(source) ? tag : ""
        }
    }

    private func removeEmptyVideos(in html: String) -> String {
        replaceMatches(in: html, regex: Self.readerVideoTagRegex) { tag in
            if let source = htmlAttribute("src", in: tag), isTrackingOrAdURL(source) {
                return ""
            }
            let hasDirectSource = htmlAttribute("src", in: tag)?.isEmpty == false
            let hasNestedSource = tag.range(of: #"<source\b[^>]+\bsrc\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
            return (hasDirectSource || hasNestedSource) ? tag : ""
        }
    }

    private func replaceMatches(in html: String,
                                regex: NSRegularExpression?,
                                transform: (String) -> String) -> String {
        guard let regex else { return html }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            guard let matchRange = Range(match.range(at: 0), in: result) else {
                continue
            }

            let original = String(result[matchRange])
            result.replaceSubrange(matchRange, with: transform(original))
        }

        return result
    }

    private func shouldRemoveImageTag(_ tag: String) -> Bool {
        guard let source = readerImageSource(in: tag), !source.isEmpty else {
            return true
        }
        if source.lowercased().hasPrefix("data:image/svg+xml") {
            return true
        }
        if isTrackingOrAdURL(source) {
            return true
        }

        let style = htmlAttribute("style", in: tag)?.lowercased() ?? ""
        if style.contains("display:none")
            || style.contains("display: none")
            || style.contains("visibility:hidden")
            || style.contains("visibility: hidden")
            || style.contains("opacity:0")
            || style.contains("opacity: 0") {
            return true
        }

        let width = htmlNumericAttribute("width", in: tag)
        let height = htmlNumericAttribute("height", in: tag)
        if let width, let height, width <= 2, height <= 2 {
            return true
        }

        if (style.contains("width:1px") || style.contains("width: 1px"))
            && (style.contains("height:1px") || style.contains("height: 1px")) {
            return true
        }

        return false
    }

    private func readerImageSource(in tag: String) -> String? {
        let attributeNames = [
            "src",
            "data-src",
            "data-original",
            "data-lazy-src",
            "data-orig-file"
        ]

        for name in attributeNames {
            if let value = htmlAttribute(name, in: tag), !value.isEmpty {
                return value
            }
        }

        if let srcset = htmlAttribute("srcset", in: tag) ?? htmlAttribute("data-srcset", in: tag) {
            return firstImageURL(inSrcset: srcset)
        }

        return nil
    }

    private func firstImageURL(inSrcset srcset: String) -> String? {
        srcset
            .split(separator: ",")
            .compactMap { candidate -> String? in
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init)
            }
            .first
    }

    private func htmlAttribute(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?i)\b\#(escapedName)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range) else {
            return nil
        }

        for index in 1..<match.numberOfRanges {
            let valueRange = match.range(at: index)
            guard valueRange.location != NSNotFound,
                  let range = Range(valueRange, in: tag) else {
                continue
            }
            return String(tag[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private func htmlNumericAttribute(_ name: String, in tag: String) -> Double? {
        guard let rawValue = htmlAttribute(name, in: tag) else { return nil }
        let normalized = rawValue
            .replacingOccurrences(of: "px", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }

    private func isSupportedReaderEmbedSource(_ rawSource: String) -> Bool {
        guard let host = hostName(from: rawSource) else {
            return false
        }

        return host == "youtu.be"
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com")
            || host == "vimeo.com"
            || host.hasSuffix(".vimeo.com")
            || host == "open.spotify.com"
            || host == "spotify.com"
            || host.hasSuffix(".spotify.com")
            || host == "w.soundcloud.com"
            || host == "soundcloud.com"
            || host.hasSuffix(".soundcloud.com")
            || host == "music.apple.com"
            || host == "podcasts.apple.com"
            || host.hasSuffix(".music.apple.com")
            || host.hasSuffix(".podcasts.apple.com")
            || host == "bandcamp.com"
            || host.hasSuffix(".bandcamp.com")
            || host == "archive.org"
            || host.hasSuffix(".archive.org")
    }

    private func isTrackingOrAdURL(_ rawSource: String) -> Bool {
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !source.isEmpty else { return true }
        guard !source.hasPrefix("about:")
                && !source.hasPrefix("javascript:")
                && !source.hasPrefix("blob:") else {
            return true
        }

        let blockedTokens = [
            "doubleclick",
            "googlesyndication",
            "googleadservices",
            "google-analytics",
            "googletagmanager",
            "adservice",
            "adnxs",
            "outbrain",
            "taboola",
            "scorecardresearch",
            "quantserve",
            "chartbeat",
            "analytics",
            "tracking",
            "tracker",
            "pixel",
            "1x1"
        ]

        return blockedTokens.contains { source.contains($0) }
    }

    private func hostName(from rawSource: String) -> String? {
        let trimmed = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized: String
        if trimmed.hasPrefix("//") {
            normalized = "https:\(trimmed)"
        } else if trimmed.range(of: #"^[a-z][a-z0-9+\-.]*://"#, options: [.regularExpression, .caseInsensitive]) == nil {
            normalized = "https://\(trimmed)"
        } else {
            normalized = trimmed
        }

        guard let host = URLComponents(string: normalized)?.host?.lowercased() else {
            return nil
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func mixedRGBColor(base: (Int, Int, Int),
                               overlay: (red: Int, green: Int, blue: Int),
                               overlayOpacity: Double) -> String {
        let clampedOpacity = max(0, min(1, overlayOpacity))
        let red = Int((Double(base.0) * (1 - clampedOpacity)) + (Double(overlay.red) * clampedOpacity))
        let green = Int((Double(base.1) * (1 - clampedOpacity)) + (Double(overlay.green) * clampedOpacity))
        let blue = Int((Double(base.2) * (1 - clampedOpacity)) + (Double(overlay.blue) * clampedOpacity))
        return "rgb(\(red),\(green),\(blue))"
    }
    
    private func formattedHTMLContentID(accentHex: String) -> String {
        let rawBodySource = (entry.contentRaw?.isEmpty == false) ? entry.contentRaw! : entry.content
        return [
            Self.readerHTMLRenderVersion,
            entry.link,
            String(rawBodySource.utf8.count),
            String(readerFontScale),
            readerFontFamily,
            String(readerLineSpacing),
            readerTextAlignmentRaw,
            String(readerParagraphSpacing),
            String(readerContentWidth),
            accentHex
        ].joined(separator: "|")
    }

    private func formattedHTML(accentHex: String, contentID: String) -> String {
        let rawBodySource = (entry.contentRaw?.isEmpty == false) ? entry.contentRaw! : entry.content
        let cacheKey = contentID as NSString

        if let cachedDocument = Self.formattedHTMLCache.object(forKey: cacheKey) {
            return cachedDocument as String
        }

        let fontSize = 18 * readerFontScale
        let lineHeight = readerLineSpacing
        let fontFamilyCSS = (ReaderFontFamily(rawValue: readerFontFamily) ?? .rounded).cssValue
        let textAlignCSS = readerTextAlignmentRaw == "justified" ? "justify" : readerTextAlignmentRaw
        let rgb = resolvedFeedColor.rgbComponents ?? (0,0,0)
        let mediaShadow: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.14)"
        let codeBackground: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.16)"
        let inlineCodeBackground: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.22)"
        let rawBody = HTMLText.normalizeHTMLContent(rawBodySource)
        let bodyHTML = sanitizedReaderBody(from: rawBody)

        let document = """
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
              html { overflow-x: hidden; min-height: 100%; background: transparent !important; }
              :root {
                color-scheme: light dark;
                --reader-line-height: \(lineHeight);
                --reader-paragraph-spacing: \(readerParagraphSpacing)em;
                --reader-content-width: \(readerContentWidth)px;
                --reader-rollout-duration: 380ms;
              }
              * { box-sizing: border-box; }
              body { font-family: \(fontFamilyCSS); font-size: \(fontSize)px; min-height: 100%; max-width: var(--reader-content-width); padding: 16px; line-height: 1.35; margin: 0 auto; text-align: \(textAlignCSS); background: transparent !important; overflow-wrap: break-word; word-break: normal; }
              body.reader-rollout {
                opacity: 0;
              }
              body.reader-rollout-ready {
                opacity: 1;
                transition: opacity 120ms ease-out;
              }
              body.reader-rollout-ready .reader-rollout-item {
                opacity: 0;
                transform: translateY(-5px);
                -webkit-clip-path: inset(0 0 100% 0);
                clip-path: inset(0 0 100% 0);
                transition:
                  opacity var(--reader-rollout-duration) ease-out var(--reader-rollout-delay, 0ms),
                  transform var(--reader-rollout-duration) cubic-bezier(0.16, 1, 0.3, 1) var(--reader-rollout-delay, 0ms),
                  -webkit-clip-path var(--reader-rollout-duration) cubic-bezier(0.16, 1, 0.3, 1) var(--reader-rollout-delay, 0ms),
                  clip-path var(--reader-rollout-duration) cubic-bezier(0.16, 1, 0.3, 1) var(--reader-rollout-delay, 0ms);
                will-change: opacity, transform, clip-path;
              }
              body.reader-rollout-ready .reader-rollout-item.reader-rollout-media {
                transition-duration: 480ms, 480ms, 520ms, 520ms;
              }
              body.reader-rollout-ready .reader-rollout-item.reader-rollout-visible {
                opacity: 1;
                transform: translateY(0);
                -webkit-clip-path: inset(0 0 0 0);
                clip-path: inset(0 0 0 0);
              }
              body.reader-rollout img.reader-media-failed,
              body.reader-rollout picture.reader-media-failed,
              body.reader-rollout figure.reader-media-failed {
                opacity: 1;
                animation: none;
              }
              p, li, blockquote, h1, h2, h3, h4, h5, h6 { overflow-wrap: anywhere; }
              p { margin: 0 0 calc(var(--reader-paragraph-spacing) * 0.72); line-height: var(--reader-line-height); }
              p:last-child { margin-bottom: 0; }
              h1, h2, h3, h4, h5, h6 {
                line-height: 1.2;
                margin: 0.82em 0 0.26em;
                text-align: left;
              }
              p + h1, p + h2, p + h3, p + h4, p + h5, p + h6,
              ul + h1, ul + h2, ul + h3, ul + h4, ul + h5, ul + h6,
              ol + h1, ol + h2, ol + h3, ol + h4, ol + h5, ol + h6,
              blockquote + h1, blockquote + h2, blockquote + h3,
              blockquote + h4, blockquote + h5, blockquote + h6 {
                margin-top: 0.96em;
              }
              h1 + p, h2 + p, h3 + p, h4 + p, h5 + p, h6 + p,
              h1 + ul, h2 + ul, h3 + ul, h4 + ul, h5 + ul, h6 + ul,
              h1 + ol, h2 + ol, h3 + ol, h4 + ol, h5 + ol, h6 + ol,
              h1 + blockquote, h2 + blockquote, h3 + blockquote,
              h4 + blockquote, h5 + blockquote, h6 + blockquote {
                margin-top: 0.18em;
              }
              h1:first-child, h2:first-child, h3:first-child,
              h4:first-child, h5:first-child, h6:first-child { margin-top: 0; }
              h1 { font-size: 1.55em; }
              h2 { font-size: 1.35em; }
              h3 { font-size: 1.18em; }
              h4, h5, h6 { font-size: 1em; }
              blockquote {
                margin: 0.42em 0 0.68em;
                padding: 0.04em 0 0.04em 0.75em;
                border-left: 3px solid \(accentHex);
              }
              blockquote p { margin-bottom: 0.44em; }
              blockquote p:last-child { margin-bottom: 0; }
              figure {
                margin: 0.8em 0;
              }
              figcaption {
                margin-top: -0.35em;
                font-size: 0.82em;
                line-height: 1.35;
                opacity: 0.72;
                text-align: center;
              }
              ul, ol {
                margin: 0.18em 0 0.52em;
                padding-inline-start: 1.18em;
              }
              li {
                margin: 0.08em 0;
                padding-inline-start: 0.08em;
                line-height: var(--reader-line-height);
              }
              li > p {
                margin: 0.04em 0;
                line-height: var(--reader-line-height);
              }
              li > p:first-child { margin-top: 0; }
              li > p:last-child { margin-bottom: 0; }
              li + li { margin-top: 0.34em; }
              li > ul, li > ol { margin: 0.2em 0 0.34em; }
              table {
                display: table !important;
                width: 100% !important;
                max-width: 100% !important;
                border-collapse: collapse;
                border-spacing: 0;
                margin: 0.46em 0 0.72em !important;
                clear: both;
              }
              p + table, div + table, section + table, figure + table,
              table:first-child {
                margin-top: 0.18em !important;
              }
              table + p, table + div, table + section {
                margin-top: 0.28em !important;
              }
              th, td {
                padding: 0.42em 0.5em;
                line-height: 1.32;
                vertical-align: top;
                border-bottom: 1px solid rgba(127,127,127,0.24);
              }
              th {
                font-weight: 700;
                text-align: left;
              }
              @media (prefers-color-scheme: dark) { body { color: #EAEAEA; } a { color: \(accentHex); } }
              @media (prefers-color-scheme: light) { body { color: #111111; } a { color: \(accentHex); } }
              img, video, iframe { display: block !important; max-width: 100% !important; border-radius: 10px; margin: 0.9em auto !important; float: none !important; clear: both; background: transparent !important; box-shadow: 0 8px 18px \(mediaShadow); }
              figure > img, figure > video, figure > iframe { margin-top: 0 !important; }
              img, video { width: auto !important; height: auto !important; }
              iframe { width: 100% !important; height: auto !important; aspect-ratio: 16/9; }
              iframe[src*="open.spotify.com"], iframe[src*="spotify.com/embed"] {
                height: 352px !important;
                max-height: min(352px, 70vh) !important;
                aspect-ratio: auto !important;
              }
              iframe[src*="open.spotify.com/embed/track"], iframe[src*="spotify.com/embed/track"],
              iframe[src*="open.spotify.com/embed/episode"], iframe[src*="spotify.com/embed/episode"] {
                height: 152px !important;
                max-height: min(152px, 42vh) !important;
              }
              img.reader-media-failed, picture.reader-media-failed, figure.reader-media-failed { display: none !important; }
              iframe:not([src]), iframe[src=""], img:not([src]), img[src=""] { display: none !important; }
              pre, code, kbd, samp { font-family: 'SFMono-Regular', Menlo, Consolas, monospace; text-align: left; }
              code, kbd, samp {
                background: \(inlineCodeBackground);
                border-radius: 8px;
                padding: 0.16em 0.38em;
                font-size: 0.88em;
              }
              pre {
                max-width: 100%;
                overflow-x: auto;
                -webkit-overflow-scrolling: touch;
                white-space: pre;
                word-break: normal;
                overflow-wrap: normal;
                background: \(codeBackground);
                border-radius: 14px;
                padding: 14px 16px;
                margin: 18px 0;
                font-size: 0.82em;
                line-height: 1.55;
              }
              pre code {
                display: block;
                background: transparent;
                padding: 0;
                border-radius: 0;
                font-size: inherit;
                line-height: inherit;
              }
              @media (prefers-reduced-motion: reduce) {
                body.reader-rollout,
                body.reader-rollout-ready,
                body.reader-rollout-ready .reader-rollout-item {
                  opacity: 1;
                  transform: none;
                  -webkit-clip-path: inset(0 0 0 0);
                  clip-path: inset(0 0 0 0);
                  animation: none;
                  transition: none;
                }
              }
            </style>
            <script>
              document.addEventListener('DOMContentLoaded', function () {
                document.querySelectorAll('video').forEach(function (video) {
                  try {
                    video.autoplay = false;
                    video.removeAttribute('autoplay');
                    video.setAttribute('playsinline', '');
                    video.setAttribute('webkit-playsinline', '');
                    video.pause();
                  } catch (_) {}
                });

                function isNoisyURL(raw) {
                  var src = (raw || '').toLowerCase();
                  return !src
                    || src.indexOf('about:') === 0
                    || src.indexOf('javascript:') === 0
                    || src.indexOf('doubleclick') !== -1
                    || src.indexOf('googlesyndication') !== -1
                    || src.indexOf('googleadservices') !== -1
                    || src.indexOf('googletagmanager') !== -1
                    || src.indexOf('outbrain') !== -1
                    || src.indexOf('taboola') !== -1
                    || src.indexOf('scorecardresearch') !== -1
                    || src.indexOf('quantserve') !== -1
                    || src.indexOf('tracking') !== -1
                    || src.indexOf('tracker') !== -1
                    || src.indexOf('pixel') !== -1
                    || src.indexOf('1x1') !== -1;
                }

                function removeEmptyBlocks() {
                  document.querySelectorAll('p, div, section, aside, figure').forEach(function (element) {
                    var text = (element.textContent || '').replace(/\\s+/g, '');
                    if (text.length > 0) { return; }
                    if (element.querySelector('img, video, iframe, audio, source, picture, canvas, svg, table')) { return; }
                    element.remove();
                  });
                }

                function normalizeTableSpacing() {
                  document.querySelectorAll('table').forEach(function (table) {
                    table.removeAttribute('height');
                    table.style.marginTop = '';
                    table.style.paddingTop = '';

                    var parent = table.parentElement;
                    if (parent && parent.children.length === 1) {
                      parent.style.marginTop = '';
                      parent.style.paddingTop = '';
                    }

                    var previous = table.previousElementSibling;
                    while (previous) {
                      var text = (previous.textContent || '').replace(/\\s+/g, '');
                      var hasContent = text.length > 0 || previous.querySelector('img, video, iframe, audio, picture, canvas, svg, table');
                      if (hasContent) { break; }
                      var removable = previous;
                      previous = previous.previousElementSibling;
                      removable.remove();
                    }
                  });
                }

                function firstSrcsetURL(srcset) {
                  return (srcset || '').split(',').map(function (candidate) {
                    return candidate.trim().split(/\\s+/)[0];
                  }).filter(Boolean)[0] || '';
                }

                function bestLazyImageSource(image) {
                  return image.getAttribute('src')
                    || image.getAttribute('data-src')
                    || image.getAttribute('data-original')
                    || image.getAttribute('data-lazy-src')
                    || image.getAttribute('data-orig-file')
                    || firstSrcsetURL(image.getAttribute('srcset'))
                    || firstSrcsetURL(image.getAttribute('data-srcset'));
                }

                function hideFailedMedia(image) {
                  image.classList.add('reader-media-failed');
                  var picture = image.closest('picture');
                  if (picture) { picture.classList.add('reader-media-failed'); }
                  var figure = image.closest('figure');
                  if (figure && !(figure.textContent || '').trim()) {
                    figure.classList.add('reader-media-failed');
                  }
                }

                function isMediaElement(element) {
                  return element.matches('img, video, iframe');
                }

                function mediaContainerFor(element) {
                  if (!isMediaElement(element)) { return null; }
                  var container = element.closest('figure, picture');
                  return container && container.querySelector('img, video, iframe') ? container : null;
                }

                function isMediaBlock(element) {
                  return isMediaElement(element)
                    || (element.matches('figure, picture') && !!element.querySelector('img, video, iframe'));
                }

                function shouldRevealElement(element) {
                  if (!element || element.classList.contains('reader-media-failed')) { return false; }
                  if (element.matches('script, style, noscript, source')) { return false; }
                  if (isMediaElement(element) && mediaContainerFor(element)) { return false; }
                  if (isMediaElement(element)) {
                    return !!(element.getAttribute('src') || element.getAttribute('srcset'));
                  }
                  if ((element.textContent || '').trim().length > 0) { return true; }
                  return !!element.querySelector('img, video, iframe, pre, table, blockquote');
                }

                function revealElement(element, delay) {
                  element.style.setProperty('--reader-rollout-delay', Math.max(0, delay) + 'ms');
                  element.classList.add('reader-rollout-visible');
                }

                function setupReaderRollout() {
                  var body = document.body;
                  if (!body) { return; }

                  var selector = [
                    'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
                    'p', 'blockquote', 'li', 'pre', 'table',
                    'figure', 'picture', 'img', 'video', 'iframe'
                  ].join(',');

                  var elements = Array.prototype.slice.call(document.querySelectorAll(selector))
                    .filter(shouldRevealElement);

                  elements.forEach(function (element) {
                    element.classList.add('reader-rollout-item');
                    if (isMediaBlock(element)) {
                      element.classList.add('reader-rollout-media');
                    }
                  });

                  requestAnimationFrame(function () {
                    var delay = 0;
                    body.classList.add('reader-rollout-ready');
                    elements.forEach(function (element) {
                      var media = isMediaBlock(element);
                      revealElement(element, delay);
                      delay += media ? 540 : 74;
                    });
                  });
                }

                document.querySelectorAll('img').forEach(function (image) {
                  var width = parseFloat(image.getAttribute('width') || '0');
                  var height = parseFloat(image.getAttribute('height') || '0');
                  var source = bestLazyImageSource(image);
                  if (source && !image.getAttribute('src')) {
                    image.setAttribute('src', source);
                  }
                  if (image.getAttribute('data-srcset') && !image.getAttribute('srcset')) {
                    image.setAttribute('srcset', image.getAttribute('data-srcset'));
                  }
                  image.setAttribute('loading', 'eager');
                  image.setAttribute('fetchpriority', 'high');
                  image.setAttribute('decoding', 'async');
                  image.addEventListener('error', function () { hideFailedMedia(image); });
                  image.addEventListener('load', function () {
                    if (image.naturalWidth > 0 && image.naturalWidth <= 2 && image.naturalHeight > 0 && image.naturalHeight <= 2) {
                      hideFailedMedia(image);
                    }
                  });
                  if (isNoisyURL(source) || (width > 0 && width <= 2 && height > 0 && height <= 2)) {
                    image.remove();
                  } else if (image.complete && image.naturalWidth === 0) {
                    hideFailedMedia(image);
                  }
                });

                document.querySelectorAll('iframe').forEach(function (frame) {
                  if (isNoisyURL(frame.getAttribute('src'))) {
                    frame.remove();
                  } else {
                    frame.setAttribute('loading', 'eager');
                  }
                });

                removeEmptyBlocks();
                normalizeTableSpacing();

                document.querySelectorAll('iframe[src]').forEach(function (frame) {
                  try {
                    var rawSrc = frame.getAttribute('src');
                    if (!rawSrc) { return; }
                    var parsed = new URL(rawSrc, window.location.href);
                    if (parsed.searchParams.get('autoplay') === '1') {
                      parsed.searchParams.set('autoplay', '0');
                      frame.setAttribute('src', parsed.toString());
                    }
                  } catch (_) {}
                });

                setupReaderRollout();
              });
            </script>
          </head>
          <body class="reader-rollout">\(bodyHTML)</body>
        </html>
        """
        Self.formattedHTMLCache.setObject(
            document as NSString,
            forKey: cacheKey,
            cost: document.utf8.count
        )
        return document
    }

    private var resolvedFeedColor: Color {
        feedColor ?? theme.uiAccentColor
    }

    private var headerTint: Color {
        guard let components = resolvedFeedColor.rgbComponents else {
            return resolvedFeedColor
        }
        let darkeningFactor = colorScheme == .dark ? 0.78 : 0.86

        return Color(
            .sRGB,
            red: max(0, min(1, Double(components.red) / 255.0 * darkeningFactor)),
            green: max(0, min(1, Double(components.green) / 255.0 * darkeningFactor)),
            blue: max(0, min(1, Double(components.blue) / 255.0 * darkeningFactor)),
            opacity: 1
        )
    }

    private var headerOverlayPrimaryOpacity: Double {
        colorScheme == .dark ? 0.30 : 0.42
    }

    private var headerOverlaySecondaryOpacity: Double {
        colorScheme == .dark ? UIStylePolicy.glassAccentOpacity : 0.16
    }

    private var navigationBarTint: Color {
        headerTint
    }

    private var surfaceTopTintOpacity: Double {
        colorScheme == .dark ? 0.34 : 0.34
    }

    private var surfaceHeaderTintOpacity: Double {
        colorScheme == .dark ? 0.18 : 0.18
    }

    private var surfaceContentTintOpacity: Double {
        colorScheme == .dark ? 0.08 : 0.07
    }

    private var surfaceTailTintOpacity: Double {
        colorScheme == .dark ? 0.03 : 0.025
    }

    private var headerBackgroundGradient: LinearGradient { //ganz oben dad ding
        LinearGradient(
            colors: [
                headerTint.opacity(colorScheme == .dark ? 0.5 : 0.62),
                headerTint.opacity(colorScheme == .dark ? 0.25 : 0.34)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func gatherShareContent() {
        webView.evaluateJavaScript("window.getSelection().toString();") { result, _ in
            let snippet = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let composed = [entry.title, snippet, entry.link].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            activeSheet = .share(payload: composed)
        }
    }

    private func shareCurrentContent() {
        if isSummaryMode {
            guard let summarySharePayload else { return }
            activeSheet = .share(payload: summarySharePayload)
        } else {
            gatherShareContent()
        }
    }
    
    private func isCurrentlyBookmarked() -> Bool {
        BookmarkService.isBookmarked(link: entry.link, context: modelContext)
    }
    
    private func toggleBookmark() {
        BookmarkService.toggleBookmark(for: entry, context: modelContext)
        isBookmarked = BookmarkService.isBookmarked(link: entry.link, context: modelContext)
        AppHaptics.selection()
        onToggleBookmark?(isBookmarked)
    }

    // MARK: - Helper Functions

    private func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}

private struct WebView: UIViewRepresentable {
    let webView: WKWebView
    let articleLink: String
    let articleURL: URL?
    let htmlContent: String
    let htmlContentID: String
    let topInset: CGFloat
    let scrollState: FeedDetailScrollState
    let initialHeaderCollapseProgress: CGFloat
    var onSwipeLeft: () -> Void = {}
    var onSwipeRight: () -> Void = {}
    private var youtubeEmbedBaseURL: URL? {
        let appIdentifier = Bundle.main.bundleIdentifier?.lowercased() ?? "notifeeder.app"
        return URL(string: "https://\(appIdentifier)")
    }

    func makeUIView(context: Context) -> WKWebView {
        configureWebViewSurface(webView)
        webView.scrollView.delegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        context.coordinator.configureGestureRecognizers(for: webView)
        loadContent(into: webView, coordinator: context.coordinator, forcePinToTop: true)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        configureWebViewSurface(uiView)
        context.coordinator.onSwipeLeft = onSwipeLeft
        context.coordinator.onSwipeRight = onSwipeRight

        if context.coordinator.lastLoadedContentID != htmlContentID {
            context.coordinator.resetScrollState(collapseProgress: initialHeaderCollapseProgress)
            loadContent(into: uiView, coordinator: context.coordinator, forcePinToTop: true)
            return
        }

        applyTopInset(topInset, to: uiView.scrollView, forcePinToTop: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            scrollState: scrollState,
            onSwipeLeft: onSwipeLeft,
            onSwipeRight: onSwipeRight
        )
    }

    private func configureWebViewSurface(_ webView: WKWebView) {
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
    }

    private func setVerticalScrollIndicatorTopInset(_ topInset: CGFloat, for scrollView: UIScrollView) {
        var indicatorInsets = scrollView.verticalScrollIndicatorInsets
        indicatorInsets.top = topInset
        scrollView.verticalScrollIndicatorInsets = indicatorInsets
    }

    private func applyTopInset(_ topInset: CGFloat, to scrollView: UIScrollView, forcePinToTop: Bool) {
        let targetTopInset = max(0, topInset)
        let currentTopInset = scrollView.contentInset.top
        guard abs(currentTopInset - targetTopInset) > 0.5 || forcePinToTop else { return }

        let isInteracting = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        let previousMinOffsetY = -scrollView.adjustedContentInset.top
        let wasPinnedToTop = scrollView.contentOffset.y <= previousMinOffsetY + 5

        scrollView.contentInset.top = targetTopInset
        setVerticalScrollIndicatorTopInset(targetTopInset, for: scrollView)

        let updatedMinOffsetY = -scrollView.adjustedContentInset.top
        if forcePinToTop || (wasPinnedToTop && !isInteracting) {
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: updatedMinOffsetY), animated: false)
        }
    }

    private func loadContent(into webView: WKWebView, coordinator: Coordinator, forcePinToTop: Bool) {
        coordinator.lastLoadedArticleLink = articleLink
        coordinator.lastLoadedContentID = htmlContentID
        coordinator.lastLoadedHTML = htmlContent
        coordinator.prepareForContentLoad(
            in: webView.scrollView,
            topInset: topInset,
            collapseProgress: initialHeaderCollapseProgress,
            animated: false
        )

        if let localFileURL = OfflineArticleArchive.existingPreparedReaderHTMLDocumentURL(forContentID: htmlContentID),
           let readAccessURL = OfflineArticleArchive.readAccessURL() {
            coordinator.lastLoadedFilePath = localFileURL.path
            webView.loadFileURL(localFileURL, allowingReadAccessTo: readAccessURL)
        } else {
            coordinator.lastLoadedFilePath = nil
            webView.loadHTMLString(htmlContent, baseURL: articleURL ?? youtubeEmbedBaseURL)
            let contentID = htmlContentID
            let document = htmlContent
            let sourceURL = articleURL
            Task.detached(priority: .utility) {
                OfflineArticleArchive.prepareReaderHTMLDocumentIfNeeded(
                    forContentID: contentID,
                    articleURL: sourceURL,
                    htmlDocument: document
                )
            }
        }

        applyTopInset(topInset, to: webView.scrollView, forcePinToTop: forcePinToTop)
    }

    class Coordinator: NSObject, UIScrollViewDelegate, WKNavigationDelegate, UIGestureRecognizerDelegate {
        let scrollState: FeedDetailScrollState
        var onSwipeLeft: () -> Void
        var onSwipeRight: () -> Void
        private let collapseUpdateThreshold: CGFloat = 0.012
        private let minimumUpdateInterval: CFTimeInterval = 1.0 / 30.0
        private let readingProgressUpdateThreshold: CGFloat = 0.01
        private let readingProgressUpdateInterval: CFTimeInterval = 0.75
        private var lastProgressUpdateTime: CFTimeInterval = 0
        private var lastReadingProgressUpdateTime: CFTimeInterval = 0
        private var lastPublishedReadingProgress: CGFloat = -1
        private var didInstallSwipeRecognizers = false
        private var pendingTopReset = false
        private var pendingTopInset: CGFloat = 0
        private var pendingInitialCollapseProgress: CGFloat = 0
        var lastLoadedArticleLink: String?
        var lastLoadedContentID: String?
        var lastLoadedHTML: String = ""
        var lastLoadedFilePath: String?

        init(scrollState: FeedDetailScrollState,
             onSwipeLeft: @escaping () -> Void,
             onSwipeRight: @escaping () -> Void) {
            self.scrollState = scrollState
            self.onSwipeLeft = onSwipeLeft
            self.onSwipeRight = onSwipeRight
        }

        func configureGestureRecognizers(for webView: WKWebView) {
            guard !didInstallSwipeRecognizers else { return }
            didInstallSwipeRecognizers = true

            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleArticleSwipe(_:)))
                recognizer.direction = direction
                recognizer.delegate = self
                webView.addGestureRecognizer(recognizer)
            }
        }

        @objc private func handleArticleSwipe(_ recognizer: UISwipeGestureRecognizer) {
            switch recognizer.direction {
            case .left:
                onSwipeLeft()
            case .right:
                onSwipeRight()
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateHeaderCollapseProgress(in: scrollView, force: false)
        }

        func scrollViewDidEndDragging(
            _ scrollView: UIScrollView,
            willDecelerate decelerate: Bool
        ) {
            if !decelerate {
                updateHeaderCollapseProgress(in: scrollView, force: true)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateHeaderCollapseProgress(in: scrollView, force: true)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            updateHeaderCollapseProgress(in: scrollView, force: true)
        }

        private func updateHeaderCollapseProgress(in scrollView: UIScrollView, force: Bool) {
            let now = CACurrentMediaTime()
            guard force || now - lastProgressUpdateTime >= minimumUpdateInterval else {
                return
            }
            lastProgressUpdateTime = now

            let currentOffset = scrollView.contentOffset.y
            let topInset = scrollView.adjustedContentInset.top
            let bottomInset = scrollView.adjustedContentInset.bottom
            let minOffsetY = -topInset
            let maxOffsetY = max(minOffsetY, scrollView.contentSize.height - scrollView.bounds.height + bottomInset)

            let clampedOffsetY = min(max(currentOffset, minOffsetY), maxOffsetY)
            let scrollDistanceFromTop = max(0, clampedOffsetY - minOffsetY)
            let scrollableDistance = max(1, maxOffsetY - minOffsetY)
            let isActivelyScrolling = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            let progress = FeedDetailLayout.clampedProgress(
                scrollDistanceFromTop / FeedDetailLayout.headerCollapseRange
            )
            let readingProgress = FeedDetailLayout.clampedProgress(scrollDistanceFromTop / scrollableDistance)
            publishReadingProgress(readingProgress, force: force, now: now)

            // Keep active WebKit scrolling mostly native. SwiftUI follows only
            // coarse visible progress changes instead of every WebKit scroll tick.
            let chromeCanMove = progress < 1 || scrollState.collapseProgress < 1
            let progressChanged = force || abs(progress - scrollState.collapseProgress) > collapseUpdateThreshold
            if progressChanged
                && (
                    force
                    || (isActivelyScrolling && chromeCanMove)
                ) {
                updateCollapseProgress(progress)
            }
        }

        func resetScrollState(collapseProgress: CGFloat = 0) {
            lastProgressUpdateTime = 0
            updateCollapseProgress(FeedDetailLayout.clampedProgress(collapseProgress))
        }

        private func publishReadingProgress(_ progress: CGFloat, force: Bool, now: CFTimeInterval) {
            guard let link = lastLoadedArticleLink, !link.isEmpty else { return }
            let shouldPublish = force
                || abs(progress - lastPublishedReadingProgress) >= readingProgressUpdateThreshold
                || now - lastReadingProgressUpdateTime >= readingProgressUpdateInterval
            guard shouldPublish else { return }

            lastPublishedReadingProgress = progress
            lastReadingProgressUpdateTime = now
            Task { @MainActor in
                ReadingLiveActivityManager.shared.updateReadingProgress(Double(progress), for: link)
            }
        }

        func prepareForContentLoad(in scrollView: UIScrollView,
                                   topInset: CGFloat,
                                   collapseProgress: CGFloat,
                                   animated: Bool) {
            pendingTopReset = true
            pendingTopInset = max(0, topInset)
            pendingInitialCollapseProgress = FeedDetailLayout.clampedProgress(collapseProgress)
            enforceTopPosition(in: scrollView, animated: animated)
        }

        private func enforceTopPosition(in scrollView: UIScrollView, animated: Bool) {
            scrollView.contentInset.top = pendingTopInset
            var indicatorInsets = scrollView.verticalScrollIndicatorInsets
            indicatorInsets.top = pendingTopInset
            scrollView.verticalScrollIndicatorInsets = indicatorInsets

            let minimumOffsetY = -scrollView.adjustedContentInset.top
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: minimumOffsetY),
                animated: animated
            )
            resetScrollState(collapseProgress: pendingInitialCollapseProgress)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard pendingTopReset else { return }
            pendingTopReset = false
            enforceTopPosition(in: webView.scrollView, animated: false)

            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView else { return }
                self.enforceTopPosition(in: webView.scrollView, animated: false)
            }
        }

        private func updateCollapseProgress(_ newValue: CGFloat) {
            if scrollState.collapseProgress != newValue {
                scrollState.collapseProgress = newValue
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme?.lowercased() != "about",
               url.scheme?.lowercased() != "file" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

private struct ArticleSummaryView: View {
    private static let summaryCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()

    private static let summaryInstructions = """
Du erstellst praezise, vollstaendige Artikelzusammenfassungen fuer eine RSS-App.
Antworte immer auf Deutsch.
Gib nur separate Stichpunkte zurueck, pro Zeile genau einen Punkt.
Keine Ueberschrift, keine Einleitung, keine Nummerierung, kein Fazit und kein Markdown.

Jeder Stichpunkt muss ein vollstaendiger, grammatikalisch korrekter Satz sein.
Keine Satzfragmente, keine elliptischen Formulierungen.

Bewahre alle Zahlen, Daten, Namen, Orte, Zitate, Einheiten und Fakten exakt und unveraendert.
Zahlen und Einheiten duerfen nicht getrennt oder umformuliert werden.
Keine Aufsplittung von Informationen ueber mehrere Stichpunkte hinweg, wenn sie zusammengehoeren.
Schliesse jeden Stichpunkt vollstaendig ab, bevor du den naechsten beginnst.
Ein Datum wie "4. Juni 2026" muss immer in derselben Zeile stehen.
Keine Zeile darf mit einer Praeposition, Konjunktion, einem offenen Zitat oder einem unvollstaendigen Namen enden.

Rechtschreibung und Grammatik muessen korrekt sein.
Falls der Quelltext sprachliche Fehler enthaelt, wird der Satz korrekt formuliert, ohne den Inhalt zu veraendern.

Trenne Tatsachen, Aussagen von Personen und Prognosen klar sprachlich.
Erfinde keine Zusammenhaenge und nutze den Titel nicht als Beleg.
Nenne ausschliesslich Informationen, die im Artikeltext klar belegt sind.
Vermeide Wiederholungen, Wertungen, Fuellsaetze und allgemeine Aussagen ohne Informationswert.

Jeder Stichpunkt soll in sich vollstaendig, lesbar und direkt verstandlich sein.
"""

    private struct SummaryLayoutProfile {
        let sourceWordCount: Int
        let targetWordCount: Int
        let bulletCount: Int
        let minWordsPerBullet: Int
        let maxWordsPerBullet: Int
    }

    private enum SummaryState {
        case loading
        case ready([String])
        case unavailable(String)
        case failed(String)
    }

    let title: String
    let sourceText: String
    let link: String
    let feedColor: Color
    let topInset: CGFloat
    let dismissRequestID: Int
    let regenerationRequestID: Int
    let onGenerationStateChange: (Bool) -> Void
    let onSharePayloadChange: (String?) -> Void
    let onDismissAnimationComplete: () -> Void
    @EnvironmentObject private var store: ArticleStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var model = SystemLanguageModel.default
    @State private var summaryState: SummaryState = .loading
    @State private var isRefreshing = false
    @State private var visibleBulletCount = 0
    @State private var isConcealingBullets = false

    private var sharePayload: String? {
        guard case .ready(let bullets) = summaryState else { return nil }
        let summary = bullets.map { "\u{2022} \($0)" }.joined(separator: "\n")
        return [title, summary, link]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private var preparedSourceText: String {
        Self.preparedSourceText(from: sourceText)
    }

    private var summaryLayout: SummaryLayoutProfile {
        Self.summaryLayoutProfile(for: preparedSourceText)
    }

    private var sourceSignature: String {
        Self.sourceSignature(for: preparedSourceText, title: title)
    }

    private var isGenerating: Bool {
        if case .loading = summaryState {
            return true
        }
        return false
    }

    private var summaryFooterHeight: CGFloat {
        let textLineHeight = UIFont.preferredFont(forTextStyle: .subheadline).lineHeight + 5
        return FeedDetailLayout.compactToolbarHitTarget + textLineHeight * 2
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryContent
                .padding(.horizontal, UIStylePolicy.Spacing.xLarge)
                .padding(.top, UIStylePolicy.Spacing.large)
                .padding(.bottom, UIStylePolicy.Spacing.xLarge)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, topInset)
        .task(id: generationTaskID) {
            await generateSummaryIfNeeded()
        }
        .task(id: dismissRequestID) {
            guard dismissRequestID > 0 else { return }
            await concealSummaryContent()
        }
        .task(id: regenerationRequestID) {
            guard regenerationRequestID > 0 else { return }
            await regenerateSummary()
        }
        .onChange(of: isGenerating, initial: true) { _, newValue in
            onGenerationStateChange(newValue)
        }
        .onChange(of: sharePayload, initial: true) { _, newValue in
            onSharePayloadChange(newValue)
        }
    }

    private var generationTaskID: String {
        "\(link)|\(sourceSignature)"
    }

    @ViewBuilder
    private var summaryContent: some View {
        switch summaryState {
        case .loading:
            VStack(spacing: UIStylePolicy.Spacing.medium) {
                ProgressView()
                    .controlSize(.large)
                    .tint(feedColor)

                Text(isRefreshing ? "Wird aktualisiert" : "Artikel wird ausgewertet")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Die Zusammenfassung wird lokal erstellt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let bullets):
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(bullets.enumerated()), id: \.offset) { index, bullet in
                        HStack(alignment: .firstTextBaseline, spacing: UIStylePolicy.Spacing.large) {
                            Text(String(format: "%02d", index + 1))
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(feedColor)
                                .frame(width: 22, alignment: .leading)

                            Text(bullet)
                                .font(AppTypography.secondary)
                                .foregroundStyle(.primary.opacity(0.92))
                                .lineSpacing(5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, UIStylePolicy.Spacing.large)
                        .opacity(index < visibleBulletCount ? 1 : 0)
                        .offset(y: index < visibleBulletCount ? 0 : -10)

                        if index < bullets.count - 1 {
                            Divider()
                                .padding(.leading, 22 + UIStylePolicy.Spacing.large)
                                .opacity(index < visibleBulletCount ? 0.45 : 0)
                        }
                    }
                }
                .padding(.bottom, summaryFooterHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
            .task(id: bulletRevealID(for: bullets)) {
                await revealBullets(count: bullets.count)
            }
        case .unavailable(let message):
            summaryStatusView(
                iconName: "sparkles.slash",
                title: "Zusammenfassung nicht verfügbar",
                message: message
            )
        case .failed(let message):
            summaryStatusView(
                iconName: "exclamationmark.triangle",
                title: "Zusammenfassung fehlgeschlagen",
                message: message
            )
        }
    }

    private func summaryStatusView(iconName: String, title: String, message: String) -> some View {
        summaryCard {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(feedColor)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(message)
                .foregroundStyle(.secondary)
            if !sourcePreview.isEmpty {
                Text(sourcePreview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
        }
    }

    private var sourcePreview: String {
        let prepared = preparedSourceText
        guard !prepared.isEmpty else { return "" }
        if prepared.count <= 420 {
            return prepared
        }
        return String(prepared.prefix(420)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func bulletRevealID(for bullets: [String]) -> String {
        "\(generationTaskID)|\(bullets.joined(separator: "|").hashValue)"
    }

    @MainActor
    private func revealBullets(count: Int) async {
        isConcealingBullets = false
        visibleBulletCount = accessibilityReduceMotion ? count : 0
        guard !accessibilityReduceMotion else { return }

        for index in 0..<count {
            guard !Task.isCancelled, !isConcealingBullets else { return }
            if index > 0 {
                try? await Task.sleep(for: .milliseconds(105))
            }
            guard !Task.isCancelled, !isConcealingBullets else { return }
            withAnimation(.smooth(duration: 0.32)) {
                visibleBulletCount = index + 1
            }
        }
    }

    @MainActor
    private func concealSummaryContent() async {
        isConcealingBullets = true

        guard case .ready = summaryState, !accessibilityReduceMotion else {
            visibleBulletCount = 0
            onDismissAnimationComplete()
            return
        }

        while visibleBulletCount > 0 {
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.22)) {
                visibleBulletCount -= 1
            }
            try? await Task.sleep(for: .milliseconds(85))
        }

        guard !Task.isCancelled else { return }
        onDismissAnimationComplete()
    }

    @MainActor
    private func generateSummaryIfNeeded() async {
        let preparedSource = preparedSourceText
        guard !preparedSource.isEmpty else {
            summaryState = .failed("Für diesen Artikel ist nicht genug Text für eine Zusammenfassung verfügbar.")
            return
        }

        let cacheKey = Self.cacheKey(link: link, sourceSignature: sourceSignature)
        if let cached = Self.summaryCache.object(forKey: cacheKey) {
            let bullets = Self.normalizedBullets(from: cached as String, layout: summaryLayout)
            if Self.isCompleteSummary(bullets, layout: summaryLayout) {
                summaryState = .ready(bullets)
                return
            }
        }

        if let persistedSummary = store.summary(articleID: link, matching: sourceSignature) {
            let bullets = Self.normalizedBullets(from: persistedSummary, layout: summaryLayout)
            if Self.isCompleteSummary(bullets, layout: summaryLayout) {
                Self.summaryCache.setObject(persistedSummary as NSString, forKey: cacheKey)
                summaryState = .ready(bullets)
                return
            }
        }

        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            summaryState = .unavailable(Self.message(for: reason))
            return
        }

        summaryState = .loading

        do {
            let session = LanguageModelSession(
                model: model,
                instructions: Self.summaryInstructions
            )
            let bullets = try await generateValidatedBullets(
                using: session,
                preparedSource: preparedSource
            )

            guard !Task.isCancelled else { return }

            guard !bullets.isEmpty else {
                summaryState = .failed("Die Zusammenfassung war unvollständig. Bitte versuche es erneut.")
                return
            }

            let persistedSummary = bullets.joined(separator: "\n")
            Self.summaryCache.setObject(persistedSummary as NSString, forKey: cacheKey)
            store.saveSummary(persistedSummary, articleID: link, sourceSignature: sourceSignature)
            summaryState = .ready(bullets)
            isRefreshing = false
        } catch let error as LanguageModelSession.GenerationError {
            guard !Task.isCancelled else { return }
            summaryState = .failed(Self.message(for: error))
            isRefreshing = false
        } catch {
            guard !Task.isCancelled else { return }
            summaryState = .failed("Die Zusammenfassung konnte gerade nicht erstellt werden.")
            isRefreshing = false
        }
    }

    @MainActor
    private func regenerateSummary() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        summaryState = .loading

        let cacheKey = Self.cacheKey(link: link, sourceSignature: sourceSignature)
        Self.summaryCache.removeObject(forKey: cacheKey)
        await generateFreshSummary()
    }

    @MainActor
    private func generateFreshSummary() async {
        let preparedSource = preparedSourceText
        guard !preparedSource.isEmpty else {
            isRefreshing = false
            summaryState = .failed("Für diesen Artikel ist nicht genug Text für eine Zusammenfassung verfügbar.")
            return
        }

        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            isRefreshing = false
            summaryState = .unavailable(Self.message(for: reason))
            return
        }

        do {
            let session = LanguageModelSession(model: model, instructions: Self.summaryInstructions)
            let bullets = try await generateValidatedBullets(
                using: session,
                preparedSource: preparedSource
            )
            guard !Task.isCancelled else { return }

            guard !bullets.isEmpty else {
                isRefreshing = false
                summaryState = .failed("Die Zusammenfassung war unvollständig. Bitte versuche es erneut.")
                return
            }

            let persistedSummary = bullets.joined(separator: "\n")
            let cacheKey = Self.cacheKey(link: link, sourceSignature: sourceSignature)
            Self.summaryCache.setObject(persistedSummary as NSString, forKey: cacheKey)
            store.saveSummary(persistedSummary, articleID: link, sourceSignature: sourceSignature)
            isRefreshing = false
            summaryState = .ready(bullets)
        } catch let error as LanguageModelSession.GenerationError {
            guard !Task.isCancelled else { return }
            isRefreshing = false
            summaryState = .failed(Self.message(for: error))
        } catch {
            guard !Task.isCancelled else { return }
            isRefreshing = false
            summaryState = .failed("Die Zusammenfassung konnte gerade nicht erstellt werden.")
        }
    }

    @MainActor
    private func generateValidatedBullets(
        using session: LanguageModelSession,
        preparedSource: String
    ) async throws -> [String] {
        let basePrompt = Self.summaryPrompt(
            title: title,
            sourceText: preparedSource,
            layout: summaryLayout
        )
        var bestUsableBullets: [String] = []

        for attempt in 0..<2 {
            let prompt: String
            if attempt == 0 {
                prompt = basePrompt
            } else {
                prompt = """
                Die vorherige Ausgabe enthielt getrennte oder unvollstaendige Saetze.
                Erstelle die Zusammenfassung erneut und beende ausnahmslos jede Zeile vollstaendig.

                \(basePrompt)
                """
            }

            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 520)
            )
            guard !Task.isCancelled else { return [] }

            let bullets = Self.normalizedBullets(from: response.content, layout: summaryLayout)
            if Self.meetsTargetSummary(bullets, layout: summaryLayout) {
                return bullets
            }

            let completeBullets = bullets.filter {
                Self.isCompleteBullet($0, layout: summaryLayout)
            }
            if completeBullets.count > bestUsableBullets.count {
                bestUsableBullets = completeBullets
            }
        }

        return bestUsableBullets.count >= 3 ? bestUsableBullets : []
    }

    private nonisolated static func cacheKey(link: String, sourceSignature: String) -> NSString {
        "\(link)|\(sourceSignature)" as NSString
    }

    private nonisolated static func preparedSourceText(from sourceText: String) -> String {
        let normalized = HTMLText.normalizePreviewSpacing(in: sourceText)
        return String(normalized.prefix(20_000))
    }

    private nonisolated static func sourceSignature(for sourceText: String, title: String) -> String {
        let normalizedTitle = HTMLText.normalizePreviewSpacing(in: title)
        let digest = SHA256.hash(data: Data(("summary-v5-title|" + normalizedTitle + "|" + sourceText).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func summaryLayoutProfile(for sourceText: String) -> SummaryLayoutProfile {
        let wordCount = max(1, sourceText.split(whereSeparator: \.isWhitespace).count)
        let proportionalWordCount = Int((Double(wordCount) * 0.20).rounded())
        let targetWordCount = min(170, max(90, proportionalWordCount))
        let bulletCount: Int
        if targetWordCount >= 145 {
            bulletCount = 7
        } else if targetWordCount >= 115 {
            bulletCount = 6
        } else {
            bulletCount = 5
        }
        let averageWordsPerBullet = Int(ceil(Double(targetWordCount) / Double(bulletCount)))

        return SummaryLayoutProfile(
            sourceWordCount: wordCount,
            targetWordCount: targetWordCount,
            bulletCount: bulletCount,
            minWordsPerBullet: max(15, averageWordsPerBullet - 4),
            maxWordsPerBullet: min(30, averageWordsPerBullet + 5)
        )
    }

    private nonisolated static func summaryPrompt(title: String, sourceText: String, layout: SummaryLayoutProfile) -> String {
        """
        Erstelle eine gut lesbare, mobile Artikelzusammenfassung.
        Gib exakt \(layout.bulletCount) Zeilen aus.
        Zielumfang: insgesamt mindestens \(layout.targetWordCount) und hoechstens \(layout.targetWordCount + 25) Woerter.
        Jede Zeile soll ungefaehr \(layout.minWordsPerBullet)-\(layout.maxWordsPerBullet) Woerter haben.
        Ordne nach Relevanz: zentrale Nachricht zuerst, danach Ursachen, wichtige Details, Zahlen, Reaktionen und Folgen.
        Beruecksichtige Gegenpositionen oder Unsicherheiten, wenn der Text sie nennt.
        Wiederhole weder Titel noch dieselbe Aussage in anderer Form.
        Keine Zeile darf leer sein.
        Beende jede Zeile als vollstaendigen Satz. Trenne niemals ein Datum, einen Namen oder ein Zitat auf zwei Zeilen.
        Nutze den Titel nur als Fokus-Signal, um aus dem Artikeltext die wichtigsten passenden Inhalte auszuwaehlen.
        Erklaere, paraphrasiere oder interpretiere den Titel nicht.
        Formuliere keine Zeile nach dem Muster "Der Titel besagt..." oder "Es geht um...".
        Der Titel ist keine Faktenquelle: Jede Aussage muss im Artikeltext belegt sein.

        Artikeltitel:
        \(title)

        Artikeltext:
        \(sourceText)
        """
    }

    private nonisolated static func normalizedBullets(from response: String, layout: SummaryLayoutProfile) -> [String] {
        let normalizedResponse = response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { HTMLText.normalizePreviewSpacing(in: $0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lineBullets = Self.repairedBulletLines(
            normalizedResponse
            .components(separatedBy: .newlines)
            .map(Self.cleanBulletLine)
            .filter { !$0.isEmpty }
        )

        if lineBullets.count >= max(3, layout.bulletCount - 1) {
            return Array(lineBullets.prefix(layout.bulletCount))
        }

        let sentenceBullets = Self.repairedBulletLines(
            normalizedResponse
            .replacingOccurrences(of: "(?<=[.!?])\\s+", with: "\n", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map(Self.cleanBulletLine)
            .filter { !$0.isEmpty }
        )

        return Array(sentenceBullets.prefix(layout.bulletCount))
    }

    private nonisolated static func repairedBulletLines(_ lines: [String]) -> [String] {
        var repaired: [String] = []

        for line in lines {
            guard let previous = repaired.last else {
                repaired.append(line)
                continue
            }

            if shouldJoin(previous: previous, continuation: line) {
                repaired[repaired.count - 1] = HTMLText.normalizePreviewSpacing(
                    in: previous + " " + line
                )
            } else {
                repaired.append(line)
            }
        }

        return repaired
    }

    private nonisolated static func shouldJoin(previous: String, continuation: String) -> Bool {
        guard !previous.isEmpty, !continuation.isEmpty else { return false }

        if previous.range(
            of: #"\b\d{1,2}\.$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil,
           continuation.range(
            of: #"^(?:Januar|Februar|Maerz|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)\b"#,
            options: [.regularExpression, .caseInsensitive]
           ) != nil {
            return true
        }

        guard let lastCharacter = previous.last else { return false }
        if !".!?…".contains(lastCharacter) {
            return true
        }

        return continuation.first?.isLowercase == true
    }

    private nonisolated static func isCompleteSummary(
        _ bullets: [String],
        layout: SummaryLayoutProfile
    ) -> Bool {
        guard bullets.count >= 3 else { return false }
        return bullets.allSatisfy { isCompleteBullet($0, layout: layout) }
    }

    private nonisolated static func meetsTargetSummary(
        _ bullets: [String],
        layout: SummaryLayoutProfile
    ) -> Bool {
        guard bullets.count >= max(3, layout.bulletCount - 1) else { return false }
        return bullets.allSatisfy { isCompleteBullet($0, layout: layout) }
    }

    private nonisolated static func isCompleteBullet(
        _ bullet: String,
        layout: SummaryLayoutProfile
    ) -> Bool {
        let trimmed = bullet.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        guard wordCount >= max(6, layout.minWordsPerBullet / 2) else { return false }

        let closingCharacters = CharacterSet(charactersIn: "\"'”’»)]}")
        let sentence = trimmed.trimmingCharacters(in: closingCharacters)
        guard let finalCharacter = sentence.last, ".!?…".contains(finalCharacter) else {
            return false
        }

        let danglingPatterns = [
            #"\b(?:v|vs)\.$"#,
            #"[,:;\-–—]\s*$"#,
            #"[\"'„“‚‘]\s*$"#,
            #"\b(?:und|oder|aber|sowie|weil|dass|mit|von|fuer|für|gegen|durch|als|bei|zu)\s*[.!?…]$"#
        ]

        return !danglingPatterns.contains { pattern in
            sentence.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private nonisolated static func cleanBulletLine(_ rawLine: String) -> String {
        let withoutMarkers = rawLine.replacingOccurrences(
            of: #"^\s*(?:[-•*]|\d+[.)]|Zusammenfassung:|Summary:)\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let normalized = HTMLText.normalizePreviewSpacing(in: withoutMarkers)
        return normalized
    }

    private func summaryCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: UIStylePolicy.Spacing.medium) {
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(feedColor.opacity(0.16), lineWidth: 1)
                }
        }
    }

    private nonisolated static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Apple Intelligence ist auf diesem Gerät nicht verfügbar."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence ist deaktiviert. Aktiviere es in den Systemeinstellungen."
        case .modelNotReady:
            return "Das Modell ist noch nicht bereit. Versuche es in einem Moment erneut."
        @unknown default:
            return "Apple Intelligence ist auf diesem Gerät derzeit nicht verfügbar."
        }
    }

    private nonisolated static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .unsupportedLanguageOrLocale(_):
            return "Für diese Sprache oder Region konnte keine Zusammenfassung erstellt werden."
        case .assetsUnavailable(_):
            return "Das lokale Modell ist im Moment nicht bereit."
        case .exceededContextWindowSize(_):
            return "Der Artikel ist zu umfangreich für eine kompakte lokale Zusammenfassung."
        case .guardrailViolation(_), .refusal(_, _):
            return "Für diesen Inhalt konnte keine Zusammenfassung erstellt werden."
        case .concurrentRequests(_):
            return "Die Zusammenfassung wird bereits erstellt. Bitte kurz warten."
        case .decodingFailure(_), .unsupportedGuide(_), .rateLimited(_):
            return error.errorDescription ?? "Die Zusammenfassung konnte nicht zuverlässig erzeugt werden."
        @unknown default:
            return error.errorDescription ?? "Die Zusammenfassung konnte gerade nicht erstellt werden."
        }
    }
}

#Preview("Feed Detail – Long Content") {
    let paragraph = "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus luctus, nisl at iaculis aliquet, velit nunc pulvinar ligula, sed tincidunt arcu ac lorem. Curabitur fringilla, nibh at dictum bibendum, nisi nunc volutpat orci, non egestas velit justo nec justo.</p>"
    let image = "<img src=\"https://picsum.photos/1200/800\" alt=\"Preview image\" />"
    let iframe = "<iframe src=\"https://www.youtube.com/embed/dQw4w9WgXcQ\" allowfullscreen></iframe>"
    let longHTML = (0..<8).map { index in
        "<section><h2>Abschnitt \(index + 1)</h2>\(paragraph)\(paragraph)\(index.isMultiple(of: 2) ? image : "")\(index.isMultiple(of: 3) ? iframe : "")</section>"
    }.joined(separator: "\n")

    let sampleEntry = FeedEntry(
        title: "Feed-Detail Preview mit langem Inhalt",
        shortTitle: "Preview",
        link: "https://example.com/articles/feed-detail-preview",
        content: longHTML,
        contentRaw: longHTML,
        imageURL: "https://picsum.photos/1200/800",
        author: "NotiFeeder Redaktion",
        sourceTitle: "Preview Feed",
        feedURL: "https://example.com/feed.xml",
        pubDateString: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)),
        isRead: false
    )

    NavigationStack {
        FeedDetailView(entry: sampleEntry, feedColor: .blue)
            .environmentObject(ThemeSettings())
            .environmentObject(ArticleStore.shared)
    }
    .modelContainer(for: FeedEntryModel.self, inMemory: true)
}
