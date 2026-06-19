import SwiftUI
import UIKit
import WidgetKit

#if canImport(ActivityKit)
import ActivityKit

struct ReadingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReadingActivityAttributes.self) { context in
            ReadingLiveActivityLockScreenView(context: context)
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(ReadingLiveActivityURLBuilder.url(for: context.attributes.link))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ReadingLiveActivitySourceView(context: context)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    ReadingLiveActivityFeedBadge(context: context, size: 30)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            ReadingLiveActivityStatusBadge(
                                label: context.readingStatusLabel,
                                tint: context.accentColor,
                                isCompact: true
                            )

                            Spacer(minLength: 8)

                            Text(context.progressPercentageLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.72))
                                .monospacedDigit()
                        }

                        Text(context.attributes.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        ReadingLiveActivityProgressBar(
                            progress: context.state.readingProgress,
                            tint: context.accentColor,
                            height: 3
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "book.pages.fill")
                    .foregroundStyle(context.accentColor)
            } compactTrailing: {
                ReadingLiveActivityFeedBadge(context: context, size: 22)
            } minimal: {
                Image(systemName: "book.pages.fill")
                    .foregroundStyle(context.accentColor)
            }
            .widgetURL(ReadingLiveActivityURLBuilder.url(for: context.attributes.link))
        }
    }
}

private struct ReadingLiveActivityLockScreenView: View {
    let context: ActivityViewContext<ReadingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ReadingLiveActivityStatusBadge(
                    label: "Weiterlesen",
                    tint: context.accentColor,
                    isCompact: false
                )

                Spacer(minLength: 8)

                ReadingLiveActivityMetadataView(context: context)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ReadingLiveActivityArticleThumbnail(context: context)

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.sourceTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(context.accentColor)
                        .lineLimit(1)

                    Text(context.attributes.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                ReadingLiveActivityProgressBar(
                    progress: context.state.readingProgress,
                    tint: context.accentColor,
                    height: 4
                )

                Text(context.progressPercentageLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.74))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            ReadingLiveActivityEdgeFadeBackground(tint: context.accentColor)
        }
    }
}

private struct ReadingLiveActivityMetadataView: View {
    let context: ActivityViewContext<ReadingActivityAttributes>

    var body: some View {
        HStack(spacing: 5) {
            if let publishedDateLabel = context.publishedDateLabel {
                Text(publishedDateLabel)
                Text("·")
                    .foregroundStyle(.white.opacity(0.42))
            }

            Image(systemName: "eyeglasses")
                .font(.caption2.weight(.semibold))
                .imageScale(.small)

            Text(context.attributes.readingTimeLabel)
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(context.lockScreenMetadataAccessibilityLabel)
    }
}

private struct ReadingLiveActivitySourceView: View {
    let context: ActivityViewContext<ReadingActivityAttributes>

    var body: some View {
        Text(context.attributes.sourceTitle)
            .font(.caption.weight(.semibold))
            .foregroundStyle(context.accentColor)
            .lineLimit(1)
    }
}

private struct ReadingLiveActivityStatusBadge: View {
    let label: String
    let tint: Color
    let isCompact: Bool

    var body: some View {
        HStack(spacing: isCompact ? 4 : 5) {
            Image(systemName: "book.pages.fill")
                .font(isCompact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .imageScale(.small)

            Text(label)
                .font(isCompact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, isCompact ? 7 : 9)
        .padding(.vertical, isCompact ? 4 : 5)
        .background(tint.opacity(0.34), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.16), lineWidth: 0.8)
        }
    }
}

private struct ReadingLiveActivityArticleThumbnail: View {
    let context: ActivityViewContext<ReadingActivityAttributes>

    var body: some View {
        Group {
            if let thumbnailImage = context.thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
            } else if let thumbnailURL = context.thumbnailURL {
                AsyncImage(url: thumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        ReadingLiveActivityFeedIcon(context: context)
                    }
                }
            } else {
                ReadingLiveActivityFeedIcon(context: context)
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct ReadingLiveActivityFeedIcon: View {
    let context: ActivityViewContext<ReadingActivityAttributes>

    var body: some View {
        if let faviconURL = context.faviconURL {
            AsyncImage(url: faviconURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                        .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                default:
                    ReadingLiveActivityFeedBadge(context: context, size: 38)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            ReadingLiveActivityFeedBadge(context: context, size: 38)
        }
    }
}

private struct ReadingLiveActivityFeedBadge: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    let size: CGFloat

    var body: some View {
        Text(context.feedInitial)
            .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(context.accentColor.opacity(0.82), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
    }
}

private struct ReadingLiveActivityProgressBar: View {
    let progress: Double
    let tint: Color
    let height: CGFloat

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * clampedProgress)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Lesefortschritt")
        .accessibilityValue("\(Int((clampedProgress * 100).rounded())) Prozent")
    }
}

private struct ReadingLiveActivityEdgeFadeBackground: View {
    let tint: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.88),
                    Color.black.opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    tint.opacity(0.42),
                    tint.opacity(0.10),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private enum ReadingLiveActivityURLBuilder {
    static func url(for link: String) -> URL? {
        var components = URLComponents()
        components.scheme = "notifeeder"
        components.host = "article"
        components.queryItems = [
            URLQueryItem(name: "link", value: link)
        ]
        return components.url
    }
}

private extension ActivityViewContext where Attributes == ReadingActivityAttributes {
    var accentColor: Color {
        Color(hexString: attributes.feedColorHex) ?? .blue
    }

    var clampedReadingProgress: Double {
        min(1, max(0, state.readingProgress))
    }

    var progressPercentageLabel: String {
        "\(Int((clampedReadingProgress * 100).rounded())) %"
    }

    var readingStatusLabel: String {
        "Weiterlesen"
    }

    var faviconURL: URL? {
        attributes.faviconURLString.flatMap(URL.init(string:))
    }

    var thumbnailURL: URL? {
        attributes.thumbnailURLString.flatMap(URL.init(string:))
    }

    var thumbnailImage: UIImage? {
        guard let key = state.thumbnailBlobKey,
              let data = AppGroupBlobStore.data(forKey: key) else {
            return nil
        }
        return UIImage(data: data)
    }

    var feedInitial: String {
        attributes.sourceTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map { String($0).uppercased() } ?? "F"
    }

    var lockScreenMetadataAccessibilityLabel: String {
        let parts = [publishedDateLabel, "Lesezeit \(attributes.readingTimeLabel)"]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return parts.joined(separator: " · ")
    }

    var publishedDateLabel: String? {
        guard let publishedAt = attributes.publishedAt else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(publishedAt) {
            return publishedAt.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_DE")))
        }
        if calendar.isDateInYesterday(publishedAt) {
            return "gestern"
        }
        return DateFormatter.readingActivityDayMonth.string(from: publishedAt)
    }
}

private extension DateFormatter {
    static let readingActivityDayMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()
}

private extension Color {
    init?(hexString: String?) {
        guard let hexString else { return nil }
        let trimmed = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
#endif
