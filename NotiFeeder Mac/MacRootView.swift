import SwiftUI
import WebKit

struct MacRootView: View {
    @EnvironmentObject private var store: MacFeedStore
    @EnvironmentObject private var theme: ThemeSettings
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            MacFeedSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            MacArticleListView()
                .navigationSplitViewColumnWidth(min: 360, ideal: 430, max: 540)
        } detail: {
            MacReaderView(entry: store.selectedArticle)
        }
        .focusedObject(store)
        .background(MacAccentBackground(accent: theme.uiAccentColor).ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.refreshAllFeeds()
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing || store.feeds.isEmpty)
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    store.addFeedFromDraft()
                } label: {
                    Label("Feed hinzufügen", systemImage: "plus")
                }
                .disabled(store.addFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task {
            if store.entries.isEmpty, !store.feeds.isEmpty {
                store.refreshAllFeeds()
            }
        }
    }
}

struct MacFeedSidebar: View {
    @EnvironmentObject private var store: MacFeedStore
    @EnvironmentObject private var theme: ThemeSettings

    var body: some View {
        List(selection: $store.selection) {
            Section {
                sidebarRow(.all, count: store.entries.count)
                sidebarRow(.unread, count: store.unreadCount)
                sidebarRow(.saved, count: store.savedCount)
            }

            Section("Feeds") {
                ForEach(store.feeds) { feed in
                    let tint = theme.color(for: feed.url)
                    Label {
                        Text(feed.title)
                    } icon: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(tint)
                    }
                        .tag(MacFeedStore.Selection(kind: .feed(feed.url)))
                        .contextMenu {
                            Button(role: .destructive) {
                                store.selection = MacFeedStore.Selection(kind: .feed(feed.url))
                                store.deleteSelectedFeed()
                            } label: {
                                Label("Feed löschen", systemImage: "trash")
                            }
                        }
                }
            }

            Section {
                TextField("Feed-URL", text: $store.addFeedURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        store.addFeedFromDraft()
                    }
                    .tint(theme.uiAccentColor)

                Button {
                    store.addFeedFromDraft()
                } label: {
                    Label("Feed hinzufügen", systemImage: "plus")
                }
                .disabled(store.addFeedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("NewsFeeder")
        .scrollContentBackground(.hidden)
        .background(MacAccentBackground(accent: theme.uiAccentColor))
    }

    private func sidebarRow(_ filter: MacFeedStore.SmartFilter, count: Int) -> some View {
        Label {
            HStack {
                Text(filter.title)
                Spacer()
                Text(count.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: filter.systemImage)
        }
        .tag(MacFeedStore.Selection(kind: .smart(filter)))
    }
}

struct MacArticleListView: View {
    @EnvironmentObject private var store: MacFeedStore
    @EnvironmentObject private var theme: ThemeSettings

    var body: some View {
        VStack(spacing: 0) {
            if store.visibleEntries.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "newspaper",
                    description: Text(emptyDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedArticleID) {
                    ForEach(store.visibleEntries) { entry in
                        let tint = theme.color(for: entry.feedURL)
                        MacArticleRow(
                            entry: entry,
                            isRead: store.readArticleIDs.contains(entry.id),
                            isBookmarked: store.bookmarkedArticleIDs.contains(entry.id),
                            feedColor: tint,
                            isSelected: store.selectedArticleID == entry.id
                        )
                        .tag(entry.id)
                        .contextMenu {
                            Button {
                                store.toggleRead(entry)
                            } label: {
                                Label(
                                    store.readArticleIDs.contains(entry.id) ? "Als ungelesen markieren" : "Als gelesen markieren",
                                    systemImage: store.readArticleIDs.contains(entry.id) ? "circle" : "checkmark.circle"
                                )
                            }

                            Button {
                                store.toggleBookmark(entry)
                            } label: {
                                Label(
                                    store.bookmarkedArticleIDs.contains(entry.id) ? "Bookmark entfernen" : "Bookmark setzen",
                                    systemImage: store.bookmarkedArticleIDs.contains(entry.id) ? "bookmark.slash" : "bookmark"
                                )
                            }

                            if let url = URL(string: entry.link) {
                                Link(destination: url) {
                                    Label("Im Browser öffnen", systemImage: "safari")
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            if let statusMessage = store.statusMessage {
                HStack {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(MacTopChromeBackground(accent: theme.uiAccentColor))
            }
        }
        .background(MacAccentBackground(accent: theme.uiAccentColor))
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Artikel suchen")
        .navigationTitle(navigationTitle)
        .onChange(of: store.selection) { _, _ in
            store.selectFirstVisibleArticleIfNeeded()
        }
        .onChange(of: store.searchText) { _, _ in
            store.selectFirstVisibleArticleIfNeeded()
        }
        .onChange(of: store.selectedArticleID) { _, _ in
            store.markSelectedArticleReadIfNeeded()
        }
    }

    private var navigationTitle: String {
        switch store.selection.kind {
        case .smart(let filter):
            filter.title
        case .feed(let url):
            store.feeds.first(where: { $0.url == url })?.title ?? "Feed"
        }
    }

    private var emptyTitle: String {
        store.feeds.isEmpty ? "Keine Feeds" : "Keine Artikel"
    }

    private var emptyDescription: String {
        store.feeds.isEmpty
            ? "Füge links einen RSS-Feed hinzu."
            : "Aktualisiere die Feeds oder ändere den Filter."
    }
}

struct MacArticleRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var textColumnHeight: CGFloat = MacArticleRowLayout.fallbackThumbnailHeight

    let entry: FeedEntry
    let isRead: Bool
    let isBookmarked: Bool
    let feedColor: Color
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isRead ? feedColor.opacity(0.24) : feedColor)
                .frame(width: 5)
                .padding(.vertical, 3)

            MacArticleThumbnailView(url: thumbnailURL,
                                    feedColor: feedColor,
                                    isRead: isRead,
                                    height: textColumnHeight)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.sourceTitle ?? "Feed")
                        .font(.caption)
                        .fontWeight(isRead ? .regular : .semibold)
                        .foregroundStyle(feedColor)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let date = entry.parsedPubDate {
                        Text(DateFormatter.timeOnly.string(from: date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(feedColor)
                    }
                }

                Text(entry.displayTitle)
                    .font(.headline)
                    .fontWeight(isRead ? .regular : .semibold)
                    .foregroundStyle(isRead ? Color.secondary : Color.primary)
                    .lineLimit(2)

                if !entry.content.isEmpty {
                    Text(entry.content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: MacArticleRowTextHeightPreferenceKey.self,
                                    value: proxy.size.height)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: UIStylePolicy.Radius.medium, style: .continuous)
                .fill(rowBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: UIStylePolicy.Radius.medium, style: .continuous)
                        .strokeBorder(feedColor.opacity(isSelected ? 0.34 : 0.13), lineWidth: 1)
                }
        }
        .padding(.vertical, 4)
        .onPreferenceChange(MacArticleRowTextHeightPreferenceKey.self) { newHeight in
            let measuredHeight = max(1, newHeight)
            guard abs(textColumnHeight - measuredHeight) > 0.5 else { return }
            textColumnHeight = measuredHeight
        }
    }

    private var thumbnailURL: URL? {
        let trimmed = (entry.imageURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard let articleURL = URL(string: entry.link) else {
            return URL(string: trimmed)
        }

        return URL(string: trimmed, relativeTo: articleURL)?.absoluteURL
    }

    private var rowBackground: Color {
        if isSelected {
            return feedColor.opacity(colorScheme == .dark ? 0.22 : 0.14)
        }
        return feedColor.opacity(isRead ? 0.045 : 0.085)
    }
}

private enum MacArticleRowLayout {
    static let thumbnailWidth: CGFloat = 76
    static let fallbackThumbnailHeight: CGFloat = 76
    static let thumbnailCornerRadius: CGFloat = 10
}

private struct MacArticleRowTextHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = MacArticleRowLayout.fallbackThumbnailHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct MacArticleThumbnailView: View {
    let url: URL?
    let feedColor: Color
    let isRead: Bool
    let height: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: MacArticleRowLayout.thumbnailWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: MacArticleRowLayout.thumbnailCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MacArticleRowLayout.thumbnailCornerRadius, style: .continuous)
                .stroke(feedColor.opacity(isRead ? 0.18 : 0.34), lineWidth: 1)
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MacArticleRowLayout.thumbnailCornerRadius, style: .continuous)
                .fill(feedColor.opacity(isRead ? 0.08 : 0.14))

            Image(systemName: "photo")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(feedColor.opacity(isRead ? 0.56 : 0.86))
        }
    }
}

struct MacReaderView: View {
    @EnvironmentObject private var store: MacFeedStore
    @EnvironmentObject private var theme: ThemeSettings
    let entry: FeedEntry?

