import SwiftUI
import Foundation

struct ArticleCardView: View {
    let feedTitle: String
    let feedColor: Color
    let title: String
    let summary: String?
    let isRead: Bool
    let date: Date?
    let isBookmarked: Bool

    private var hasSummary: Bool {
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    private var formattedDate: String? {
        guard let date else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return DateFormatter.timeOnly.string(from: date)
        } else {
            return DateFormatter.dateOnly.string(from: date)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(feedTitle)
                        .appSectionLabel()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(feedColor.opacity(isRead ? 0.22 : 0.4), in: Capsule())
                        .foregroundStyle(Color.white.opacity(0.95))

                    Spacer()

                    HStack(spacing: 6) {
                        if isBookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundColor(feedColor)
                        }
                        if let formattedDate {
                            Text(formattedDate)
                                .appMeta()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .appTitle()
                        .foregroundStyle(isRead ? Color.primary.opacity(0.65) : Color.primary)

                    if hasSummary, let summary {
                        Text(summary)
                            .appSecondary()
                            .foregroundStyle(isRead ? Color.secondary.opacity(0.85) : Color.primary.opacity(0.75))
                            .lineLimit(3)
                    }
                }
                .padding(.leading, 10)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
    }
}
