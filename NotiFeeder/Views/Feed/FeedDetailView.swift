import WebKit
import SwiftUI
import FoundationModels
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
    
    // --- SCROLL STATE ---
    @State private var isScrollingDown = false

    @State private var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.scrollView.showsHorizontalScrollIndicator = false
        return wv
    }()
    
    @State private var shareText: String = ""
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
        if let idx = list.firstIndex(where: { $0.link == entry.link }) { return idx }
        return nil
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
                colors: [headerTint.opacity(0.3), (feedColor ?? .primary).opacity(0.1)],
                startPoint: .top,
                endPoint: .bottom)
        )
    }

    @ToolbarContentBuilder
    private var expandedToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button(action: { if let url = URL(string: entry.link) { UIApplication.shared.open(url) } }) {
                Image(systemName: "safari")
            }
            Button(action: { gatherShareContent() }) {
                Image(systemName: "square.and.arrow.up")
            }
            Button(action: {
                isReadLocal.toggle()
                store.setRead(isReadLocal, articleID: entry.link)
            }) {
                Image(systemName: isReadLocal ? "checkmark.circle.fill" : "checkmark.circle")
            }
            Button(action: { activeSheet = .readerSettings }) {
                Image(systemName: "textformat.size")
            }
        }
        ToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            Button(action: { goToPrevious() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(isAtFirstEntry)

            Button(action: { goToNext() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(isAtLastEntry)
        }
    }

    @ToolbarContentBuilder
    private var collapsedToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button{
            }label:{
                Image(systemName: "ellipsis")
                    .tint(feedColor)
            }
            Button(action: {
                isReadLocal.toggle()
                store.setRead(isReadLocal, articleID: entry.link)
            }) {
                Image(systemName: isReadLocal ? "checkmark.circle.fill" : "checkmark.circle")
            }
            
            
            
        Spacer()
            
            
            Button{
                
            }label:{
                Image(systemName: "chevron.compact.left.chevron.compact.right")
            }.tint(feedColor)
        }
    }

    private var readerSettings: [AnyHashable] { [readerFontScale, readerFontFamily, readerLineSpacing, readerTextAlignmentRaw] }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            WebView(webView: webView,
                    htmlContent: formattedHTML(accentHex: theme.uiAccentHexString),
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
                .tint(feedColor ?? theme.uiAccentColor)
            }

            if isScrollingDown {
                collapsedToolbar
            } else {
                expandedToolbar
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(false)
        .tint(feedColor ?? theme.uiAccentColor)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(entry.title)
        .onAppear {
            store.markRecentlyRead(articleID: entry.link)
            isReadLocal = store.isRead(articleID: entry.link)
            isBookmarked = isCurrentlyBookmarked()
        }
        .animation(.snappy(duration: 0.3), value: isScrollingDown)
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
                                    feedColor: .constant(feedColor ?? theme.uiAccentColor))
                    .presentationDetents([.fraction(0.5)])
            }
        }
    }

    private func fixYouTubeIframes(in html: String) -> String {
        let pattern = "<iframe([^>]*)src=\"([^\"]*youtube[^\"]*)\"([^>]*)>"
        return html.replacingOccurrences(of: pattern, with: "<iframe$1src=\"$2\"$3 allow=\"fullscreen\" playsinline></iframe>", options: .regularExpression)
    }

    private func formattedHTML(accentHex: String) -> String {
        let fontSize = 18 * readerFontScale
        let lineHeight = readerLineSpacing
        let fontFamilyCSS = (ReaderFontFamily(rawValue: readerFontFamily) ?? .rounded).cssValue
        let textAlignCSS = readerTextAlignmentRaw == "justified" ? "justify" : readerTextAlignmentRaw
        let rgb = (feedColor ?? theme.uiAccentColor).rgbComponents ?? (0,0,0)
        let background: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.1)"
        let accentHex = (feedColor ?? theme.uiAccentColor).toHex() ?? "007AFF"

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

    private var headerTint: Color { feedColor ?? theme.uiAccentColor }
    
    private func gatherShareContent() {
        webView.evaluateJavaScript("window.getSelection().toString();") { result, _ in
            let snippet = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let composed = [entry.title, snippet, entry.link].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            shareText = composed
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

// --- WEBVIEW BRIDGE MIT FIX GEGEN SPRINGEN ---

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
        // NUR neu laden, wenn sich der Content (Reader Settings) wirklich geändert hat.
        // Verhindert das Springen zum Anfang beim Toolbar-Toggle.
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
        var lastLoadedHTML: String = ""

        init(isScrollingDown: Binding<Bool>) {
            _isScrollingDown = isScrollingDown
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let currentOffset = scrollView.contentOffset.y
            let threshold: CGFloat = 10
            
            // Reagiere nur auf echtes User-Scrollen
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }

            if currentOffset <= 5 {
                updateScrollState(false)
                return
            }

            if currentOffset > lastOffset + threshold && !isScrollingDown {
                updateScrollState(true)
            } else if currentOffset < lastOffset - threshold && isScrollingDown {
                updateScrollState(false)
            }
            
            lastOffset = currentOffset
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