    var body: some View {
        Group {
            if let entry {
                let tint = theme.color(for: entry.feedURL)
                VStack(spacing: 0) {
                    MacReaderHeader(entry: entry, feedColor: tint)

                    Divider()

                    MacArticleWebView(html: readerHTML(for: entry, feedColor: tint), baseURL: URL(string: entry.link))
                        .background(Color(nsColor: .textBackgroundColor))
                }
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            store.toggleRead(entry)
                        } label: {
                            Label(
                                store.readArticleIDs.contains(entry.id) ? "Ungelesen" : "Gelesen",
                                systemImage: store.readArticleIDs.contains(entry.id) ? "circle" : "checkmark.circle"
                            )
                        }
                        .keyboardShortcut("m", modifiers: .command)

                        Button {
                            store.toggleBookmark(entry)
                        } label: {
                            Label(
                                store.bookmarkedArticleIDs.contains(entry.id) ? "Bookmark entfernen" : "Bookmark",
                                systemImage: store.bookmarkedArticleIDs.contains(entry.id) ? "bookmark.fill" : "bookmark"
                            )
                        }
                        .keyboardShortcut("b", modifiers: .command)

                        if let url = URL(string: entry.link) {
                            Link(destination: url) {
                                Label("Im Browser öffnen", systemImage: "safari")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Kein Artikel ausgewählt",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Wähle links einen Artikel aus.")
                )
                .background(MacAccentBackground(accent: theme.uiAccentColor))
            }
        }
        .navigationTitle(entry?.sourceTitle ?? "Reader")
    }

