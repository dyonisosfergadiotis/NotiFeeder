import SwiftUI

struct WatchContentView: View {
    @StateObject private var store = WatchSyncStore()
    @State private var selectedFilter: WatchArticleFilter = .top
    @State private var isFilterSheetPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if filteredEntries.isEmpty {
                        emptyStateCard
                    } else {
                        ForEach(filteredEntries) { entry in
                            NavigationLink {
                                WatchArticleDetailView(
                                    entry: entry,
                                    toggleBookmark: {
                                        store.toggleBookmark(for: entry)
                                    },
                                    openOnPhone: {
                                        store.openOnPhone(link: entry.link)
                                    }
                                )
                            } label: {
                                WatchArticleCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .navigationTitle(unreadCounterTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    refreshButton
                }

                ToolbarItem(placement: .topBarTrailing) {
                    filterButton
                }
            }
            .sheet(isPresented: $isFilterSheetPresented) {
                WatchFilterSheet(selectedFilter: $selectedFilter)
            }
            .refreshable {
                await store.requestRefresh()
            }
        }
    }

    private var unreadCount: Int {
        store.entries.filter { !$0.isRead }.count
    }

    private var unreadCounterTitle: String {
        unreadCount == 1 ? "1 ungelesen" : "\(unreadCount) ungelesen"
    }

    private var filteredEntries: [WatchFeedEntry] {
        selectedFilter.apply(to: store.entries)
    }

    private var refreshButton: some View {
        Button {
            Task {
                await store.requestRefresh()
            }
        } label: {
            if store.isRefreshing {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
                    .fontWeight(.light)
            }
        }
        .disabled(store.isRefreshing)
        .accessibilityLabel("Neu laden")
    }

    private var filterButton: some View {
        Button {
            isFilterSheetPresented = true
        } label: {
            Image(systemName: selectedFilter.systemImage)
                .fontWeight(.light)
        }
        .accessibilityLabel("Filter")
    }

    private var emptyStateCard: some View {
        VStack(spacing: 8) {
            Image(systemName: selectedFilter.emptySystemImage)
                .font(.title3)
                .fontWeight(.light)
                .foregroundStyle(.secondary)

            Text(selectedFilter.emptyTitle)
                .font(.headline)

            Text(selectedFilter.emptyMessage)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gray.opacity(0.14))
        )
    }
}

private struct WatchFilterSheet: View {
    @Binding var selectedFilter: WatchArticleFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(WatchArticleFilter.allCases) { filter in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedFilter = filter
                            }
                            dismiss()
                        } label: {
                            Label(
                                filter.title,
                                systemImage: selectedFilter == filter ? "checkmark.circle.fill" : filter.systemImage
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedFilter == filter ? .accentColor : .secondary)
                        .accessibilityLabel(filter.accessibilityLabel)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
            }
            .navigationTitle("Filter")
        }
    }
}

private enum WatchArticleFilter: String, CaseIterable, Identifiable {
    case top
    case unread
    case bookmarks
    case today

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top:
            return "Top"
        case .unread:
            return "Ungelesen"
        case .bookmarks:
            return "Lesezeichen"
        case .today:
            return "Heute"
        }
    }

    var systemImage: String {
        switch self {
        case .top:
            return "sparkle"
        case .unread:
            return "circle"
        case .bookmarks:
            return "bookmark"
        case .today:
            return "calendar"
        }
    }

    var accessibilityLabel: String {
        "\(title) anzeigen"
    }

    var emptySystemImage: String {
        switch self {
        case .top:
            return "newspaper"
        case .unread:
            return "checkmark.circle"
        case .bookmarks:
            return "bookmark"
        case .today:
            return "calendar"
        }
    }

    var emptyTitle: String {
        switch self {
        case .top:
            return "Keine Artikel"
        case .unread:
            return "Alles gelesen"
        case .bookmarks:
            return "Keine Lesezeichen"
        case .today:
            return "Heute nichts Neues"
        }
    }

    var emptyMessage: String {
        switch self {
        case .top:
            return "Sobald das iPhone synchronisiert, erscheinen hier Artikel."
        case .unread:
            return "Ungelesene Artikel erscheinen hier nach der nächsten Synchronisierung."
        case .bookmarks:
            return "Gespeicherte Artikel erscheinen hier, sobald du ein Lesezeichen setzt."
        case .today:
            return "Artikel von heute erscheinen hier nach dem nächsten Feed-Refresh."
        }
    }

    func apply(to entries: [WatchFeedEntry]) -> [WatchFeedEntry] {
        switch self {
        case .top:
            return entries
        case .unread:
            return entries.filter { !$0.isRead }
        case .bookmarks:
            return entries.filter(\.isBookmarked)
        case .today:
            return entries.filter(\.isToday)
        }
    }
}

