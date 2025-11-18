import WebKit
import SwiftUI
import FoundationModels
import Foundation
import SwiftData

struct FeedDetailView: View {
    var entry: FeedEntry
    var onAppearMarkRead: (() -> Void)? = nil
    var feedColor: Color?
    @EnvironmentObject private var theme: ThemeSettings
    @EnvironmentObject private var store: ArticleStore
    @Environment(\.modelContext) private var modelContext

    @State private var webView = WKWebView()
    @State private var shareText: String = ""
    @State private var activeSheet: ActiveSheet?
    @State private var isReadLocal: Bool = false
    @State private var isBookmarked: Bool = false
    @AppStorage("readerFontScale") private var readerFontScale: Double = 1.0
    @AppStorage("readerFontFamily") private var readerFontFamily: String = ReaderFontFamily.system.rawValue
    @AppStorage("readerLineSpacing") private var readerLineSpacing: Double = 1.4

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

    init(entry: FeedEntry, feedColor: Color? = nil, onAppearMarkRead: (() -> Void)? = nil) {
        self.entry = entry
        self.feedColor = feedColor
        self.onAppearMarkRead = onAppearMarkRead
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {

                // Header in der unteren Hälfte
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("by \(entry.author ?? "Unknown")")
                        Text("·")
                        Text(entry.sourceTitle ?? "Quelle")
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    if let dateString = entry.pubDateString {
                        if let date = DateFormatter.rfc822.date(from: dateString) {
                            Text(DateFormatter.localized.string(from: date))
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
                    LinearGradient(colors: [headerTint.opacity(0.24), Color(.systemBackground)],
                                   startPoint: .top,
                                   endPoint: .bottom)
                        .opacity(0.9)
                )

                // WebView unten
                WebView(webView: webView,
                        htmlContent: formattedHTML(accentHex: theme.uiAccentHexString))
                    .frame(maxHeight: .infinity)
                    .edgesIgnoringSafeArea(.bottom)
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
                ToolbarItemGroup(placement: .bottomBar) {
                    HStack(spacing: 12) {
                        Button {
                            if let url = URL(string: entry.link) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "safari")
                        }
                        .tint(feedColor ?? theme.uiAccentColor)
                        .frame(maxWidth: .infinity)

                        Button {
                            gatherShareContent()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(feedColor ?? theme.uiAccentColor)
                        .frame(maxWidth: .infinity)

                        Button {
                            let newValue = !isReadLocal
                            isReadLocal = newValue
                            store.setRead(newValue, articleID: entry.link)
                        } label: {
                            Image(systemName: isReadLocal ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .tint(feedColor ?? theme.uiAccentColor)
                        .frame(maxWidth: .infinity)

                        Button {
                            activeSheet = .readerSettings
                        } label: {
                            Image(systemName: "textformat.size")
                        }
                        .tint(feedColor ?? theme.uiAccentColor)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
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
                    onAppearMarkRead?()
                    isReadLocal = store.isRead(articleID: entry.link)
                    isBookmarked = isCurrentlyBookmarked()
                }
            }
            // Reader settings panel has no separate preview; article content acts as live preview
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .share(let payload, _):
                    ActivityView(activityItems: [payload])
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                case .readerSettings:
                    ReaderSettingsPanel(fontScale: $readerFontScale,
                                        fontFamily: $readerFontFamily,
                                        lineSpacing: $readerLineSpacing)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                onAppearMarkRead?()
                isBookmarked = isCurrentlyBookmarked()
            }
        }
    }


    private func formattedHTML(accentHex: String) -> String {
        let fontSize = 18 * readerFontScale
        let lineHeight = readerLineSpacing
        let fontFamilyCSS = (ReaderFontFamily(rawValue: readerFontFamily) ?? .system).cssValue

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
              }
        
              @media (prefers-color-scheme: dark) {
                body {
                  background-color: #000000;
                  color: #EAEAEA;
                }
                a { color: \(accentHex); }
              }
        
              @media (prefers-color-scheme: light) {
                body {
                  background-color: #FFFFFF;
                  color: #111111;
                }
                a { color: \(accentHex); }
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
        
              h1, h2, h3 {
                font-weight: 600;
                margin-top: 1em;
              }
            </style>
          </head>
          <body>
            \(entry.content)
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
 
