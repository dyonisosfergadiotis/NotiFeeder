import SwiftUI

struct WatchContentView: View {
    @StateObject private var store = WatchSyncStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    if store.entries.isEmpty {
                        emptyStateCard
                    } else {
                        ForEach(store.entries) { entry in
                            NavigationLink {
                                WatchArticleDetailView(entry: entry) {
                                    store.openOnPhone(link: entry.link)
                                }
                            } label: {
                                WatchArticleCard(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
            .navigationTitle("NotiFeeder")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
            }
            .refreshable {
                await store.requestRefresh()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 2) {
                    Text(store.lastRefreshText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let status = store.statusText, !status.isEmpty {
                        Text(status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.vertical, 4)
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "newspaper")
                .font(.title3)
                .fontWeight(.light)
                .foregroundStyle(.secondary)

            Text("Keine Artikel")
                .font(.headline)

            Text("Sobald das iPhone synchronisiert, erscheinen hier Artikel.")
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
    let openOnPhone: () -> Void

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

                Button("Auf iPhone öffnen") {
                    openOnPhone()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
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
        let index = abs(normalized.hashValue) % colors.count
        return colors[index]
    }
}

#Preview {
    WatchContentView()
}
