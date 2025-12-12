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
    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var store: ArticleStore
    @Environment(\.modelContext) private var modelContext

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
                if parsed != Date.distantPast {
                    Text(DateFormatter.localized.string(from: parsed))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text(dateString)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .background(
            LinearGradient(
                colors: [headerTint.opacity(0.3), (feedColor ?? .primary).opacity(0.15)],
                        startPoint: .top,
                        endPoint: .bottom)
                .opacity(1)
        )
    }

    private var contentWebView: some View {
        WebView(webView: webView,
                htmlContent: formattedHTML(accentHex: theme.uiAccentHexString))
            .frame(maxHeight: .infinity)
            .edgesIgnoringSafeArea(.bottom)
    }

    @ViewBuilder private var bottomToolbarItems: some View {
            HStack {
                Button {
                    if let url = URL(string: entry.link) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Image(systemName: "safari")
                }
                .tint(feedColor ?? theme.uiAccentColor)

                Spacer(minLength: 20)

                Button {
                    gatherShareContent()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .tint(feedColor ?? theme.uiAccentColor)

                Spacer(minLength: 20)

                Button {
                    let newValue = !isReadLocal
                    isReadLocal = newValue
                    store.setRead(newValue, articleID: entry.link)
                } label: {
                    Image(systemName: isReadLocal ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .tint(feedColor ?? theme.uiAccentColor)

                Spacer(minLength: 20)

                Button {
                    activeSheet = .readerSettings
                } label: {
                    Image(systemName: "textformat.size")
                }
                .tint(feedColor ?? theme.uiAccentColor)
            }
            .padding(.horizontal, 20)
       
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                headerView

                contentWebView
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(.smooth(duration: 0.22), value: entry.id)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        toggleBookmark()
                    } label: {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 18, weight: .regular))
                            .contentShape(Rectangle())
                    }
                    .tint(feedColor ?? theme.uiAccentColor)
                }
                ToolbarItem(placement: .bottomBar) {
                    bottomToolbarItems
                }
            }
            .toolbarBackground((feedColor ?? theme.uiAccentColor).opacity(0.1), for: .bottomBar)
            .toolbar(.visible, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(entry.title)
            .navigationBarBackButtonHidden(false)
            .onAppear {
                DispatchQueue.main.async {
                    // Mark article as recently read (not full read marking)
                    store.markRecentlyRead(articleID: entry.link)
                    isReadLocal = store.isRead(articleID: entry.link)
                    isBookmarked = isCurrentlyBookmarked()
                }
            }
            // Reader settings panel has no separate preview; article content acts as live preview
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .share(let payload, _):
                    ActivityView(activityItems: [payload])
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.visible)
                case .readerSettings:
                    ReaderSettingsPanel(textAlignment: $readerTextAlignmentRaw,
                                        fontScale: $readerFontScale,
                                        fontFamily: $readerFontFamily,
                                        lineSpacing: $readerLineSpacing,
                                        feedColor: .constant(feedColor ?? theme.uiAccentColor))
                    .presentationDetents([.fraction(0.44)]) // <— hier
                    .presentationDragIndicator(.visible)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                // Mark article as recently read (not full read marking)
                store.markRecentlyRead(articleID: entry.link)
                isBookmarked = isCurrentlyBookmarked()
            }
        }
    }

    private func fixYouTubeIframes(in html: String) -> String {
        let pattern = "<iframe([^>]*)src=\"([^\"]*youtube[^\"]*)\"([^>]*)>"
        return html.replacingOccurrences(
            of: pattern,
            with: "<iframe$1src=\"$2\"$3 allow=\"fullscreen\" playsinline></iframe>",
            options: .regularExpression
        )
    }

    private func formattedHTML(accentHex: String) -> String {
        let fontSize = 18 * readerFontScale
        let lineHeight = readerLineSpacing
        let fontFamilyCSS = (ReaderFontFamily(rawValue: readerFontFamily) ?? .rounded).cssValue

        let textAlignCSS: String
        let textJustifyCSS: String
        switch readerTextAlignmentRaw {
        case "center":
            textAlignCSS = "center"
            textJustifyCSS = "auto"
        case "right":
            textAlignCSS = "right"
            textJustifyCSS = "auto"
        case "justified", "justify":
            textAlignCSS = "justify"
            textJustifyCSS = "inter-word"
        default:
            textAlignCSS = "left"
            textJustifyCSS = "auto"
        }
        
        let rgb = (feedColor ?? theme.uiAccentColor).rgbComponents ?? (0,0,0)
        // Beispiel: Wenn rgb = (200, 150, 100)


        // Erstelle den fertigen CSS-String im rgba-Format mit Opazität 0.9
        let darkBackground: String = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.15)"
        // Ergebnis für das Beispiel: "rgba(170, 120, 70, 0.9)"
        // For light mode background: original color with lighter alpha
        let lightBackground = "rgba(\(rgb.red),\(rgb.green),\(rgb.blue),0.15)"
        // Text color for dark mode: keep #EAEAEA as light text
        let darkTextColor = "#EAEAEA"
        // Text color for light mode: dark text
        let lightTextColor = "#111111"
        // Link color: use accentHex for consistency
        let linkColor = feedColor?.description ?? theme.uiAccentHexString

        return  """
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
        
        
              body {
                font-family: \(fontFamilyCSS);
                font-size: \(fontSize)px;
                padding: 16px;
                line-height: \(lineHeight);
                margin: 0;
                text-align: \(textAlignCSS);
                text-justify: \(textJustifyCSS);
              }
        
              @media (prefers-color-scheme: dark) {
                body {
                  background-color: \(darkBackground);
                  color: \(darkTextColor);
                }
                a { color: \(linkColor); }
                html {
                 background-color: #000000;
                }
              }
        
              @media (prefers-color-scheme: light) {
                body {
                  background-color: \(lightBackground);
                  color: \(lightTextColor);
                }
                a { color: \(linkColor); }
                html {
                 background-color: #ffffff;
                }
              }
        
              ul, ol {
                padding-left: 20px;
                margin-top: 0.5em;
                margin-bottom: 0.5em;
              }
        
              li {
                margin-bottom: 0.25em;
              }
        
              img {
                  display: block;
                  max-width: 90%;
                  height: auto;
                  border-radius: 10px;
                  margin: 16px auto;
              }
        
              iframe {
                  display: block;
                  max-width: 90%;
                  width: 90%;
                  height: auto;
                  aspect-ratio: 16 / 9;
                  margin: 16px auto;
                  border-radius: 10px;
              }
        
              h1, h2, h3 {
                font-weight: 600;
                margin-top: 1em;
              }
            </style>
          </head>
          <body>
            \(fixYouTubeIframes(in: entry.content))
          </body>
        </html>
        """
    }

    private var headerTint: Color {
        feedColor ?? theme.uiAccentColor
    }

    private func composeShareText(selectedSnippet: String?) -> String {
        var parts: [String] = []
        parts.append(entry.title)
        if let snippet = selectedSnippet, !snippet.isEmpty {
            parts.append(snippet)
        }
        parts.append(entry.link)
        return parts.joined(separator: "\n\n")
    }

    private func gatherShareContent() {
        let script = "window.getSelection().toString();"
        webView.evaluateJavaScript(script) { result, _ in
            let snippet = (result as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                let composed = composeShareText(selectedSnippet: (snippet?.isEmpty == false) ? snippet : nil)
                shareText = composed
                activeSheet = .share(payload: composed)
            }
        }
    }

    private func isCurrentlyBookmarked() -> Bool {
        let descriptor = FetchDescriptor<FeedEntryModel>(predicate: #Predicate { $0.link == entry.link && $0.isBookmarked })
        if let result = try? modelContext.fetch(descriptor) {
            return !result.isEmpty
        }
        return false
    }

    private func toggleBookmark() {
        BookmarkService.toggleBookmark(for: entry, context: modelContext)
        isBookmarked = BookmarkService.isBookmarked(link: entry.link, context: modelContext)
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView
    let htmlContent: String

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.loadHTMLString(htmlContent, baseURL: nil)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    FeedDetailView(entry: FeedEntry(title: "test",link: "http:abc.de",content: "test",imageURL: nil,author: "mama",pubDateString: "15.11.25",isRead: false))
        .environmentObject(ThemeSettings())
        .environmentObject(ArticleStore.shared)
}
 

// Gibt einen halbtransparenten rgba-Overlay-String für Dark Mode zurück, etwa: "rgba(100, 80, 60, 0.1)"
// Beispiel der Nutzung:
//   let css = generateDarkTintOverlayCSS(from: (100, 80, 60)) // => "rgba(100, 80, 60, 0.1)"
private func generateDarkTintOverlayCSS(from rgb: (Int, Int, Int)) -> String {
    return "rgba(\(rgb.0), \(rgb.1), \(rgb.2), 0.1)"
}
