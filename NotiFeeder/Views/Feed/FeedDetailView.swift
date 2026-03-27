import WebKit
import SwiftUI
import Foundation
import SwiftData
import UIKit

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

    enum NavigationDirection {
        case previous
        case next
    }

    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var store: ArticleStore
    @Environment(\.modelContext) private var modelContext
    
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
        config.mediaTypesRequiringUserActionForPlayback = []
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
        case readerSettings
        var id: UUID {
            switch self {
            case .share(_, let token): return token
            case .readerSettings: return ActiveSheet.readerSettingsID
            }
        }
        private static let readerSettingsID = UUID()
    }

    init(entry: FeedEntry, feedColor: Color? = nil, onToggleRead: ((Bool) -> Void)? = nil) {
        self.entry = entry
        self.feedColor = feedColor
        self.onToggleRead = onToggleRead
    }

    init(entry: FeedEntry,
         feedColor: Color? = nil,
         entriesProvider: @escaping () -> [FeedEntry],
         onNavigateToEntry: @escaping (FeedEntry, NavigationDirection) -> Void,
         onToggleRead: ((Bool) -> Void)? = nil) {
        self.entry = entry
        self.feedColor = feedColor
        self.entriesProvider = entriesProvider
        self.onNavigateToEntry = onNavigateToEntry
        self.onToggleRead = onToggleRead
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
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.smooth(duration: 0.22)) { onNavigateToEntry(target, .previous) }
    }

    private func goToNext() {
        let list = entriesProvider()
        guard !list.isEmpty, let currentIndex = currentIndex(in: list) else { return }
        let nextIndex = list.index(after: currentIndex)
        guard nextIndex < list.endIndex else { return }
        let target = list[nextIndex]
        pendingNavigationDirection = .next
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
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

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
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
                    Image(systemName: "bookmark").font(.system(size: 18, weight: .regular))
                    Image(systemName: "bookmark.fill").font(.system(size: 18, weight: .regular))
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
                HStack(spacing: 18) {
                    Button(action: { activeSheet = .readerSettings }) {
                        Image(systemName: "textformat.size")
                            .foregroundStyle(resolvedFeedColor)
                    }
                    .minimumHitTarget()
                    .accessibilityLabel("Lesedarstellung")
                    .accessibilityHint("Öffnet Einstellungen für Schrift und Layout")
                    Button(action: { if let url = URL(string: entry.link) { UIApplication.shared.open(url) } }) {
                        Image(systemName: "safari")
                            .foregroundStyle(resolvedFeedColor)
                    }
                    .minimumHitTarget()
                    .accessibilityLabel("In Safari öffnen")
                    VStack {
                        Button(action: { gatherShareContent() }) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(resolvedFeedColor)
                        }
                    }.padding(.bottom,4)
                    .minimumHitTarget()
                    .accessibilityLabel("Teilen")
                    Button(action: { onToggleReadAction() }) {
                        Image(systemName: isReadLocal ? "eye.slash" : "eye")
                            .foregroundStyle(isReadLocal ? resolvedFeedColor : UIStylePolicy.neutralIcon)
                    }
                    .minimumHitTarget()
                    .accessibilityLabel(isReadLocal ? "Als ungelesen markieren" : "Als gelesen markieren")
                }.padding(.horizontal, 8)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isLeftBarExpanded = true
                        bothExpanded = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(resolvedFeedColor)
                }
                .minimumHitTarget()
                .accessibilityLabel("Aktionen einblenden")
            }

            Spacer(minLength: 8)

            // Right cluster
            if bothExpanded || isRightBarExpanded {
                HStack(spacing: 18) {
                    Button(action: { goToPrevious() }) {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(resolvedFeedColor.opacity(isAtFirstEntry ? 0.35 : 1.0))
                    }
                        .minimumHitTarget()
                        .accessibilityLabel("Vorheriger Artikel")
                        .disabled(isAtFirstEntry)
                    Button(action: { goToNext() }) {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(resolvedFeedColor.opacity(isAtLastEntry ? 0.35 : 1.0))
                    }
                        .minimumHitTarget()
                        .accessibilityLabel("Nächster Artikel")
                        .disabled(isAtLastEntry)
                }.padding(.horizontal, 8)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isLeftBarExpanded = true
                        isRightBarExpanded = true
                        bothExpanded = true
                    }
                } label: {
                    Image(systemName: "chevron.left.chevron.right")
                        .foregroundStyle(resolvedFeedColor)
                }
                .minimumHitTarget()
                .accessibilityLabel("Navigation einblenden")
            }
        }
    }
    
    private func onToggleReadAction() {
        isReadLocal.toggle()
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
        ZStack(alignment: .top) {
            WebView(webView: webView,
                    htmlContent: formattedHTML(accentHex: webAccentHexString()),
                    topInset: effectiveHeaderHeight,
                    collapseProgress: $collapseProgress,
                    readingProgress: $readingProgress)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .edgesIgnoringSafeArea(.bottom)

            headerView
                .background(
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [headerTint.opacity(0.30),headerTint.opacity(UIStylePolicy.glassAccentOpacity)],
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
                let collapsedBarVisibility = max(0, min(1, (collapseProgress - 0.72) / 0.2))
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: fullWidth, height: barHeight)
                    Rectangle()
                        .fill(resolvedFeedColor)
                        .frame(width: fullWidth * max(0, min(1, readingProgress)), height: barHeight)
                }
                .padding(.horizontal, 0)
                .offset(y: collapsedHeaderBottom)
                .opacity(collapsedBarVisibility)
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
        .navigationTitle(collapseProgress > 0.6 ? entry.title : "")
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {dynamicBottomToolbar}
        .onAppear {
            store.markRecentlyRead(articleID: entry.link)
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
            withAnimation(UIStylePolicy.Motion.detailScrollSpring) {
                isLeftBarExpanded = shouldExpand
                isRightBarExpanded = shouldExpand
                bothExpanded = shouldExpand
            }
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
        let pattern = "<iframe([^>]*)src=\"([^\\\"]*youtube[^\\\"]*)\"([^>]*)>"
        return html.replacingOccurrences(of: pattern,
                                         with: "<iframe$1src=\\\"$2\\\"$3 allow=\\\"fullscreen\\\" playsinline></iframe>",
                                         options: .regularExpression)
    }
    
    private func formattedHTML(accentHex: String) -> String {
        let fontSize = 18 * readerFontScale
        let lineHeight = readerLineSpacing
        let fontFamilyCSS = (ReaderFontFamily(rawValue: readerFontFamily) ?? .rounded).cssValue
        let textAlignCSS = readerTextAlignmentRaw == "justified" ? "justify" : readerTextAlignmentRaw
        let rgb = resolvedFeedColor.rgbComponents ?? (0,0,0)
        let background: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.1)"
        let mediaGlow: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.22)"
        let mediaShadow: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.12)"
        let codeBackground: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.16)"
        let inlineCodeBackground: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.22)"
        let rawBody = (entry.contentRaw?.isEmpty == false) ? entry.contentRaw! : entry.content

        return """
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
              html { overflow-x: hidden; }
              * { box-sizing: border-box; }
              body { font-family: \(fontFamilyCSS); font-size: \(fontSize)px; padding: 16px; line-height: \(lineHeight); margin: 0; text-align: \(textAlignCSS); background-color: \(background); overflow-wrap: break-word; word-break: normal; }
              p, li, blockquote { overflow-wrap: anywhere; }
              @media (prefers-color-scheme: dark) { body { color: #EAEAEA; } a { color: \(accentHex); } html { background-color: #000000; } }
              @media (prefers-color-scheme: light) { body { color: #111111; } a { color: \(accentHex); } html { background-color: #ffffff; } }
              img, video, iframe { display: block; max-width: 90%; height: auto; border-radius: 10px; margin: 16px auto; box-shadow: 0 10px 28px \(mediaShadow), 0 0 0 1px rgba(255,255,255,0.08), 0 0 22px \(mediaGlow); }
              iframe { aspect-ratio: 16/9; }
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
          </head>
          <body>\(fixYouTubeIframes(in: rawBody))</body>
        </html>
        """
    }

    private var resolvedFeedColor: Color {
        feedColor ?? theme.uiAccentColor
    }

    private var headerTint: Color { resolvedFeedColor }

    private var headerBackgroundGradient: LinearGradient { //ganz oben dad ding
        LinearGradient(
            colors: [headerTint.opacity(0.5), headerTint.opacity(0.25)],
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
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    let htmlContent: String
    let topInset: CGFloat
    @Binding var collapseProgress: CGFloat
    @Binding var readingProgress: CGFloat

    func makeUIView(context: Context) -> WKWebView {
        webView.scrollView.delegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        context.coordinator.lastLoadedHTML = htmlContent
        webView.loadHTMLString(htmlContent, baseURL: nil)
        applyTopInset(topInset, to: webView.scrollView, forcePinToTop: true)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedHTML != htmlContent {
            context.coordinator.lastLoadedHTML = htmlContent
            context.coordinator.resetScrollState()
            uiView.loadHTMLString(htmlContent, baseURL: nil)
            applyTopInset(topInset, to: uiView.scrollView, forcePinToTop: true)
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

    class Coordinator: NSObject, UIScrollViewDelegate, WKNavigationDelegate {
        @Binding var collapseProgress: CGFloat
        @Binding var readingProgress: CGFloat
        private let collapseRange: CGFloat = 120 // pixels over which header collapses
        private let progressUpdateThreshold: CGFloat = 0.005
        var lastLoadedHTML: String = ""

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

            // Only react to real user scrolling
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }

            let clampedOffsetY = min(max(currentOffset, minOffsetY), maxOffsetY)
            let scrollDistanceFromTop = max(0, clampedOffsetY - minOffsetY)
            let progress = min(1, scrollDistanceFromTop / collapseRange)

            // Update binding only if significant change
            if abs(progress - collapseProgress) > progressUpdateThreshold {
                updateCollapseProgress(progress)
            }

            let contentHeight = scrollView.contentSize.height
            let visibleHeight = scrollView.bounds.height - scrollView.adjustedContentInset.top - scrollView.adjustedContentInset.bottom
            let totalScrollable = max(1, contentHeight - visibleHeight)
            let progressRaw = (clampedOffsetY - minOffsetY) / totalScrollable
            let clamped = max(0, min(1, progressRaw))
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
