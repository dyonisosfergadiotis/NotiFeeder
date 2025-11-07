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

    @State private var isSharing = false
    @State private var shareText: String = ""
    @State private var isReadLocal: Bool = false
    @State private var isBookmarked: Bool = false

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
                WebView(htmlContent: formattedHTML(accentHex: theme.uiAccentHexString))
                    .frame(maxHeight: .infinity)
                    .edgesIgnoringSafeArea(.bottom)
            }
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(.smooth(duration: 0.22), value: entry.id)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    HStack {
                        Spacer()
                        Button {
                            if let url = URL(string: entry.link) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Image(systemName: "safari")
                        }
                        .tint(feedColor ?? theme.uiAccentColor)

                        Spacer()

                        Button {
                            shareText = buildShareText()
                            isSharing = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .tint(feedColor ?? theme.uiAccentColor)

                        Spacer()

                        Button {
                            let newValue = !isReadLocal
                            isReadLocal = newValue
                            store.setRead(newValue, articleID: entry.link)
                        } label: {
                            Image(systemName: isReadLocal ? "checkmark.circle.fill" : "checkmark.circle")
                        }
                        .tint(feedColor ?? theme.uiAccentColor)

                        Spacer()

                        Button {
                            toggleBookmark()
                        } label: {
                            Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        }
                        .tint(feedColor ?? theme.uiAccentColor)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
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
            .sheet(isPresented: $isSharing) {
                ActivityView(activityItems: [shareText])
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
        """
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
              body {
                font-family: -apple-system;
                font-size: 18px;
                padding: 16px;
                line-height: 1.6;
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

    private func summary(from text: String, limit: Int = 280) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        // Try to cut at sentence boundary near the limit
        let idx = trimmed.index(trimmed.startIndex, offsetBy: min(limit, trimmed.count))
        var candidate = String(trimmed[..<idx])
        if let lastDot = candidate.lastIndex(of: ".") {
            candidate = String(candidate[...lastDot])
        }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func buildShareText() -> String {
        let text = HTMLText.stripHTML(entry.content)
        let short = summary(from: text)
        var parts: [String] = []
        parts.append("Titel: \(entry.title)")
        if !short.isEmpty { parts.append("\nZusammenfassung:\n\(short)") }
        parts.append("\nLink: \(entry.link)")
        return parts.joined(separator: "\n")
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
    let htmlContent: String

    func makeUIView(context: Context) -> WKWebView { WKWebView() }
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
    FeedDetailView(entry: FeedEntry(title: "test",link: "http:abc.de",content: "test",imageURL: nil,author: "mama",pubDateString: nil,isRead: false))
}
 
