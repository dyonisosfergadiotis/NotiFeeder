import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: TVArticleStore
    @State private var selectedFilter: TVArticleFilter = .all

    var body: some View {
        NavigationStack {
            TVArticleListView(filter: selectedFilter)
                .navigationTitle("NewsFeeder")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        TVNavigationTitleView()
                    }

                    ToolbarItem(placement: .topBarLeading) {
                        TVFilterToolbarMenu(selectedFilter: $selectedFilter)
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        TVStatusToolbarView()
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await store.refresh() }
                        } label: {
                            Label("Aktualisieren", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing || store.feeds.isEmpty)
                    }
                }
        }
        .tint(store.tintColor(for: selectedFilter))
        .toolbarBackground(.visible, for: .navigationBar)
        .background(Color.black)
        .task {
            await store.bootstrap()
        }
    }
}

private struct TVNavigationTitleView: View {
    var body: some View {
        Label {
            Text("NewsFeeder")
                .font(.headline.weight(.semibold))
        } icon: {
            Image(systemName: "newspaper.fill")
        }
        .labelStyle(.titleAndIcon)
    }
}

private struct TVFilterToolbarMenu: View {
    @EnvironmentObject private var store: TVArticleStore
    @Binding var selectedFilter: TVArticleFilter

    private var navigationItems: [TVArticleFilter] {
        [.all, .unread, .saved] + store.feeds.map { .feed($0.url, $0.title) }
    }

    var body: some View {
        Menu {
            ForEach(navigationItems) { filter in
                Button {
                    selectedFilter = filter
                } label: {
                    Label {
                        Text("\(filter.title) (\(store.count(for: filter)))")
                    } icon: {
                        if selectedFilter == filter {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: filter.systemImage)
                        }
                    }
                }
            }
        } label: {
            Label(selectedFilter.title, systemImage: selectedFilter.systemImage)
        }
    }
}

private struct TVArticleListView: View {
    @EnvironmentObject private var store: TVArticleStore
    @State private var selectedEntry: FeedEntry?
    @FocusState private var focusedEntryID: String?
    let filter: TVArticleFilter

    private var entries: [FeedEntry] {
        store.entries(for: filter)
    }

    var body: some View {
        Group {
            if store.isRefreshing && store.entries.isEmpty {
                ProgressView("Feeds werden geladen")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.feeds.isEmpty {
                TVEmptyStateView(
                    title: store.isUsingLocalFeedLayer ? "Keine lokalen Feeds" : "Keine iCloud-Feeds",
                    message: store.isUsingLocalFeedLayer
                        ? "Lege lokale tvOS-Quellen an oder synchronisiere die Feeds spaeter ueber iCloud."
                        : "Lege Feeds in der iPhone-App an. Apple TV synchronisiert die Quellen aus iCloud; im Simulator nutzt die App lokale Debug-Quellen.",
                    systemImage: "dot.radiowaves.left.and.right"
                )
            } else if entries.isEmpty {
                TVEmptyStateView(
                    title: "Keine Artikel",
                    message: filter.emptyMessage,
                    systemImage: "newspaper"
                )
            } else {
                List(entries, id: \.link) { entry in
                    let resolved = store.resolvedEntry(for: entry) ?? entry
                    Button {
                        selectedEntry = resolved
                    } label: {
                        TVArticleRowView(
                            entry: resolved,
                            isBookmarked: store.isBookmarked(resolved),
                            feedColor: store.feedColor(for: resolved.feedURL),
                            isFocused: focusedEntryID == resolved.link
                        )
                    }
                    .buttonStyle(.plain)
                    .focused($focusedEntryID, equals: resolved.link)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .focusSection()
                .defaultFocus($focusedEntryID, entries.first?.link)
            }
        }
        .onChange(of: filter.id) { _, _ in
            focusedEntryID = entries.first?.link
        }
        .onChange(of: entries.map(\.link)) { _, links in
            if focusedEntryID == nil || !links.contains(focusedEntryID ?? "") {
                focusedEntryID = links.first
            }
        }
        .navigationDestination(item: $selectedEntry) { entry in
            TVArticleReaderView(entry: entry)
        }
    }
}

private struct TVArticleRowView: View {
    let entry: FeedEntry
    let isBookmarked: Bool
    let feedColor: Color
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(feedColor)
                .frame(width: 7, height: 118)
                .opacity(entry.isRead ? 0.45 : 1)

            TVArticleThumbnailView(entry: entry)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if let source = entry.sourceTitle, !source.isEmpty {
                        Text(source)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(displayDate)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(.yellow)
                    }
                }

                Text(entry.displayTitle)
                    .font(.title3.weight(entry.isRead ? .medium : .semibold))
                    .foregroundStyle(entry.isRead ? .secondary : .primary)
                    .lineLimit(2)

                Text(entry.previewText)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isFocused ? feedColor.opacity(0.18) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isFocused ? feedColor.opacity(0.55) : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var displayDate: String {
        let date = DateParser.parse(entry.pubDateString)
        guard date != .distantPast else { return "Ohne Datum" }
        return DateFormatter.localized.string(from: date)
    }
}

private struct TVArticleThumbnailView: View {
    let entry: FeedEntry

