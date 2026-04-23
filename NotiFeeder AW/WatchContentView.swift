import SwiftUI

struct WatchContentView: View {
    @StateObject private var store = WatchSyncStore()

    var body: some View {
        NavigationStack {
            List(store.entries) { entry in
                NavigationLink {
                    WatchArticleDetailView(entry: entry) {
                        store.openOnPhone(link: entry.link)
                    }
                } label: {
                    WatchArticleRow(entry: entry)
                }
            }
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("Keine Artikel")
                        } icon: {
                            Image(systemName: "newspaper")
                                .fontWeight(.light)
                        }
                    } description: {
                        Text("Sobald das iPhone synchronisiert, erscheinen hier Artikel.")
                    }
                }
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
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.vertical, 4)
            }
        }
    }
}

private struct WatchArticleRow: View {
    let entry: WatchFeedEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.isRead ? Color.gray.opacity(0.35) : Color.green)
                    .frame(width: 6, height: 6)

                Text(entry.sourceTitle ?? "Feed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if !entry.relativeDateText.isEmpty {
                    Text(entry.relativeDateText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.displayTitle)
                .font(.body)
                .lineLimit(3)
                .foregroundStyle(entry.isRead ? .secondary : .primary)
        }
        .padding(.vertical, 2)
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
                    Text(entry.sourceTitle ?? "Feed")
                    if !entry.relativeDateText.isEmpty {
                        Text("•")
                        Text(entry.relativeDateText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !entry.content.isEmpty {
                    Text(entry.content)
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

#Preview {
    WatchContentView()
}