private struct WatchArticleCard: View {
    let entry: WatchFeedEntry

    private var feedTint: Color {
        FeedTintPalette.color(for: entry.sourceDisplayTitle)
    }

    private var titleColor: Color {
        entry.isRead ? .secondary : .primary
    }

    private var previewColor: Color {
        entry.isRead ? .secondary.opacity(0.8) : .secondary
    }

    private var cardFillOpacity: Double {
        entry.isRead ? 0.16 : 0.30
    }

    private var cardBorderOpacity: Double {
        entry.isRead ? 0.20 : 0.46
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.isRead ? Color.gray.opacity(0.45) : feedTint)
                    .frame(width: 6, height: 6)

                Text(entry.sourceDisplayTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !entry.relativeDateText.isEmpty {
                    Text(entry.relativeDateText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if entry.isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(feedTint)
                        .accessibilityLabel("Lesezeichen")
                }
            }

            Text(entry.displayTitle)
                .font(.body.weight(entry.isRead ? .regular : .semibold))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(titleColor)

            if !entry.previewText.isEmpty {
                Text(entry.previewText)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(previewColor)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(feedTint.opacity(cardFillOpacity))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(feedTint.opacity(cardBorderOpacity), lineWidth: 1)
                }
        }
    }
}

private struct WatchArticleDetailView: View {
    let entry: WatchFeedEntry
    let toggleBookmark: () -> Void
    let openOnPhone: () -> Void
    @State private var isBookmarked: Bool

    init(entry: WatchFeedEntry, toggleBookmark: @escaping () -> Void, openOnPhone: @escaping () -> Void) {
        self.entry = entry
        self.toggleBookmark = toggleBookmark
        self.openOnPhone = openOnPhone
        _isBookmarked = State(initialValue: entry.isBookmarked)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.displayTitle)
                    .font(.headline)

                HStack(spacing: 6) {
                    Text(entry.sourceDisplayTitle)
                    if !entry.relativeDateText.isEmpty {
                        Text("•")
                        Text(entry.relativeDateText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !entry.previewText.isEmpty {
                    Text(entry.previewText)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }

                Button {
                    isBookmarked.toggle()
                    toggleBookmark()
                } label: {
                    Label(
                        isBookmarked ? "Lesezeichen entfernen" : "Lesezeichen",
                        systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
                    )
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)

                Button("Auf iPhone öffnen") {
                    openOnPhone()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }
}

private enum FeedTintPalette {
    private static let colors: [Color] = [
        Color(red: 0.97, green: 0.74, blue: 0.80),
        Color(red: 0.99, green: 0.82, blue: 0.67),
        Color(red: 0.98, green: 0.90, blue: 0.61),
        Color(red: 0.77, green: 0.93, blue: 0.74),
        Color(red: 0.73, green: 0.90, blue: 0.96),
        Color(red: 0.78, green: 0.85, blue: 0.99)
    ]

    static func color(for key: String) -> Color {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return colors[0] }
        let index = stableIndex(for: normalized, count: colors.count)
        return colors[index]
    }

    private static func stableIndex(for value: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}

#Preview {
    WatchContentView()
}
