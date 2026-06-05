import WebKit
import SwiftUI
import Foundation
import FoundationModels
import SwiftData
import UIKit
import CryptoKit

extension Color {
    var rgbComponents: (red: Int, green: Int, blue: Int)? {
        #if canImport(UIKit)
        typealias NativeColor = UIColor
        #elseif canImport(AppKit)
        typealias NativeColor = NSColor
        #endif

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard NativeColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }

        return (Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

private enum FeedDetailLayout {
    static let expandedHeaderHeight: CGFloat = 92
    static let headerCollapseOffset: CGFloat = 40
    static let compactToolbarSpacing: CGFloat = 6
    static let compactToolbarHorizontalPadding: CGFloat = 2
    static let compactToolbarHitTarget: CGFloat = 40
}

private struct FeedDetailHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = FeedDetailLayout.expandedHeaderHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct FeedDetailView: View {
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

    var entry: FeedEntry
    var feedColor: Color?
    var entriesProvider: () -> [FeedEntry] = { [] }
    var onNavigateToEntry: (FeedEntry, NavigationDirection) -> Void = { _, _ in }
    /// Optional callback invoked when the read/unread state is toggled in this detail view.
    var onToggleRead: ((Bool) -> Void)? = nil
    /// Optional callback invoked when bookmark state changes in this detail view.
    var onToggleBookmark: ((Bool) -> Void)? = nil

    enum NavigationDirection {
        case previous
        case next
    }

    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var store: ArticleStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    
    // --- UNIFIED COLLAPSE BEHAVIOR FOR TOOLBARS (scroll drives collapse; taps expand sides) ---
    @State private var collapseProgress: CGFloat = 0
    @State private var isLeftBarExpanded = true
    @State private var isRightBarExpanded = true
    @State private var bothExpanded = true
    @State private var readingProgress: CGFloat = 0
    @State private var headerHeight: CGFloat = FeedDetailLayout.expandedHeaderHeight

    @State private var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.showsHorizontalScrollIndicator = false
        return wv
    }()
    
    @State private var activeSheet: ActiveSheet?
    @State private var isReadLocal: Bool = false
    @State private var isBookmarked: Bool = false
    @State private var pendingNavigationDirection: NavigationDirection?
    @State private var contentOffset: CGFloat = 0
    @State private var contentOpacity: Double = 1
    @State private var hasAppeared = false
    @AppStorage("readerFontScale") private var readerFontScale: Double = 1.0
    @AppStorage("readerFontFamily") private var readerFontFamily: String = ReaderFontFamily.rounded.rawValue
    @AppStorage("readerLineSpacing") private var readerLineSpacing: Double = 1.4
    @AppStorage("readerTextAlignment") private var readerTextAlignmentRaw: String = "left"

    private enum ActiveSheet: Identifiable {
        case share(payload: String, token: UUID = UUID())
        case articleSummary
        case readerSettings
        var id: UUID {
            switch self {
            case .share(_, let token): return token
            case .articleSummary: return ActiveSheet.articleSummaryID
            case .readerSettings: return ActiveSheet.readerSettingsID
            }
        }
        private static let articleSummaryID = UUID()
        private static let readerSettingsID = UUID()
    }

    init(entry: FeedEntry,
         feedColor: Color? = nil,
         onToggleRead: ((Bool) -> Void)? = nil,
         onToggleBookmark: ((Bool) -> Void)? = nil) {
        self.entry = entry
        self.feedColor = feedColor
        self.onToggleRead = onToggleRead
        self.onToggleBookmark = onToggleBookmark
    }

    init(entry: FeedEntry,
         feedColor: Color? = nil,
         entriesProvider: @escaping () -> [FeedEntry],
         onNavigateToEntry: @escaping (FeedEntry, NavigationDirection) -> Void,
         onToggleRead: ((Bool) -> Void)? = nil,
         onToggleBookmark: ((Bool) -> Void)? = nil) {
        self.entry = entry
        self.feedColor = feedColor
        self.entriesProvider = entriesProvider
        self.onNavigateToEntry = onNavigateToEntry
        self.onToggleRead = onToggleRead
        self.onToggleBookmark = onToggleBookmark
    }

    private func currentIndex(in list: [FeedEntry]) -> Int? {
        list.firstIndex(where: { $0.link == entry.link })
    }

    private var isAtFirstEntry: Bool {
        let list = entriesProvider()
        guard let idx = currentIndex(in: list) else { return false }
        return idx == list.startIndex
    }

    private var isAtLastEntry: Bool {
        let list = entriesProvider()
        guard let idx = currentIndex(in: list) else { return false }
        return list.index(after: idx) == list.endIndex
    }

    private func goToPrevious() {
        let list = entriesProvider()
        guard !list.isEmpty, let currentIndex = currentIndex(in: list), currentIndex > list.startIndex else { return }
        let target = list[list.index(before: currentIndex)]
        pendingNavigationDirection = .previous
        AppHaptics.softImpact()
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

            HStack(spacing: 4) {
                Text("\(entry.author ?? "Unbekannt")")
                Text("·")
                Text(entry.sourceTitle ?? "Unbekannte Quelle")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)

            HStack(spacing: 8) {
                if let publishDateLabel {
                    Text(publishDateLabel)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "eyeglasses")
                        .fontWeight(.light)
                    Text(readingTimeLabel)
                }
                .multilineTextAlignment(.trailing)
            }
            .font(.footnote)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }
    
