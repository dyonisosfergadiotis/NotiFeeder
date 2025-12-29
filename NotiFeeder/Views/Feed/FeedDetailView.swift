import WebKit
import SwiftUI
import QuartzCore
import Foundation
import SwiftData

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

struct FeedDetailView: View {
    var entry: FeedEntry
    var feedColor: Color?
    var entriesProvider: () -> [FeedEntry] = { [] }
    var onNavigateToEntry: (FeedEntry, NavigationDirection) -> Void = { _, _ in }

    enum NavigationDirection {
        case previous
        case next
    }

    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var store: ArticleStore
    @Environment(\.modelContext) private var modelContext
    
    // --- UNIFIED COLLAPSE BEHAVIOR FOR TOOLBARS (scroll drives collapse; taps expand sides) ---
    @State private var isScrollingDown = false
    @State private var isLeftBarExpanded = true
    @State private var isRightBarExpanded = true
    @State private var bothExpanded = true

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

    init(entry: FeedEntry, feedColor: Color? = nil) {
        self.entry = entry
        self.feedColor = feedColor
    }

    init(entry: FeedEntry,
         feedColor: Color? = nil,
         entriesProvider: @escaping () -> [FeedEntry],
         onNavigateToEntry: @escaping (FeedEntry, NavigationDirection) -> Void) {
        self.entry = entry
        self.feedColor = feedColor
        self.entriesProvider = entriesProvider
        self.onNavigateToEntry = onNavigateToEntry
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
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.smooth(duration: 0.22)) { onNavigateToEntry(target, .previous) }
    }

    private func goToNext() {
        let list = entriesProvider()
        guard !list.isEmpty, let currentIndex = currentIndex(in: list) else { return }
        let nextIndex = list.index(after: currentIndex)
        guard nextIndex < list.endIndex else { return }
        let target = list[nextIndex]
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.smooth(duration: 0.22)) { onNavigateToEntry(target, .next) }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("von \(entry.author ?? "Unbekannt")")
                Text("·")
                Text(entry.sourceTitle ?? "Unbekannte Quelle")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            if let dateString = entry.pubDateString {
                let parsed = DateParser.parse(dateString)
                Text(parsed != Date.distantPast ? DateFormatter.localized.string(from: parsed) : dateString)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .background(
            LinearGradient(
                colors: [headerTint.opacity(0.3), resolvedFeedColor.opacity(0.1)],
                startPoint: .top,
                endPoint: .bottom)
        )
    }
    
    @ToolbarContentBuilder
    private var dynamicBottomToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            // Left cluster
            if bothExpanded || isLeftBarExpanded {
                HStack(spacing: 18) {
                    Button(action: { activeSheet = .readerSettings }) { Image(systemName: "textformat.size") }
                    Button(action: { if let url = URL(string: entry.link) { UIApplication.shared.open(url) } }) { Image(systemName: "safari") }
                    VStack{Button(action: { gatherShareContent() }) { Image(systemName: "square.and.arrow.up") }}.padding(.bottom,4)
                    Button(action: {
                        isReadLocal.toggle()
                        store.setRead(isReadLocal, articleID: entry.link)
                    }) {
                        Image(systemName: isReadLocal ? "eye.slash" : "eye")
                    }
                }.padding(.horizontal, 8)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isLeftBarExpanded = true
                        bothExpanded = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }

            Spacer(minLength: 8)

            // Right cluster
            if bothExpanded || isRightBarExpanded {
                HStack(spacing: 18) {
                    Button(action: { goToPrevious() }) { Image(systemName: "chevron.left") }
                        .disabled(isAtFirstEntry)
                    Button(action: { goToNext() }) { Image(systemName: "chevron.right") }
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
                }
            }
        }
    }
    
    private func webAccentHexString() -> String {
        guard let components = resolvedFeedColor.rgbComponents else {
            return "#007AFF"
        }
        return String(format: "#%02X%02X%02X", components.red, components.green, components.blue)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            WebView(webView: webView,
                    htmlContent: formattedHTML(accentHex: webAccentHexString()),
                    isScrollingDown: $isScrollingDown)
                .frame(maxHeight: .infinity)
                .edgesIgnoringSafeArea(.bottom)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: { toggleBookmark() }) {
                    ZStack {
                        Image(systemName: "bookmark").font(.system(size: 18, weight: .regular))
                        Image(systemName: "bookmark.fill").font(.system(size: 18, weight: .regular))
                            .mask(Rectangle().scaleEffect(y: isBookmarked ? 1 : 0, anchor: .top))
                    }
                }
                .tint(feedColor)
            }
        }
        .toolbar {
            dynamicBottomToolbar
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(entry.title)
        .tint(feedColor)
        .onAppear {
            store.markRecentlyRead(articleID: entry.link)
            isReadLocal = store.isRead(articleID: entry.link)
            isBookmarked = isCurrentlyBookmarked()
            bothExpanded = true
        }
        .onChange(of: isScrollingDown) { _, scrollingDown in
            withAnimation(.snappy(duration: 0.25)) {
                if scrollingDown {
                    isLeftBarExpanded = false
                    isRightBarExpanded = false
                    bothExpanded = false
                } else {
                    isLeftBarExpanded = true
                    isRightBarExpanded = true
                    bothExpanded = true
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share(let payload, _):
                ShareSheet(items: [payload])
                    .presentationDetents([.fraction(0.5)])
            case .readerSettings:
                ReaderSettingsPanel(textAlignment: $readerTextAlignmentRaw,
                                    fontScale: $readerFontScale,
                                    fontFamily: $readerFontFamily,
                                    lineSpacing: $readerLineSpacing,
                                    feedColor: .constant(resolvedFeedColor))
                    .presentationDetents([.fraction(0.5)])
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

        return """
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
              body { font-family: \(fontFamilyCSS); font-size: \(fontSize)px; padding: 16px; line-height: \(lineHeight); margin: 0; text-align: \(textAlignCSS); background-color: \(background); }
              @media (prefers-color-scheme: dark) { body { color: #EAEAEA; } a { color: \(accentHex); } html { background-color: #000000; } }
              @media (prefers-color-scheme: light) { body { color: #111111; } a { color: \(accentHex); } html { background-color: #ffffff; } }
              img, iframe { display: block; max-width: 90%; height: auto; border-radius: 10px; margin: 16px auto; }
              iframe { aspect-ratio: 16/9; }
            </style>
          </head>
          <body>\(fixYouTubeIframes(in: entry.content))</body>
        </html>
        """
    }

    private var resolvedFeedColor: Color {
        feedColor ?? theme.uiAccentColor
    }

    private var headerTint: Color { resolvedFeedColor }
    
    private var accentColor: Color { theme.uiAccentColor }
    
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
    @Binding var isScrollingDown: Bool

    func makeUIView(context: Context) -> WKWebView {
        webView.scrollView.delegate = context.coordinator
        webView.loadHTMLString(htmlContent, baseURL: nil)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedHTML != htmlContent {
            context.coordinator.lastLoadedHTML = htmlContent
            uiView.loadHTMLString(htmlContent, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isScrollingDown: $isScrollingDown)
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding var isScrollingDown: Bool
        private var lastOffset: CGFloat = 0
        private var lastDirectionDown: Bool = false
        private var lastUpdateTime: TimeInterval = 0
        private let minDelta: CGFloat = 12
        private let minInterval: TimeInterval = 0.08
        var lastLoadedHTML: String = ""

        init(isScrollingDown: Binding<Bool>) {
            _isScrollingDown = isScrollingDown
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let currentOffset = scrollView.contentOffset.y
            let now = CACurrentMediaTime()

            // Only react to real user scrolling
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }

            // Near top: always expand
            if currentOffset <= 5 {
                updateScrollState(false)
                lastOffset = currentOffset
                lastDirectionDown = false
                lastUpdateTime = now
                return
            }

            let delta = currentOffset - lastOffset
            let isDown = delta > 0

            // Hysteresis: ignore tiny moves and too frequent updates
            guard abs(delta) >= minDelta || (isDown != lastDirectionDown) else { return }
            guard now - lastUpdateTime >= minInterval else { return }

            if isDown {
                // collapse on downward movement
                if !isScrollingDown { updateScrollState(true) }
            } else {
                // expand on upward movement
                if isScrollingDown { updateScrollState(false) }
            }

            lastOffset = currentOffset
            lastDirectionDown = isDown
            lastUpdateTime = now
        }
       
        private func updateScrollState(_ newValue: Bool) {
            DispatchQueue.main.async {
                if self.isScrollingDown != newValue {
                    self.isScrollingDown = newValue
                }
            }
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