    private func readerHTML(for entry: FeedEntry, feedColor: Color) -> String {
        let title = entry.displayTitle.escapedForHTML
        let source = (entry.sourceTitle ?? "NewsFeeder").escapedForHTML
        let date = entry.parsedPubDate.map(DateFormatter.localized.string(from:)) ?? ""
        let body = (entry.contentRaw?.isEmpty == false ? entry.contentRaw : nil) ?? "<p>\(entry.content.escapedForHTML)</p>"
        let accent = feedColor.hexString ?? UIStylePolicy.Brand.appIconDeepHex

        return """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root {
            color-scheme: light dark;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
        }
        body {
            margin: 0;
            padding: 34px 44px 60px;
            line-height: 1.58;
            font-size: 17px;
            color: CanvasText;
            background:
                linear-gradient(145deg, color-mix(in srgb, \(accent) 13%, Canvas), Canvas 42%);
        }
        main {
            max-width: 760px;
            margin: 0 auto;
        }
        h1 {
            font-size: 34px;
            line-height: 1.08;
            letter-spacing: 0;
            margin: 0 0 12px;
        }
        h1::before {
            content: "";
            display: block;
            width: 58px;
            height: 5px;
            border-radius: 99px;
            background: \(accent);
            margin: 0 0 18px;
        }
        .meta {
            color: color-mix(in srgb, CanvasText 56%, transparent);
            font-size: 13px;
            margin-bottom: 28px;
        }
        img, video, iframe {
            max-width: 100%;
            height: auto;
            border-radius: 8px;
        }
        a { color: \(accent); }
        p { margin: 0 0 1em; }
        pre, code {
            font-family: "SF Mono", ui-monospace, monospace;
        }
        blockquote {
            margin-left: 0;
            padding-left: 18px;
            border-left: 3px solid color-mix(in srgb, CanvasText 18%, transparent);
            color: color-mix(in srgb, CanvasText 78%, transparent);
        }
        </style>
        </head>
        <body>
        <main>
            <h1>\(title)</h1>
            <div class="meta">\(source)\(date.isEmpty ? "" : " · \(date.escapedForHTML)")</div>
            \(body)
        </main>
        </body>
        </html>
        """
    }
}

struct MacReaderHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let entry: FeedEntry
    let feedColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.displayTitle)
                .font(.title2.weight(.semibold))
                .lineLimit(2)

            HStack(spacing: 10) {
                Label(entry.sourceTitle ?? "Feed", systemImage: "dot.radiowaves.left.and.right")
                if let date = entry.parsedPubDate {
                    Label(DateFormatter.localized.string(from: date), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(headerText.opacity(0.76))
        }
        .foregroundStyle(headerText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background {
            LinearGradient(
                colors: [
                    feedColor,
                    feedColor.opacity(colorScheme == .dark ? 0.72 : 0.82)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var headerText: Color {
        feedColor.isLight ? .black : .white
    }
}

struct MacArticleWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsMagnification = true
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: baseURL)
    }
}

struct MacFeedCommands: Commands {
    @FocusedObject private var store: MacFeedStore?

    var body: some Commands {
        CommandMenu("Artikel") {
            Button("Nächster Artikel") {
                store?.selectNextArticle()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Button("Vorheriger Artikel") {
                store?.selectPreviousArticle()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Als gelesen markieren") {
                store?.markSelectedRead()
            }
            .keyboardShortcut("m", modifiers: .command)
        }
    }
}

struct MacSettingsView: View {
    @EnvironmentObject private var store: MacFeedStore
    @EnvironmentObject private var theme: ThemeSettings

    var body: some View {
        Form {
            Section("Feeds") {
                LabeledContent("Gespeicherte Feeds", value: store.feeds.count.formatted())
                LabeledContent("Artikel im Cache", value: store.entries.count.formatted())
                LabeledContent("Ungelesen", value: store.unreadCount.formatted())
            }

            Section {
                Button("Alle Feeds aktualisieren") {
                    store.refreshAllFeeds()
                }
                .disabled(store.isRefreshing || store.feeds.isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding()
        .tint(theme.uiAccentColor)
    }
}

private struct MacAccentBackground: View {
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: UIStylePolicy.accentBackgroundColors(accent: accent, colorScheme: colorScheme),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct MacTopChromeBackground: View {
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: UIStylePolicy.topChromeColors(accent: accent, colorScheme: colorScheme),
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private extension Color {
    var hexString: String? {
        #if os(macOS)
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
        #else
        return nil
        #endif
    }

    var isLight: Bool {
        #if os(macOS)
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return false }
        let luminance = (0.2126 * rgb.redComponent) + (0.7152 * rgb.greenComponent) + (0.0722 * rgb.blueComponent)
        return luminance > 0.62
        #else
        return false
        #endif
    }
}

private extension String {
    var escapedForHTML: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