    var body: some View {
        Group {
            if let rawURL = entry.imageURL,
               let url = URL(string: rawURL) {
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
        .frame(width: 196, height: 118)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
            Image(systemName: "text.alignleft")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
        }
    }
}

private struct TVArticleReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var store: TVArticleStore
    let entry: FeedEntry

    private var currentEntry: FeedEntry {
        store.resolvedEntry(for: entry) ?? entry
    }

    private var feedColor: Color {
        store.feedColor(for: currentEntry.feedURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(metadata)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(currentEntry.displayTitle)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)

                TVArticleBodyView(text: articleText, feedColor: feedColor)

                if let rawURL = currentEntry.imageURL,
                   let url = URL(string: rawURL) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 420)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                    .frame(maxWidth: 1040)
                    .focusable()
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(.horizontal, 84)
            .padding(.vertical, 60)
        }
        .scrollIndicators(.visible)
        .tint(feedColor)
        .navigationTitle(currentEntry.sourceTitle ?? "Artikel")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Label("Schliessen", systemImage: "xmark")
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.toggleRead(currentEntry)
                } label: {
                    Label(
                        currentEntry.isRead ? "Ungelesen" : "Gelesen",
                        systemImage: currentEntry.isRead ? "eye.slash" : "eye"
                    )
                }

                Button {
                    store.toggleBookmark(currentEntry)
                } label: {
                    Label(
                        store.isBookmarked(currentEntry) ? "Gespeichert" : "Speichern",
                        systemImage: store.isBookmarked(currentEntry) ? "bookmark.fill" : "bookmark"
                    )
                }

                if let url = URL(string: currentEntry.link) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Im Web", systemImage: "safari")
                    }
                }
            }
        }
        .onAppear {
            store.markRead(currentEntry)
        }
        .onExitCommand {
            dismiss()
        }
    }

    private var articleText: String {
        if let raw = currentEntry.contentRaw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let stripped = HTMLText.stripHTML(raw)
            if stripped.count > currentEntry.content.count {
                return stripped
            }
        }

        let content = currentEntry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? "Dieser Feed liefert nur einen kurzen Eintrag. Oeffne den Artikel im Web, um den vollstaendigen Text zu lesen." : content
    }

    private var metadata: String {
        var parts: [String] = []
        if let source = currentEntry.sourceTitle, !source.isEmpty {
            parts.append(source)
        }
        let date = DateParser.parse(currentEntry.pubDateString)
        if date != .distantPast {
            parts.append(DateFormatter.localized.string(from: date))
        }
        return parts.joined(separator: "  |  ")
    }
}

private struct TVArticleBodyView: View {
    let text: String
    let feedColor: Color
    @FocusState private var focusedParagraph: Int?

    private var paragraphs: [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let split = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return split.isEmpty ? [text] : split
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, paragraph in
                Text(paragraph)
                    .font(.system(size: 31, weight: .regular, design: .serif))
                    .lineSpacing(12)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, index == 0 ? 22 : 0)
                    .overlay(alignment: .leading) {
                        if index == 0 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(feedColor)
                                .frame(width: 6)
                        }
                    }
                    .focusable()
                    .focused($focusedParagraph, equals: index)
                    .padding(.vertical, 8)
                    .padding(.trailing, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(focusedParagraph == index ? feedColor.opacity(0.12) : Color.clear)
                    }
            }
        }
        .focusSection()
        .defaultFocus($focusedParagraph, 0)
        .onAppear {
            focusedParagraph = 0
        }
    }
}

private struct TVEmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.largeTitle.weight(.bold))
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(60)
    }
}

private struct TVStatusToolbarView: View {
    @EnvironmentObject private var store: TVArticleStore

    var body: some View {
        HStack(spacing: 12) {
            if store.isRefreshing {
                ProgressView()
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(store.statusHeadline)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let detail = store.statusDetail {
                    Text(detail)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(TVArticleStore.preview)
}