    @ToolbarContentBuilder
    private var dynamicBottomToolbar: some ToolbarContent {
        
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: { toggleBookmark() }) {
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
            .minimumHitTarget()
            .accessibilityLabel(isBookmarked ? "Lesezeichen entfernen" : "Lesezeichen setzen")
            .foregroundStyle(isBookmarked ? resolvedFeedColor : UIStylePolicy.neutralIcon)
        }
        
        ToolbarItemGroup(placement: .bottomBar) {
            // Left cluster
            if bothExpanded || isLeftBarExpanded {
                HStack(spacing: FeedDetailLayout.compactToolbarSpacing) {
                    Button(action: {
                        AppHaptics.selection()
                        activeSheet = .readerSettings
                    }) {
                        Image(systemName: "textformat.size")
                            .fontWeight(.light)
                            .foregroundStyle(resolvedFeedColor)
                    }
                    .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
                    .accessibilityLabel("Lesedarstellung")
                    .accessibilityHint("Öffnet Einstellungen für Schrift und Layout")
                    Button(action: {
                        AppHaptics.lightImpact()
                        if let url = URL(string: entry.link) { UIApplication.shared.open(url) }
                    }) {
                        Image(systemName: "safari")
                            .fontWeight(.light)
                            .foregroundStyle(resolvedFeedColor)
                    }
                    .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
                    .accessibilityLabel("In Safari öffnen")
                    Button(action: {
                        AppHaptics.selection()
                        gatherShareContent()
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .fontWeight(.light)
                            .foregroundStyle(resolvedFeedColor)
                    }
                    .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
                    .accessibilityLabel("Teilen")
                    Button(action: {
                        AppHaptics.selection()
                        activeSheet = .articleSummary
                    }) {
                        Image(systemName: "text.line.3.summary")
                            .fontWeight(.light)
                            .foregroundStyle(resolvedFeedColor)
                    }
                    .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
                    .accessibilityLabel("Zusammenfassung anzeigen")
                    Button(action: { onToggleReadAction() }) {
                        Image(systemName: isReadLocal ? "eye.slash" : "eye")
                            .fontWeight(.light)
                            .foregroundStyle(isReadLocal ? resolvedFeedColor : UIStylePolicy.neutralIcon)
                    }
                    .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
                    .accessibilityLabel(isReadLocal ? "Als ungelesen markieren" : "Als gelesen markieren")
                }
                .padding(.horizontal, FeedDetailLayout.compactToolbarHorizontalPadding)
            } else {
                Button {
                    AppHaptics.selection()
                    isLeftBarExpanded = true
                    bothExpanded = true
                } label: {
                    Image(systemName: "ellipsis")
                        .fontWeight(.light)
                        .foregroundStyle(resolvedFeedColor)
                }
                .minimumHitTarget()
                .accessibilityLabel("Aktionen einblenden")
            }

            Spacer(minLength: 2)

            // Right cluster
            if bothExpanded || isRightBarExpanded {
                HStack(spacing: FeedDetailLayout.compactToolbarSpacing) {
                    Button(action: { goToPrevious() }) {
                        Image(systemName: "chevron.left")
                            .fontWeight(.light)
                            .foregroundStyle(resolvedFeedColor.opacity(isAtFirstEntry ? 0.35 : 1.0))
                    }
                        .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
                        .accessibilityLabel("Vorheriger Artikel")
                        .disabled(isAtFirstEntry)
                    Button(action: { goToNext() }) {
                        Image(systemName: "chevron.right")
                            .fontWeight(.light)
                            .foregroundStyle(resolvedFeedColor.opacity(isAtLastEntry ? 0.35 : 1.0))
                    }
                        .minimumHitTarget(FeedDetailLayout.compactToolbarHitTarget)
                        .accessibilityLabel("Nächster Artikel")
                        .disabled(isAtLastEntry)
                }
                .padding(.horizontal, FeedDetailLayout.compactToolbarHorizontalPadding)
            } else {
                Button {
                    AppHaptics.selection()
                    isLeftBarExpanded = true
                    isRightBarExpanded = true
                    bothExpanded = true
                } label: {
                    Image(systemName: "chevron.left.chevron.right")
                        .fontWeight(.light)
                        .foregroundStyle(resolvedFeedColor)
                }
                .minimumHitTarget()
                .accessibilityLabel("Navigation einblenden")
            }
        }
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
        let htmlDocument = formattedHTML(accentHex: webAccentHexString())

        ZStack(alignment: .top) {
            WebView(webView: webView,
                    articleLink: entry.link,
                    articleURL: URL(string: entry.link),
                    htmlContent: htmlDocument,
                    topInset: effectiveHeaderHeight,
                    collapseProgress: $collapseProgress,
                    readingProgress: $readingProgress)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .edgesIgnoringSafeArea(.bottom)

            headerView
                .background(
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [headerTint.opacity(headerOverlayPrimaryOpacity), headerTint.opacity(headerOverlaySecondaryOpacity)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                )
                .opacity(max(0, 1 - collapseProgress))
                .offset(y: -FeedDetailLayout.headerCollapseOffset * collapseProgress)

            
            GeometryReader { proxy in
                let fullWidth = proxy.size.width
                let barHeight: CGFloat = 2
                let collapsedHeaderBottom = 0.0
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: fullWidth, height: barHeight)
                    Rectangle()
                        .fill(resolvedFeedColor)
                        .frame(width: fullWidth * max(0, min(1, readingProgress)), height: barHeight)
                        .animation(.linear(duration: 0.15), value: readingProgress)
                }
                .padding(.horizontal, 0)
                .offset(y: collapsedHeaderBottom)
            }
            .allowsHitTesting(false)
        }
        .offset(x: contentOffset)
        .opacity(contentOpacity)
        .background(alignment: .top) {
            GeometryReader { proxy in
                headerBackgroundGradient
                    .frame(height: proxy.safeAreaInsets.top + effectiveHeaderHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(collapseProgress > 0.6 ? entry.displayTitle : "")
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {dynamicBottomToolbar}
        .onAppear {
            isReadLocal = store.isRead(articleID: entry.link)
            isBookmarked = isCurrentlyBookmarked()
            collapseProgress = 0
            readingProgress = 0
            isLeftBarExpanded = true
            isRightBarExpanded = true
            bothExpanded = true
            hasAppeared = true
        }
        .onChange(of: entry.link) { _, _ in
            guard hasAppeared else { return }
            isReadLocal = store.isRead(articleID: entry.link)
            isBookmarked = isCurrentlyBookmarked()
            collapseProgress = 0
            readingProgress = 0
            isLeftBarExpanded = true
            isRightBarExpanded = true
            bothExpanded = true
            animateEntryTransition()
        }
        .onPreferenceChange(FeedDetailHeaderHeightKey.self) { newValue in
            let clampedValue = max(FeedDetailLayout.expandedHeaderHeight, newValue)
            guard abs(clampedValue - headerHeight) > 0.5 else { return }
            headerHeight = clampedValue
        }
        .onChange(of: collapseProgress) { _, newProgress in
            let shouldExpand = newProgress <= 0.7
            guard bothExpanded != shouldExpand ||
                    isLeftBarExpanded != shouldExpand ||
                    isRightBarExpanded != shouldExpand else {
                return
            }
            // Removed animation for collapseProgress changes
            isLeftBarExpanded = shouldExpand
            isRightBarExpanded = shouldExpand
            bothExpanded = shouldExpand
        }
        .onChange(of: readerFontScale) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerFontScale)
        }
        .onChange(of: readerFontFamily) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerFontFamily)
        }
        .onChange(of: readerLineSpacing) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerLineSpacing)
        }
        .onChange(of: readerTextAlignmentRaw) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.readerTextAlignment)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share(let payload, _):
                ShareSheet(items: [payload])
                    .presentationDetents([UIStylePolicy.Sheet.mediumDetent])
            case .articleSummary:
                ArticleSummarySheet(
                    title: entry.displayTitle,
                    sourceText: articleSummarySourceText,
                    link: entry.link,
                    feedColor: resolvedFeedColor
                )
                .environmentObject(store)
            case .readerSettings:
                ReaderSettingsPanel(textAlignment: $readerTextAlignmentRaw,
                                    fontScale: $readerFontScale,
                                    fontFamily: $readerFontFamily,
                                    lineSpacing: $readerLineSpacing,
                                    feedColor: .constant(resolvedFeedColor))
                    .presentationDetents([UIStylePolicy.Sheet.mediumDetent])
            }
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
            <iframe\(cleanedAttributes) src="\(normalizedSource)" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share" allowfullscreen playsinline loading="lazy" referrerpolicy="strict-origin-when-cross-origin">
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
        guard let source = htmlAttribute("src", in: tag), !source.isEmpty else {
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
    
    private func formattedHTML(accentHex: String) -> String {
        let fontSize = 18 * readerFontScale
        let lineHeight = readerLineSpacing
        let fontFamilyCSS = (ReaderFontFamily(rawValue: readerFontFamily) ?? .rounded).cssValue
        let textAlignCSS = readerTextAlignmentRaw == "justified" ? "justify" : readerTextAlignmentRaw
        let rgb = resolvedFeedColor.rgbComponents ?? (0,0,0)
        let backgroundBase = colorScheme == .dark ? (0, 0, 0) : (255, 255, 255)
        let background: String = mixedRGBColor(base: backgroundBase, overlay: rgb, overlayOpacity: 0.1)
        let mediaGlow: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.16)"
        let mediaShadow: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.14)"
        let codeBackground: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.16)"
        let inlineCodeBackground: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.22)"
        let rawBodySource = (entry.contentRaw?.isEmpty == false) ? entry.contentRaw! : entry.content
        let rawBody = HTMLText.normalizeHTMLContent(rawBodySource)
        let bodyHTML = sanitizedReaderBody(from: rawBody)

        return """
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
              html { overflow-x: hidden; min-height: 100%; background: \(background); }
              :root { --reader-media-width: 90%; }
              * { box-sizing: border-box; }
              body { font-family: \(fontFamilyCSS); font-size: \(fontSize)px; min-height: 100%; padding: 16px; line-height: \(lineHeight); margin: 0; text-align: \(textAlignCSS); background: \(background); overflow-wrap: break-word; word-break: normal; }
              p, li, blockquote { overflow-wrap: anywhere; }
              p { margin: 0 0 0.78em; }
              p:last-child { margin-bottom: 0; }
              ul, ol {
                margin: 0.56em 0 0.9em;
                padding-inline-start: 1.18em;
              }
              li {
                margin: 0.22em 0;
                padding-inline-start: 0.08em;
              }
              li > p {
                margin: 0.18em 0;
              }
              li > p:first-child { margin-top: 0; }
              li > p:last-child { margin-bottom: 0; }
              li > ul, li > ol { margin: 0.32em 0 0.46em; }
              @media (prefers-color-scheme: dark) { body { color: #EAEAEA; } a { color: \(accentHex); } }
              @media (prefers-color-scheme: light) { body { color: #111111; } a { color: \(accentHex); } }
              img, video, iframe { display: block !important; max-width: var(--reader-media-width) !important; border-radius: 10px; margin: 16px auto !important; float: none !important; clear: both; background: transparent !important; box-shadow: 0 10px 24px \(mediaShadow), 0 0 0 1px rgba(255,255,255,0.08), 0 0 12px \(mediaGlow), 0 0 20px \(mediaGlow); }
              img, video { width: auto !important; height: auto !important; }
              iframe { width: var(--reader-media-width) !important; height: auto !important; aspect-ratio: 16/9; }
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
                    if (element.querySelector('img, video, iframe, audio, source, picture, canvas, svg')) { return; }
                    element.remove();
                  });
                }

                document.querySelectorAll('img').forEach(function (image) {
                  var width = parseFloat(image.getAttribute('width') || '0');
                  var height = parseFloat(image.getAttribute('height') || '0');
                  if (isNoisyURL(image.getAttribute('src')) || (width > 0 && width <= 2 && height > 0 && height <= 2)) {
                    image.remove();
                  }
                });

                document.querySelectorAll('iframe').forEach(function (frame) {
                  if (isNoisyURL(frame.getAttribute('src'))) {
                    frame.remove();
                  }
                });

                removeEmptyBlocks();

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
              });
            </script>
          </head>
          <body>\(bodyHTML)</body>
        </html>
        """
    }

    private var resolvedFeedColor: Color {
        feedColor ?? theme.uiAccentColor
    }

    private var headerTint: Color { resolvedFeedColor }

    private var headerOverlayPrimaryOpacity: Double {
        colorScheme == .dark ? 0.30 : 0.42
    }

    private var headerOverlaySecondaryOpacity: Double {
        colorScheme == .dark ? UIStylePolicy.glassAccentOpacity : 0.16
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
    
    private func isCurrentlyBookmarked() -> Bool {
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.link == entry.link && $0.isBookmarked })
        let results = try? modelContext.fetch(descriptor)
        return (results?.isEmpty == false)
    }
    
    private func toggleBookmark() {
        BookmarkService.toggleBookmark(for: entry, context: modelContext)
        isBookmarked = BookmarkService.isBookmarked(link: entry.link, context: modelContext)
        AppHaptics.selection()
        onToggleBookmark?(isBookmarked)
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    let articleLink: String
    let articleURL: URL?
    let htmlContent: String
    let topInset: CGFloat
    @Binding var collapseProgress: CGFloat
    @Binding var readingProgress: CGFloat
    private var youtubeEmbedBaseURL: URL? {
        let appIdentifier = Bundle.main.bundleIdentifier?.lowercased() ?? "notifeeder.app"
        return URL(string: "https://\(appIdentifier)")
    }

    func makeUIView(context: Context) -> WKWebView {
        webView.scrollView.delegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        loadContent(into: webView, coordinator: context.coordinator, forcePinToTop: true)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let expectedLocalFilePath = OfflineArticleArchive.articleHTMLFileURL(forArticleLink: articleLink)?.path
        if context.coordinator.lastLoadedHTML != htmlContent || context.coordinator.lastLoadedFilePath != expectedLocalFilePath {
            context.coordinator.resetScrollState()
            loadContent(into: uiView, coordinator: context.coordinator, forcePinToTop: true)
            return
        }

        applyTopInset(topInset, to: uiView.scrollView, forcePinToTop: false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(collapseProgress: $collapseProgress, readingProgress: $readingProgress)
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
        coordinator.lastLoadedHTML = htmlContent

        if let localFileURL = OfflineArticleArchive.prepareOfflineHTMLDocument(
            forArticleLink: articleLink,
            articleURL: articleURL,
            htmlDocument: htmlContent
        ), let readAccessURL = OfflineArticleArchive.readAccessURL() {
            coordinator.lastLoadedFilePath = localFileURL.path
            webView.loadFileURL(localFileURL, allowingReadAccessTo: readAccessURL)
        } else {
            coordinator.lastLoadedFilePath = nil
            webView.loadHTMLString(htmlContent, baseURL: youtubeEmbedBaseURL)
        }

        applyTopInset(topInset, to: webView.scrollView, forcePinToTop: forcePinToTop)
    }

    class Coordinator: NSObject, UIScrollViewDelegate, WKNavigationDelegate {
        @Binding var collapseProgress: CGFloat
        @Binding var readingProgress: CGFloat
        private let collapseRange: CGFloat = 120 // pixels over which header collapses
        private let progressUpdateThreshold: CGFloat = 0.005
        var lastLoadedHTML: String = ""
        var lastLoadedFilePath: String?

        init(collapseProgress: Binding<CGFloat>, readingProgress: Binding<CGFloat>) {
            _collapseProgress = collapseProgress
            _readingProgress = readingProgress
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let currentOffset = scrollView.contentOffset.y
            let topInset = scrollView.adjustedContentInset.top
            let bottomInset = scrollView.adjustedContentInset.bottom
            let minOffsetY = -topInset
            let maxOffsetY = max(minOffsetY, scrollView.contentSize.height - scrollView.bounds.height + bottomInset)

            let clampedOffsetY = min(max(currentOffset, minOffsetY), maxOffsetY)
            let scrollDistanceFromTop = max(0, clampedOffsetY - minOffsetY)
            let shouldUpdateChrome = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            let progress = min(1, scrollDistanceFromTop / collapseRange)

            // Header chrome should follow user-driven scroll, while reading progress
            // also needs to track WebKit layout and programmatic offset updates.
            if shouldUpdateChrome && abs(progress - collapseProgress) > progressUpdateThreshold {
                updateCollapseProgress(progress)
            }

            let scrollableDistance = max(0, maxOffsetY - minOffsetY)
            let clamped = scrollableDistance > 0
                ? max(0, min(1, (clampedOffsetY - minOffsetY) / scrollableDistance))
                : 1
            if abs(clamped - readingProgress) > progressUpdateThreshold {
                updateReadingProgress(clamped)
            }
        }

        func resetScrollState() {
            updateCollapseProgress(0)
            updateReadingProgress(0)
        }
       
        private func updateCollapseProgress(_ newValue: CGFloat) {
            if collapseProgress != newValue {
                collapseProgress = newValue
            }
        }
        private func updateReadingProgress(_ newValue: CGFloat) {
            if readingProgress != newValue {
                readingProgress = newValue
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

private struct ArticleSummarySheet: View {
    private static let summaryCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        return cache
    }()

    private static let summaryInstructions = """
    Du erstellst praezise, gut lesbare Artikelzusammenfassungen fuer ein mobiles Sheet in einer RSS-App.
    Antworte immer auf Deutsch.
    Gib nur separate Stichpunkte zurueck, pro Zeile genau einen Punkt.
    Keine Ueberschrift, keine Einleitung, keine Nummerierung, kein Fazit und kein Markdown.
    Formuliere konkret, natuerlich und ohne Fuellsaetze.
    Nenne nur Informationen, die im Text klar belegt sind.
    """

    private struct SummaryLayoutProfile {
        let sourceWordCount: Int
        let targetWordCount: Int
        let bulletCount: Int
        let minWordsPerBullet: Int
        let maxWordsPerBullet: Int
        let maxCharactersPerBullet: Int
        let detentFraction: CGFloat
        let coveragePercent: Int
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
    @EnvironmentObject private var store: ArticleStore
    @State private var model = SystemLanguageModel.default
    @State private var summaryState: SummaryState = .loading

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
        Self.sourceSignature(for: preparedSourceText)
    }

    private var summaryDetent: PresentationDetent {
        .fraction(summaryLayout.detentFraction)
    }

    private var summaryCoverageLabel: String {
        "Ca. \(summaryLayout.coveragePercent)% des Artikels"
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        feedColor.opacity(0.15),
                        feedColor.opacity(0.06),
                        Color(.systemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(alignment: .leading, spacing: UIStylePolicy.Spacing.large) {
                    summaryContent
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, UIStylePolicy.Spacing.large)
                .padding(.top, UIStylePolicy.Spacing.large)
                .padding(.bottom, UIStylePolicy.Spacing.medium)
            }
            .navigationTitle(title)
            .navigationSubtitle("Zusammenfassung mit Apple Intelligence")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([summaryDetent])
            .presentationDragIndicator(.visible)
            .task(id: generationTaskID) {
                await generateSummaryIfNeeded()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let sharePayload {
                        ShareLink(item: sharePayload) {
                            Image(systemName: "square.and.arrow.up")
                                .fontWeight(.light)
                                .foregroundStyle(feedColor)
                        }
                        .accessibilityLabel("Zusammenfassung teilen")
                    } else {
                        Button(action: {}) {
                            Image(systemName: "square.and.arrow.up")
                                .fontWeight(.light)
                                .foregroundStyle(UIStylePolicy.neutralIcon)
                        }
                        .disabled(true)
                        .accessibilityLabel("Zusammenfassung teilen")
                    }
                }
            }
        }
    }

    private var generationTaskID: String {
        "\(link)|\(sourceSignature)"
    }

    @ViewBuilder
    private var summaryContent: some View {
        switch summaryState {
        case .loading:
            summaryCard {
                Label("Apple Intelligence erstellt die Zusammenfassung lokal.", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                ProgressView()
                    .tint(feedColor)
                Text("Erstelle längere Zusammenfassung …")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Die Ausgabe wird lokal auf dem Gerät generiert.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .ready(let bullets):
            VStack(alignment: .leading, spacing: UIStylePolicy.Spacing.medium) {
                summaryCard {
                    HStack(alignment: .center, spacing: UIStylePolicy.Spacing.small) {
                        Label("Lokal gespeichert", systemImage: "checkmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(summaryCoverageLabel)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(feedColor)
                    }

                    ForEach(Array(bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: UIStylePolicy.Spacing.medium) {
                            Circle()
                                .fill(feedColor)
                                .frame(width: 8, height: 8)
                                .padding(.top, 8)
                            Text(bullet)
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                                .foregroundStyle(.primary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)
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
                    .lineLimit(7)
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
            if !bullets.isEmpty {
                summaryState = .ready(bullets)
                return
            }
        }

        if let persistedSummary = store.summary(articleID: link, matching: sourceSignature) {
            let bullets = Self.normalizedBullets(from: persistedSummary, layout: summaryLayout)
            if !bullets.isEmpty {
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
            let response = try await session.respond(
                to: Self.summaryPrompt(title: title, sourceText: preparedSource, layout: summaryLayout),
                options: GenerationOptions(
                    temperature: 0.2,
                    maximumResponseTokens: 160
                )
            )

            guard !Task.isCancelled else { return }

            let bullets = Self.normalizedBullets(from: response.content, layout: summaryLayout)
            guard !bullets.isEmpty else {
                summaryState = .failed("Die Zusammenfassung konnte nicht in ein kompaktes Format gebracht werden.")
                return
            }

            let persistedSummary = bullets.joined(separator: "\n")
            Self.summaryCache.setObject(persistedSummary as NSString, forKey: cacheKey)
            store.saveSummary(persistedSummary, articleID: link, sourceSignature: sourceSignature)
            summaryState = .ready(bullets)
        } catch let error as LanguageModelSession.GenerationError {
            guard !Task.isCancelled else { return }
            summaryState = .failed(Self.message(for: error))
        } catch {
            guard !Task.isCancelled else { return }
            summaryState = .failed("Die Zusammenfassung konnte gerade nicht erstellt werden.")
        }
    }

    private nonisolated static func cacheKey(link: String, sourceSignature: String) -> NSString {
        "\(link)|\(sourceSignature)" as NSString
    }

    private nonisolated static func preparedSourceText(from sourceText: String) -> String {
        let normalized = HTMLText.normalizePreviewSpacing(in: sourceText)
        return String(normalized.prefix(12_000))
    }

    private nonisolated static func sourceSignature(for sourceText: String) -> String {
        let digest = SHA256.hash(data: Data(("summary-v2|" + sourceText).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func summaryLayoutProfile(for sourceText: String) -> SummaryLayoutProfile {
        let wordCount = max(1, sourceText.split(whereSeparator: \.isWhitespace).count)
        let proportionalWordCount = Int((Double(wordCount) * 0.14).rounded())
        let targetWordCount = min(76, max(48, proportionalWordCount))
        let bulletCount = targetWordCount >= 64 ? 4 : 3
        let averageWordsPerBullet = Int(ceil(Double(targetWordCount) / Double(bulletCount)))
        let coveragePercent = min(35, max(8, Int((Double(targetWordCount) / Double(wordCount) * 100).rounded())))

        return SummaryLayoutProfile(
            sourceWordCount: wordCount,
            targetWordCount: targetWordCount,
            bulletCount: bulletCount,
            minWordsPerBullet: max(12, averageWordsPerBullet - 2),
            maxWordsPerBullet: min(20, averageWordsPerBullet + 2),
            maxCharactersPerBullet: bulletCount == 4 ? 150 : 170,
            detentFraction: bulletCount == 4 ? 0.58 : 0.54,
            coveragePercent: coveragePercent
        )
    }

    private nonisolated static func summaryPrompt(title: String, sourceText: String, layout: SummaryLayoutProfile) -> String {
        """
        Erstelle eine gut lesbare, mobile Artikelzusammenfassung.
        Gib exakt \(layout.bulletCount) Zeilen aus.
        Zielumfang: insgesamt ungefaehr \(layout.targetWordCount) Woerter, also etwa \(layout.coveragePercent)% des Artikels.
        Jede Zeile soll ungefaehr \(layout.minWordsPerBullet)-\(layout.maxWordsPerBullet) Woerter haben.
        Verteile die wichtigsten Informationen ueber alle Zeilen. Keine Zeile darf leer sein.

        Titel: \(title)

        Artikeltext:
        \(sourceText)
        """
    }

    private nonisolated static func normalizedBullets(from response: String, layout: SummaryLayoutProfile) -> [String] {
        let normalizedResponse = HTMLText.normalizePreviewSpacing(
            in: response.replacingOccurrences(of: "\r\n", with: "\n")
        )

        let lineBullets = normalizedResponse
            .components(separatedBy: .newlines)
            .map { Self.cleanBulletLine($0, maxCharacters: layout.maxCharactersPerBullet) }
            .filter { !$0.isEmpty }

        if lineBullets.count >= 2 {
            return Array(lineBullets.prefix(layout.bulletCount))
        }

        let sentenceBullets = normalizedResponse
            .replacingOccurrences(of: "(?<=[.!?])\\s+", with: "\n", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { Self.cleanBulletLine($0, maxCharacters: layout.maxCharactersPerBullet) }
            .filter { !$0.isEmpty }

        return Array(sentenceBullets.prefix(layout.bulletCount))
    }

    private nonisolated static func cleanBulletLine(_ rawLine: String, maxCharacters: Int) -> String {
        let withoutMarkers = rawLine.replacingOccurrences(
            of: #"^\s*(?:[-•*]|\d+[.)]|Zusammenfassung:|Summary:)\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let normalized = HTMLText.normalizePreviewSpacing(in: withoutMarkers)
        guard !normalized.isEmpty else { return "" }
        guard normalized.count > maxCharacters else { return normalized }

        let trimmedPrefix = String(normalized.prefix(max(1, maxCharacters - 3)))
        if let lastSpace = trimmedPrefix.lastIndex(of: " ") {
            return String(trimmedPrefix[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return trimmedPrefix + "…"
    }

    private func summaryCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: UIStylePolicy.Spacing.medium) {
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    feedColor.opacity(0.34),
                                    Color.white.opacity(0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
                .shadow(color: feedColor.opacity(0.14), radius: 20, y: 10)
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
