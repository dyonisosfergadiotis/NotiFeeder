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
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(ReadingLiveActivityURLBuilder.url(for: context.attributes.link))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ReadingLiveActivityArticleThumbnail(context: context, size: 42)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentMargins(.leading, 2)
                .contentMargins(.trailing, 4)

                DynamicIslandExpandedRegion(.trailing) {
                    ReadingLiveActivityExpandedTrailingView(context: context)
                }
                .contentMargins(.leading, 6)

                DynamicIslandExpandedRegion(.center) {
                    ReadingLiveActivityExpandedCenterView(context: context)
                }
                .contentMargins(.horizontal, 6)

                DynamicIslandExpandedRegion(.bottom, priority: 1) {
                    ReadingLiveActivityExpandedBottomView(context: context)
                }
                .contentMargins(.top, 6)
            } compactLeading: {
                ReadingLiveActivityCompactThumbnail(context: context)
            } compactTrailing: {
                ReadingLiveActivityCompactProgressRing(context: context)
            } minimal: {
                ReadingLiveActivityCompactThumbnail(context: context)
            }
            .widgetURL(ReadingLiveActivityURLBuilder.url(for: context.attributes.link))
        }
    }
}

private struct ReadingLiveActivityCompactThumbnail: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    private let size: CGFloat = 22

    var body: some View {
        thumbnailContent
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.10), lineWidth: 1)
            }
            .frame(width: 24, height: 24)
            .accessibilityLabel("Artikelbild")
    }

    @ViewBuilder
    private var thumbnailContent: some View {
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
                    fallbackThumbnail
                }
            }
        } else if let faviconURL = context.faviconURL {
            AsyncImage(url: faviconURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                        .background(colorScheme == .dark ? .white.opacity(0.92) : .white)
                default:
                    fallbackThumbnail
                }
            }
        } else {
            fallbackThumbnail
        }
    }

    private var fallbackThumbnail: some View {
        ReadingLiveActivityFeedBadge(context: context, size: size)
    }
}

private struct ReadingLiveActivityCompactProgressRing: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        context.accentColor(for: colorScheme)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.14), lineWidth: 2.5)

            Circle()
                .trim(from: 0, to: context.clampedReadingProgress)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
        .padding(2)
        .frame(width: 22, height: 22)
        .accessibilityLabel("Lesefortschritt \(context.progressPercentageLabel)")
    }
}

private struct ReadingLiveActivityExpandedCenterView: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        context.accentColor(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.sourceTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)

            Text(context.attributes.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(WidgetTheme.primaryText(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReadingLiveActivityExpandedTrailingView: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(context.attributes.readingTimeLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(WidgetTheme.secondaryText(for: colorScheme))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(width: 42, alignment: .trailing)
    }
}

private struct ReadingLiveActivityExpandedBottomView: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        context.accentColor(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                ReadingLiveActivityStatusBadge(
                    label: context.readingStatusLabel,
                    tint: accent,
                    isCompact: true
                )
                .layoutPriority(1)

                Spacer(minLength: 8)
            }

            ReadingLiveActivityProgressBar(
                progress: context.state.readingProgress,
                tint: accent,
                height: 3
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReadingLiveActivityLockScreenView: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        context.accentColor(for: colorScheme)
    }

    private let thumbnailSize: CGFloat = 70

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ReadingLiveActivityArticleThumbnail(context: context, size: thumbnailSize)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(context.attributes.sourceTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .layoutPriority(1)

                    Spacer(minLength: 6)

                    ReadingLiveActivityMetadataView(context: context)
                }

                Spacer(minLength: 4)

                Text(context.attributes.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WidgetTheme.primaryText(for: colorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.86)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 6)

                ReadingLiveActivityProgressBar(
                    progress: context.state.readingProgress,
                    tint: accent,
                    height: 4
                )
            }
            .frame(height: thumbnailSize)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background {
            ReadingLiveActivityEdgeFadeBackground(tint: accent)
        }
    }
}

private struct ReadingLiveActivityMetadataView: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            if let publishedDateLabel = context.publishedDateLabel {
                Text(publishedDateLabel)
                Text("·")
                    .foregroundStyle(WidgetTheme.tertiaryText(for: colorScheme))
            }

            Image(systemName: "eyeglasses")
                .font(.caption2.weight(.semibold))
                .imageScale(.small)

            Text(context.attributes.readingTimeLabel)
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(WidgetTheme.secondaryText(for: colorScheme))
        .lineLimit(1)
        .multilineTextAlignment(.trailing)
        .accessibilityLabel(context.lockScreenMetadataAccessibilityLabel)
    }
}

private struct ReadingLiveActivityStatusBadge: View {
    let label: String
    let tint: Color
    let isCompact: Bool
    @Environment(\.colorScheme) private var colorScheme

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
        .background(tint.opacity(colorScheme == .dark ? 0.34 : 0.88), in: Capsule())
        .overlay {
            Capsule()
                .stroke(colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.08), lineWidth: 0.8)
        }
    }
}

private struct ReadingLiveActivityArticleThumbnail: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    var size: CGFloat = 58
    var showsProgressOutline: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    private var cornerRadius: CGFloat {
        max(9, size * 0.2)
    }

    private var progressInset: CGFloat {
        showsProgressOutline ? 1.5 : 0
    }

    var body: some View {
        thumbnailContent
            .frame(width: size, height: size)
            .clipShape(thumbnailShape)
            .overlay {
                thumbnailShape
                    .strokeBorder(colorScheme == .dark ? .white.opacity(0.18) : .black.opacity(0.10), lineWidth: 1)
            }
            .overlay {
                if showsProgressOutline {
                    thumbnailShape
                        .inset(by: progressInset)
                        .trim(from: 0, to: context.clampedReadingProgress)
                        .stroke(
                            context.accentColor(for: colorScheme),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.25), value: context.clampedReadingProgress)
                }
            }
    }

    private var thumbnailShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    private var thumbnailContent: some View {
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
}

private struct ReadingLiveActivityFeedIcon: View {
    let context: ActivityViewContext<ReadingActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let faviconURL = context.faviconURL {
            AsyncImage(url: faviconURL) { phase in
                switch phase {
                case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                        .background(colorScheme == .dark ? .white.opacity(0.92) : .white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(context.feedInitial)
            .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(context.accentColor(for: colorScheme).opacity(colorScheme == .dark ? 0.82 : 0.95), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .stroke(colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.08), lineWidth: 1)
            }
    }
}

private struct ReadingLiveActivityProgressBar: View {
    let progress: Double
    let tint: Color
    let height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12))
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: backgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    tint.opacity(colorScheme == .dark ? 0.42 : 0.20),
                    tint.opacity(colorScheme == .dark ? 0.10 : 0.08),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var backgroundColors: [Color] {
        colorScheme == .dark
        ? [Color.black.opacity(0.88), Color.black.opacity(0.72)]
        : [Color.white.opacity(0.96), Color.white.opacity(0.88)]
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
        Color(hexString: attributes.feedColorHex) ?? WidgetTheme.accent(for: .dark)
    }

    func accentColor(for colorScheme: ColorScheme) -> Color {
        if let feedColorHex = attributes.feedColorHex {
            return FeedColorOption.resolvedColor(for: feedColorHex, colorScheme: colorScheme)
        }
        return WidgetTheme.accent(for: colorScheme)
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
