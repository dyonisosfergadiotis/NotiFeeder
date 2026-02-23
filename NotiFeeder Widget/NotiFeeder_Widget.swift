//
//  NotiFeeder_Widget.swift
//  NotiFeeder Widget
//
//  Updated to display unread feed entries from app group cache.
//

import WidgetKit
import SwiftUI
import Foundation
import AppIntents
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Models for the Widget target

// MARK: - Position intent for selecting widget placement

enum WidgetGridPosition: String, CaseIterable, AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Widget Position"
    static var caseDisplayRepresentations: [WidgetGridPosition : DisplayRepresentation] = [
        .topLeft: DisplayRepresentation(stringLiteral: "Top Left"),
        .topRight: DisplayRepresentation(stringLiteral: "Top Right"),
        .middleLeft: DisplayRepresentation(stringLiteral: "Middle Left"),
        .middleRight: DisplayRepresentation(stringLiteral: "Middle Right"),
        .bottomLeft: DisplayRepresentation(stringLiteral: "Bottom Left"),
        .bottomRight: DisplayRepresentation(stringLiteral: "Bottom Right")
    ]

    case topLeft
    case topRight
    case middleLeft
    case middleRight
    case bottomLeft
    case bottomRight
}

enum SmallWidgetPosition: String, CaseIterable, AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Position (Klein)"
    static var caseDisplayRepresentations: [SmallWidgetPosition : DisplayRepresentation] = [
        .topLeft: "Oben Links",
        .topRight: "Oben Rechts",
        .middleLeft: "Mitte Links",
        .middleRight: "Mitte Rechts",
        .bottomLeft: "Unten Links",
        .bottomRight: "Unten Rechts"
    ]

    case topLeft
    case topRight
    case middleLeft
    case middleRight
    case bottomLeft
    case bottomRight
}

enum MediumWidgetPosition: String, CaseIterable, AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Position (Mittel)"
    static var caseDisplayRepresentations: [MediumWidgetPosition : DisplayRepresentation] = [
        .top: "Oben",
        .center: "Mitte",
        .bottom: "Unten"
    ]

    case top
    case center
    case bottom
}

enum LargeWidgetPosition: String, CaseIterable, AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Position (Groß)"
    static var caseDisplayRepresentations: [LargeWidgetPosition : DisplayRepresentation] = [
        .top: "Oben",
        .bottom: "Unten"
    ]

    case top
    case bottom
}

struct ChooseSmallWidgetPositionIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget Hintergrund (Klein)"
    static var description = IntentDescription("Wähle die Position für das transparente Widget-Hintergrund-Cropping (Klein).")

    @Parameter(title: "Position")
    var position: SmallWidgetPosition?

    static var parameterSummary: some ParameterSummary {
        Summary { \.$position }
    }
}

struct ChooseMediumWidgetPositionIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget Hintergrund (Mittel)"
    static var description = IntentDescription("Wähle die Position für das transparente Widget-Hintergrund-Cropping (Mittel).")

    @Parameter(title: "Position")
    var position: MediumWidgetPosition?

    static var parameterSummary: some ParameterSummary {
        Summary { \.$position }
    }
}

struct ChooseLargeWidgetPositionIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget Hintergrund (Groß)"
    static var description = IntentDescription("Wähle die Position für das transparente Widget-Hintergrund-Cropping (Groß).")

    @Parameter(title: "Position")
    var position: LargeWidgetPosition?

    static var parameterSummary: some ParameterSummary {
        Summary { \.$position }
    }
}

struct WidgetUnreadItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let feedTitle: String
    let feedColor: Color?
    let date: Date
    let imageURL: URL?
    let link: String
    let preview: String? // Added preview property
}

struct WidgetEntry: TimelineEntry {
    let date: Date
    let items: [WidgetUnreadItem]
    let accent: Color
    let background: Image?
    let position: WidgetGridPosition?
}

private enum WidgetAppearance {
    static let suiteName = "group.notiFeeder"
    static let transparentEnabledKey = "nf_widget_transparent_enabled"
    static let accentHexKey = "uiAccentHex"
    static let iconSizeKey = "nf_widget_icon_size"
    static let iconSizeSmall = "small"
    static let iconSizeLarge = "large"
    static let offsetXKey = "nf_widget_offset_x"
    static let offsetYKey = "nf_widget_offset_y"
    static let refreshTokenKey = "nf_widget_refresh_token"
    static let verticalBiasKey = "nf_widget_vertical_bias"

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func isTransparentEnabled() -> Bool {
        defaults().bool(forKey: transparentEnabledKey)
    }

    static func accentColor() -> Color {
        if let hex = defaults().string(forKey: accentHexKey), !hex.isEmpty {
            return Color.fromHex(hex)
        }
        return .accentColor
    }

    static func backgroundKey() -> String {
        "nf_widget_bg_latest"
    }

    static func iconSizeMode() -> String {
        let value = defaults().string(forKey: iconSizeKey) ?? iconSizeSmall
        return (value == iconSizeLarge) ? iconSizeLarge : iconSizeSmall
    }

    static func offsetX() -> CGFloat {
        CGFloat(defaults().double(forKey: offsetXKey))
    }

    static func offsetY() -> CGFloat {
        CGFloat(defaults().double(forKey: offsetYKey))
    }

    static func refreshToken() -> Double {
        defaults().double(forKey: refreshTokenKey)
    }

    static func verticalBias() -> CGFloat {
        CGFloat(defaults().double(forKey: verticalBiasKey))
    }
}

private enum WidgetSizeCache {
    private static let cacheKey = "nf_widget_size_cache_v1"

    struct Size: Codable {
        let w: Double
        let h: Double
    }

    struct Snapshot: Codable {
        var small: Size?
        var medium: Size?
        var large: Size?
    }

    static func load() -> Snapshot {
        let defaults = WidgetAppearance.defaults()
        guard let data = defaults.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return Snapshot()
        }
        return decoded
    }

    static func update(family: WidgetFamily, displaySize: CGSize) {
        guard displaySize.width > 0, displaySize.height > 0 else { return }
        var snapshot = load()
        let size = Size(w: Double(displaySize.width), h: Double(displaySize.height))
        switch family {
        case .systemSmall:
            snapshot.small = size
        case .systemMedium:
            snapshot.medium = size
        case .systemLarge:
            snapshot.large = size
        default:
            break
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            WidgetAppearance.defaults().set(data, forKey: cacheKey)
        }
    }
}

private struct WidgetFeedEntryCache: Codable {
    let title: String
    let link: String
    let content: String?
    let author: String?
    let sourceTitle: String?
    let feedURL: String?
    let pubDateString: String
    let imageURL: String?
    let isRead: Bool

    static func decode(from data: Data) -> [WidgetFeedEntryCache]? {
        let decoder = JSONDecoder()
        return try? decoder.decode([WidgetFeedEntryCache].self, from: data)
    }
}

private extension Date {
    /// Parses pubDateString with minimal logic (ISO8601 and RFC822)
    init?(rssDateString: String) {
        // Try ISO8601
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: rssDateString) {
            self = date
            return
        }
        // Try RFC822 formats
        let rfc822Formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm zzz",
            "dd MMM yyyy HH:mm zzz"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in rfc822Formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: rssDateString) {
                self = date
                return
            }
        }
        return nil
    }
}

// MARK: - Helper HTMLText

private enum HTMLText {
    static func stripHTML(_ htmlString: String?) -> String? {
        guard let htmlString = htmlString else { return nil }
        guard let data = htmlString.data(using: .utf8) else { return htmlString }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return htmlString
    }
}

// MARK: - Provider

private struct WidgetCore {
    static let suiteName = "group.notiFeeder"

    static func loadEntry(for family: WidgetFamily, position: WidgetGridPosition, displaySize: CGSize? = nil) -> WidgetEntry {
        let defaults = UserDefaults(suiteName: suiteName) ?? UserDefaults.standard

        if let displaySize {
            WidgetSizeCache.update(family: family, displaySize: displaySize)
        }

        var cachedEntries: [WidgetFeedEntryCache] = []
        if let data = defaults.data(forKey: "cachedEntries"), let decoded = WidgetFeedEntryCache.decode(from: data) {
            cachedEntries = decoded
        }

        let sorted = cachedEntries.sorted { lhs, rhs in
            let ld = Date(rssDateString: lhs.pubDateString) ?? .distantPast
            let rd = Date(rssDateString: rhs.pubDateString) ?? .distantPast
            return ld > rd
        }

        let maxCount: Int
        switch family {
        case .systemSmall: maxCount = 1
        case .systemMedium: maxCount = 2
        case .systemLarge: maxCount = 5
        default: maxCount = 2
        }

        let unread = sorted.filter { !$0.isRead }
        let selected = (unread.isEmpty ? sorted : unread).prefix(maxCount)

        let backgroundImage = WidgetAppearance.isTransparentEnabled() ? loadBackgroundImage(for: family, position: position) : nil

        var items: [WidgetUnreadItem] = selected.map { entry in
            let date = Date(rssDateString: entry.pubDateString) ?? Date()
            let url: URL?
            if family == .systemSmall {
                url = nil
            } else if let s = entry.imageURL, let u = URL(string: s) {
                url = u
            } else {
                url = nil
            }
            return WidgetUnreadItem(
                id: UUID(),
                title: entry.title,
                feedTitle: entry.sourceTitle ?? "",
                feedColor: feedColor(for: entry.sourceTitle),
                date: date,
                imageURL: url,
                link: entry.link,
                preview: HTMLText.stripHTML(entry.content)
            )
        }

        if items.count < maxCount {
            let paddingCount = maxCount - items.count
            let emptyItems: [WidgetUnreadItem] = (0..<paddingCount).map { _ in
                WidgetUnreadItem(id: UUID(), title: "", feedTitle: "", feedColor: nil, date: Date(), imageURL: nil, link: "", preview: nil)
            }
            items.append(contentsOf: emptyItems)
        }

        let refreshToken = WidgetAppearance.refreshToken()
        return WidgetEntry(date: Date().addingTimeInterval(refreshToken.truncatingRemainder(dividingBy: 1)), items: items, accent: WidgetAppearance.accentColor(), background: backgroundImage, position: position)
    }

    static func feedColor(for title: String?) -> Color? {
        guard let title = title, !title.isEmpty else { return nil }
        let options = FeedColorOption.defaultPalette
        let index = abs(title.hashValue) % options.count
        return options[index].color
    }

    #if canImport(UIKit)
    static func loadBackgroundImage(for family: WidgetFamily, position: WidgetGridPosition) -> Image? {
        let defaults = WidgetAppearance.defaults()
        let key = WidgetAppearance.backgroundKey()
        guard let data = defaults.data(forKey: key), let uiImage = UIImage(data: data) else { return nil }
        let cropped = crop(image: uiImage, for: family, position: position)
        return Image(uiImage: cropped ?? uiImage)
    }

    static func crop(image: UIImage, for family: WidgetFamily, position: WidgetGridPosition) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let isLandscape = pixelWidth > pixelHeight
        let width = isLandscape ? pixelHeight : pixelWidth
        let height = isLandscape ? pixelWidth : pixelHeight

        let iconSizeMode = WidgetAppearance.iconSizeMode()
        let layout = WidgetCropper.layout(for: CGSize(width: width, height: height), iconSizeMode: iconSizeMode)
        let userOffsetX = WidgetAppearance.offsetX()
        let userOffsetY = WidgetAppearance.offsetY()

        let scaled = WidgetCropper.scaledLayout(layout, target: CGSize(width: width, height: height))

        let cropRect = WidgetCropper.cropRect(
            for: family,
            position: position,
            layout: scaled,
            offset: CGSize(width: userOffsetX * scaled.scaleX, height: userOffsetY * scaled.scaleY)
        )

        guard let cropped = cgImage.cropping(to: cropRect.integral) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
    #else
    static func deviceKey() -> String { "default" }
    static func loadBackgroundImage(for family: WidgetFamily, position: WidgetGridPosition) -> Image? { nil }
    #endif
}

private struct WidgetCropper {
    struct Layout {
        let screen: CGSize
        let small: CGFloat
        let medium: CGFloat
        let large: CGFloat
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let middle: CGFloat
        let bottom: CGFloat
    }

    struct ScaledLayout {
        let screen: CGSize
        let smallWidth: CGFloat
        let smallHeight: CGFloat
        let mediumWidth: CGFloat
        let largeHeight: CGFloat
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let middle: CGFloat
        let bottom: CGFloat
        let scaleX: CGFloat
        let scaleY: CGFloat
    }

    private struct BaseValues {
        let small: CGFloat
        let medium: CGFloat
        let large: CGFloat
        let left: CGFloat
        let right: CGFloat
        let top: CGFloat
        let middle: CGFloat
        let bottom: CGFloat
    }

    static func layout(for size: CGSize, iconSizeMode: String) -> Layout {
        let base = baseValues(iconSizeMode: iconSizeMode)
        let heightKey = Int(size.height.rounded())
        if let exact = base[heightKey] {
            return Layout(
                screen: size,
                small: exact.small,
                medium: exact.medium,
                large: exact.large,
                left: exact.left,
                right: exact.right,
                top: exact.top,
                middle: exact.middle,
                bottom: exact.bottom
            )
        }
        if let dynamic = dynamicLayout(for: size, iconSizeMode: iconSizeMode) {
            return dynamic
        }
        // Fallback: choose the closest aspect ratio base
        let targetRatio = size.height / max(size.width, 1)
        let nearest = base.min { lhs, rhs in
            let lhsRatio = CGFloat(lhs.key) / max(size.width, 1)
            let rhsRatio = CGFloat(rhs.key) / max(size.width, 1)
            return abs(lhsRatio - targetRatio) < abs(rhsRatio - targetRatio)
        }
        if let fallback = nearest?.value {
            return Layout(
                screen: size,
                small: fallback.small,
                medium: fallback.medium,
                large: fallback.large,
                left: fallback.left,
                right: fallback.right,
                top: fallback.top,
                middle: fallback.middle,
                bottom: fallback.bottom
            )
        }
        let defaultValues = base[2532] ?? BaseValues(small: 474, medium: 1014, large: 1062, left: 78, right: 618, top: 231, middle: 819, bottom: 1407)
        return Layout(
            screen: size,
            small: defaultValues.small,
            medium: defaultValues.medium,
            large: defaultValues.large,
            left: defaultValues.left,
            right: defaultValues.right,
            top: defaultValues.top,
            middle: defaultValues.middle,
            bottom: defaultValues.bottom
        )
    }

    #if canImport(UIKit)
    private static func topMarginRatio(for iconSizeMode: String,
                                       screenPixels: CGSize,
                                       gridHeightPt: CGFloat) -> CGFloat {
        // Start with a sensible default for modern iPhones with notch
        var initial: CGFloat = 0.245

        let base = baseValues(iconSizeMode: iconSizeMode)
        let targetHeight = Int(screenPixels.height.rounded())
        let nearestHeight = base.keys.min { abs($0 - targetHeight) < abs($1 - targetHeight) }

        if let nearestHeight, let b = base[nearestHeight] {
            let baseSpacing = b.large - (2 * b.small)
            let baseGridHeight = (3 * b.small) + (2 * baseSpacing)
            let baseTotalMargin = max(1, CGFloat(nearestHeight) - baseGridHeight)
            // How much of the vertical margins sits on top on the reference device
            initial = min(0.5, max(0.05, b.top / baseTotalMargin))
        } else {
            // Aspect-ratio fallback for unknown/new devices
            // Taller aspect ratios tend to have slightly smaller top ratios (more dock space at bottom).
            let aspect = max(1.0, screenPixels.height / max(screenPixels.width, 1))
            // Map typical iPhone aspects (~2.0 - 2.2) to a reasonable top ratio band.
            // 2.0 -> ~0.26, 2.16 -> ~0.22, clamp to [0.18, 0.32]
            let mapped = 0.30 - (aspect - 2.0) * 0.20
            initial = min(0.32, max(0.18, mapped))
        }

        // Bias towards more space at the bottom (dock area is visually larger than status bar)
        // The larger the screen (in pixels), the stronger the bias.
        let heightBias = min(1.0, max(0.0, (screenPixels.height - 2000) / 1200)) // ~0 on small, ~1 on tall
        let dockBias: CGFloat = 0.10 * heightBias // up to -10% towards bottom on tall devices
        var ratio = max(0.08, initial - dockBias)

        // Constrain ratio so that after splitting, the grid still fits above the dock with some cushion
        // Ensure at least 1/6 of the total vertical margin remains at the bottom
        ratio = min(ratio, 5.0/6.0)
        ratio = max(ratio, 1.0/10.0)

        return ratio
    }

    static func dynamicLayout(for screenPixels: CGSize, iconSizeMode: String) -> Layout? {
        let cache = WidgetSizeCache.load()
        let screenPoints = UIScreen.main.bounds.size
        let screenWidth = min(screenPoints.width, screenPoints.height)
        let screenHeight = max(screenPoints.width, screenPoints.height)
        guard screenWidth > 0, screenHeight > 0 else { return nil }

        let scaleX = screenPixels.width / screenWidth
        let scaleY = screenPixels.height / screenHeight

        let smallSize = cache.small
        let mediumSize = cache.medium
        let largeSize = cache.large

        // Derive small widget size in points
        let smallWidthPt: CGFloat
        let smallHeightPt: CGFloat

        if let smallSize {
            smallWidthPt = CGFloat(smallSize.w)
            smallHeightPt = CGFloat(smallSize.h)
        } else if let mediumSize {
            // Medium height equals small height.
            smallHeightPt = CGFloat(mediumSize.h)
            let margin = (screenWidth - CGFloat(mediumSize.w)) / 2
            let gutterX = max(0, margin)
            smallWidthPt = max(1, (CGFloat(mediumSize.w) - gutterX) / 2)
        } else if let largeSize {
            // Large width equals medium width.
            let margin = (screenWidth - CGFloat(largeSize.w)) / 2
            let gutterX = max(0, margin)
            smallWidthPt = max(1, (CGFloat(largeSize.w) - gutterX) / 2)
            // Fall back to a square small height.
            smallHeightPt = smallWidthPt
        } else {
            return nil
        }

        // Horizontal gutters and outer margins (left/right) in points
        let gutterXPt: CGFloat
        if smallSize != nil {
            // 3 gutters horizontally: left outer, middle, right outer
            gutterXPt = max(0, (screenWidth - (2 * smallWidthPt)) / 3)
        } else if let mediumSize {
            gutterXPt = max(0, (screenWidth - CGFloat(mediumSize.w)) / 2)
        } else if let largeSize {
            gutterXPt = max(0, (screenWidth - CGFloat(largeSize.w)) / 2)
        } else {
            return nil
        }

        // Large widget height in points
        let largeHeightPt: CGFloat
        if let largeSize {
            largeHeightPt = CGFloat(largeSize.h)
        } else {
            // Approximate: two small heights plus 1.5x horizontal gutter is a good fit for vertical spacing
            largeHeightPt = smallHeightPt * 2 + gutterXPt * 1.5
        }

        // Vertical gutter between rows in points
        let gutterYPt: CGFloat
        if largeHeightPt > 0 {
            gutterYPt = max(0, largeHeightPt - 2 * smallHeightPt)
        } else {
            gutterYPt = gutterXPt * 1.5
        }

        // Total grid height (3 rows of small with two vertical gutters)
        let gridHeightPt = (3 * smallHeightPt) + (2 * gutterYPt)

        // Remaining vertical margin (top + bottom safe areas)
        let totalMarginPt = max(0, screenHeight - gridHeightPt)

        // Try to derive top margin directly from the closest base profile
        let base = baseValues(iconSizeMode: iconSizeMode)
        let targetHeight = Int(screenPixels.height.rounded())
        let nearestHeight = base.keys.min { abs($0 - targetHeight) < abs($1 - targetHeight) }

        // Fallback using ratio if we can't derive a good base
        var topPt: CGFloat = totalMarginPt * topMarginRatio(for: iconSizeMode, screenPixels: screenPixels, gridHeightPt: gridHeightPt)

        if let nearestHeight, let b = base[nearestHeight], nearestHeight > 0 {
            // b.top is the y-origin of the top row on the reference device (in pixels).
            // Convert to a fraction of the reference height and apply to current screen height (in points).
            let topFraction = max(0.0, min(0.5, b.top / CGFloat(nearestHeight)))
            let derivedTopPt = topFraction * screenHeight
            // Blend slightly towards the derived value to reduce jumps between devices
            topPt = (derivedTopPt * 0.8) + (topPt * 0.2)
        }

        // Clamp with sensible safe areas for status bar (top) and dock (bottom)
        let minTopSafe: CGFloat = screenHeight >= 700 ? 24 : 12
        let minBottomSafe: CGFloat = screenHeight >= 700 ? 60 : 40
        let maxTopAllowed = max(0, screenHeight - gridHeightPt - minBottomSafe)
        topPt = min(max(topPt, minTopSafe), maxTopAllowed)

        // Nudge the grid slightly downward to better align with real homescreen start (status bar / notch)
        // Use a fraction of the vertical gutter and clamp to a reasonable range.
        let downAdjust = max(6, min(18, gutterYPt * 0.35))
        topPt = min(topPt + downAdjust, maxTopAllowed)

        // Apply user-tunable vertical bias (in points), positive values push the grid further down
        let userBiasPt = WidgetAppearance.verticalBias()
        topPt = min(max(topPt + userBiasPt, minTopSafe), maxTopAllowed)

        let middlePt = topPt + smallHeightPt + gutterYPt
        let bottomPt = topPt + 2 * (smallHeightPt + gutterYPt)

        // Horizontal positions in points
        let leftPt = gutterXPt
        let rightPt = leftPt + smallWidthPt + gutterXPt

        // Medium width equals two small widths plus one gutter
        let mediumWidthPt = (mediumSize.map { CGFloat($0.w) }) ?? (smallWidthPt * 2 + gutterXPt)

        return Layout(
            screen: screenPixels,
            small: smallWidthPt * scaleX,
            medium: mediumWidthPt * scaleX,
            large: largeHeightPt * scaleY,
            left: leftPt * scaleX,
            right: rightPt * scaleX,
            top: topPt * scaleY,
            middle: middlePt * scaleY,
            bottom: bottomPt * scaleY
        )
    }
    #else
    static func dynamicLayout(for screenPixels: CGSize, iconSizeMode: String) -> Layout? { nil }
    #endif

    static func scaledLayout(_ base: Layout, target: CGSize) -> ScaledLayout {
        let scaleX = target.width / max(base.screen.width, 1)
        let scaleY = target.height / max(base.screen.height, 1)
        return ScaledLayout(
            screen: target,
            smallWidth: base.small * scaleX,
            smallHeight: base.small * scaleY,
            mediumWidth: base.medium * scaleX,
            largeHeight: base.large * scaleY,
            left: base.left * scaleX,
            right: base.right * scaleX,
            top: base.top * scaleY,
            middle: base.middle * scaleY,
            bottom: base.bottom * scaleY,
            scaleX: scaleX,
            scaleY: scaleY
        )
    }

    static func cropRect(for family: WidgetFamily,
                         position: WidgetGridPosition,
                         layout: ScaledLayout,
                         offset: CGSize) -> CGRect {
        let xLeft = layout.left + offset.width
        let xRight = layout.right + offset.width
        let yTop = layout.top + offset.height
        let yMiddle = layout.middle + offset.height
        let yBottom = layout.bottom + offset.height

        let width: CGFloat
        let height: CGFloat
        let x: CGFloat
        let y: CGFloat

        switch family {
        case .systemSmall:
            width = layout.smallWidth
            height = layout.smallHeight
            switch position {
            case .topLeft: x = xLeft; y = yTop
            case .topRight: x = xRight; y = yTop
            case .middleLeft: x = xLeft; y = yMiddle
            case .middleRight: x = xRight; y = yMiddle
            case .bottomLeft: x = xLeft; y = yBottom
            case .bottomRight: x = xRight; y = yBottom
            }
        case .systemMedium:
            width = layout.mediumWidth
            height = layout.smallHeight
            x = xLeft
            switch position {
            case .topLeft, .topRight: y = yTop
            case .middleLeft, .middleRight: y = yMiddle
            case .bottomLeft, .bottomRight: y = yBottom
            }
        case .systemLarge:
            width = layout.mediumWidth
            height = layout.largeHeight
            x = xLeft
            switch position {
            case .topLeft, .topRight: y = yTop
            case .middleLeft, .middleRight: y = yMiddle
            case .bottomLeft, .bottomRight: y = yMiddle
            }
        default:
            width = layout.smallWidth
            height = layout.smallHeight
            x = xLeft
            y = yTop
        }

        let rect = CGRect(x: x, y: y, width: width, height: height)
        let bounds = CGRect(origin: .zero, size: layout.screen)
        return rect.intersection(bounds)
    }

    private static func baseValues(iconSizeMode: String) -> [Int: BaseValues] {
        let useNoText = (iconSizeMode == WidgetAppearance.iconSizeLarge)

        let v2868Text = BaseValues(small: 510, medium: 1092, large: 1146, left: 114, right: 696, top: 276, middle: 912, bottom: 1548)
        let v2868NoText = BaseValues(small: 530, medium: 1138, large: 1136, left: 91, right: 699, top: 276, middle: 882, bottom: 1488)

        let v2796Text = BaseValues(small: 510, medium: 1092, large: 1146, left: 98, right: 681, top: 252, middle: 888, bottom: 1524)
        let v2796NoText = BaseValues(small: 530, medium: 1139, large: 1136, left: 75, right: 684, top: 252, middle: 858, bottom: 1464)

        let v2622Text = BaseValues(small: 486, medium: 1032, large: 1098, left: 87, right: 633, top: 261, middle: 872, bottom: 1485)
        let v2622NoText = BaseValues(small: 495, medium: 1037, large: 1035, left: 84, right: 626, top: 270, middle: 810, bottom: 1350)

        let v2556Text = BaseValues(small: 474, medium: 1017, large: 1062, left: 81, right: 624, top: 240, middle: 828, bottom: 1416)
        let v2556NoText = BaseValues(small: 495, medium: 1047, large: 1047, left: 66, right: 618, top: 243, middle: 795, bottom: 1347)

        let v1334Text = BaseValues(small: 296, medium: 642, large: 648, left: 54, right: 400, top: 60, middle: 412, bottom: 764)
        let v1334NoText = BaseValues(small: 309, medium: 667, large: 667, left: 41, right: 399, top: 67, middle: 425, bottom: 783)

        let v2778 = BaseValues(small: 510, medium: 1092, large: 1146, left: 96, right: 678, top: 246, middle: 882, bottom: 1518)
        let v2688 = BaseValues(small: 507, medium: 1080, large: 1137, left: 81, right: 654, top: 228, middle: 858, bottom: 1488)
        let v2532 = BaseValues(small: 474, medium: 1014, large: 1062, left: 78, right: 618, top: 231, middle: 819, bottom: 1407)
        let v2436X = BaseValues(small: 465, medium: 987, large: 1035, left: 69, right: 591, top: 213, middle: 783, bottom: 1353)
        let v2436Mini = BaseValues(small: 465, medium: 987, large: 1035, left: 69, right: 591, top: 231, middle: 801, bottom: 1371)
        let v1792 = BaseValues(small: 338, medium: 720, large: 758, left: 55, right: 437, top: 159, middle: 579, bottom: 999)
        let v1624 = BaseValues(small: 310, medium: 658, large: 690, left: 46, right: 394, top: 142, middle: 522, bottom: 902)
        let v2208 = BaseValues(small: 471, medium: 1044, large: 1071, left: 99, right: 672, top: 114, middle: 696, bottom: 1278)
        let v2001 = BaseValues(small: 444, medium: 963, large: 972, left: 81, right: 600, top: 90, middle: 618, bottom: 1146)
        let v1136 = BaseValues(small: 282, medium: 584, large: 622, left: 30, right: 332, top: 59, middle: 399, bottom: 399)

        var values: [Int: BaseValues] = [
            2868: useNoText ? v2868NoText : v2868Text,
            2796: useNoText ? v2796NoText : v2796Text,
            2622: useNoText ? v2622NoText : v2622Text,
            2556: useNoText ? v2556NoText : v2556Text,
            2778: v2778,
            2688: v2688,
            2532: v2532,
            1792: v1792,
            1624: v1624,
            2208: v2208,
            2001: v2001,
            1334: useNoText ? v1334NoText : v1334Text,
            1136: v1136
        ]

        #if canImport(UIKit)
        let screenPoints = UIScreen.main.bounds.size
        let screenWidth = min(screenPoints.width, screenPoints.height)
        let isMini = screenWidth <= 360
        values[2436] = isMini ? v2436Mini : v2436X
        #else
        values[2436] = v2436X
        #endif

        return values
    }
}

struct SmallWidgetProvider: AppIntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = ChooseSmallWidgetPositionIntent

    func placeholder(in context: Context) -> WidgetEntry {
        let now = Date()
        let sampleItems: [WidgetUnreadItem] = [
            WidgetUnreadItem(id: UUID(), title: "Introducing Widgets in SwiftUI", feedTitle: "Swift Blog", feedColor: nil, date: now.addingTimeInterval(-3600), imageURL: nil, link: "https://swift.org/blog/widgets", preview: nil),
            WidgetUnreadItem(id: UUID(), title: "What's New in iOS", feedTitle: "Apple Newsroom", feedColor: nil, date: now.addingTimeInterval(-7200), imageURL: nil, link: "https://apple.com/news/ios", preview: nil)
        ]
        return WidgetEntry(date: now, items: sampleItems, accent: .accentColor, background: nil, position: .topLeft)
    }

    func snapshot(for configuration: ChooseSmallWidgetPositionIntent, in context: Context) async -> WidgetEntry {
        WidgetCore.loadEntry(for: context.family, position: map(configuration.position), displaySize: context.displaySize)
    }

    func timeline(for configuration: ChooseSmallWidgetPositionIntent, in context: Context) async -> Timeline<WidgetEntry> {
        let entry = WidgetCore.loadEntry(for: context.family, position: map(configuration.position), displaySize: context.displaySize)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func map(_ choice: SmallWidgetPosition?) -> WidgetGridPosition {
        switch choice {
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .middleLeft: return .middleLeft
        case .middleRight: return .middleRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        case nil: return .topLeft
        }
    }
}

struct MediumWidgetProvider: AppIntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = ChooseMediumWidgetPositionIntent

    func placeholder(in context: Context) -> WidgetEntry {
        let now = Date()
        let sampleItems: [WidgetUnreadItem] = [
            WidgetUnreadItem(id: UUID(), title: "Introducing Widgets in SwiftUI", feedTitle: "Swift Blog", feedColor: nil, date: now.addingTimeInterval(-3600), imageURL: nil, link: "https://swift.org/blog/widgets", preview: nil),
            WidgetUnreadItem(id: UUID(), title: "What's New in iOS", feedTitle: "Apple Newsroom", feedColor: nil, date: now.addingTimeInterval(-7200), imageURL: nil, link: "https://apple.com/news/ios", preview: nil)
        ]
        return WidgetEntry(date: now, items: sampleItems, accent: .accentColor, background: nil, position: .topLeft)
    }

    func snapshot(for configuration: ChooseMediumWidgetPositionIntent, in context: Context) async -> WidgetEntry {
        WidgetCore.loadEntry(for: context.family, position: map(configuration.position), displaySize: context.displaySize)
    }

    func timeline(for configuration: ChooseMediumWidgetPositionIntent, in context: Context) async -> Timeline<WidgetEntry> {
        let entry = WidgetCore.loadEntry(for: context.family, position: map(configuration.position), displaySize: context.displaySize)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func map(_ choice: MediumWidgetPosition?) -> WidgetGridPosition {
        switch choice {
        case .top: return .topLeft
        case .center: return .middleLeft
        case .bottom: return .bottomLeft
        case nil: return .topLeft
        }
    }
}

struct LargeWidgetProvider: AppIntentTimelineProvider {
    typealias Entry = WidgetEntry
    typealias Intent = ChooseLargeWidgetPositionIntent

    func placeholder(in context: Context) -> WidgetEntry {
        let now = Date()
        let sampleItems: [WidgetUnreadItem] = [
            WidgetUnreadItem(id: UUID(), title: "Introducing Widgets in SwiftUI", feedTitle: "Swift Blog", feedColor: nil, date: now.addingTimeInterval(-3600), imageURL: nil, link: "https://swift.org/blog/widgets", preview: nil),
            WidgetUnreadItem(id: UUID(), title: "What's New in iOS", feedTitle: "Apple Newsroom", feedColor: nil, date: now.addingTimeInterval(-7200), imageURL: nil, link: "https://apple.com/news/ios", preview: nil)
        ]
        return WidgetEntry(date: now, items: sampleItems, accent: .accentColor, background: nil, position: .topLeft)
    }

    func snapshot(for configuration: ChooseLargeWidgetPositionIntent, in context: Context) async -> WidgetEntry {
        WidgetCore.loadEntry(for: context.family, position: map(configuration.position), displaySize: context.displaySize)
    }

    func timeline(for configuration: ChooseLargeWidgetPositionIntent, in context: Context) async -> Timeline<WidgetEntry> {
        let entry = WidgetCore.loadEntry(for: context.family, position: map(configuration.position), displaySize: context.displaySize)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(nextUpdate))
    }

    private func map(_ choice: LargeWidgetPosition?) -> WidgetGridPosition {
        switch choice {
        case .top: return .topLeft
        case .bottom: return .bottomLeft
        case nil: return .topLeft
        }
    }
}

// MARK: - View

struct NotiFeeder_WidgetEntryView: View {
    var entry: WidgetEntry
    @Environment(\.widgetFamily) var family
    @Environment(\.colorScheme) private var colorScheme

    private func articleDeepLink(for link: String) -> URL? {
        guard !link.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "notifeeder"
        components.host = "article"
        components.queryItems = [
            URLQueryItem(name: "link", value: link)
        ]
        return components.url
    }

    // Returns nil for today, "gestern" for yesterday, else dd.MM
    private func displayDateLabel(_ date: Date) -> String? {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return nil }
        if cal.isDateInYesterday(date) { return "gestern" }
        return DateFormatter.dayMonth.string(from: date)
    }

    var body: some View {
        contentCard
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.widgetRenderingMode, .fullColor)
            .containerBackground(for: .widget) {
                backgroundView
            }
    }

    @ViewBuilder
    private var contentCard: some View {
        switch family {
        case .systemSmall:
            card {
                smallView
            }
        case .systemMedium, .systemLarge:
            card {
                largerView
            }
        default:
            card {
                smallView
            }
        }
    }

    private var smallView: some View {
        VStack(spacing: 8) {
            if let item = entry.items.first {
                if item.title.isEmpty && item.feedTitle.isEmpty {
                    // Placeholder: reserve vertical space subtly
                    Spacer(minLength: 8)
                    HStack { Text("") ; Spacer() ; Text("") }
                        .font(.caption2)
                        .opacity(0)
                } else {
                    if let url = articleDeepLink(for: item.link) {
                        Link(destination: url) { smallCardContent(item) }
                            .buttonStyle(.plain)
                    } else {
                        smallCardContent(item)
                    }
                }
            } else {
                // Fallback: no items at all
                Spacer(minLength: 8)
            }
        }
    }

    private var largerView: some View {
        VStack(alignment: .leading, spacing: family == .systemMedium ? 6 : 8) {
            ForEach(entry.items.indices, id: \.self) { index in
                let item = entry.items[index]
                let titleFont: Font = .subheadline
                let metaFont: Font = .caption2
                let rowSpacing: CGFloat = (family == .systemMedium) ? 3 : 4

                // Build row content
                let row = VStack(alignment: .leading, spacing: rowSpacing) {
                    if item.title.isEmpty && item.feedTitle.isEmpty {
                        // Placeholder row keeps spacing; render transparent texts to maintain height
                        Text("")
                            .font(titleFont)
                            .lineLimit(1)
                            .opacity(0)
                        Text("")
                            .font(metaFont)
                            .lineLimit(1)
                            .opacity(0)
                        Text("")
                            .font(metaFont)
                            .lineLimit(1)
                            .opacity(0)
                    } else {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title.isEmpty ? "Keine ungelesenen Artikel" : item.title)
                                .font(titleFont)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                                .shadow(color: useTransparentBackground ? Color.black.opacity(0.25) : .clear, radius: 1.2, x: 0, y: 1)
                            Spacer(minLength: 8)
                        }
                        
                        if let preview = item.preview, !preview.isEmpty {
                            Text(preview)
                                .font(metaFont)
                                .foregroundStyle(.secondary)
                                .shadow(color: useTransparentBackground ? Color.black.opacity(0.2) : .clear, radius: 1, x: 0, y: 1)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        } else {
                            Text(item.link)
                                .font(metaFont)
                                .foregroundStyle(.secondary)
                                .shadow(color: useTransparentBackground ? Color.black.opacity(0.2) : .clear, radius: 1, x: 0, y: 1)
                                .lineLimit(1)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.feedTitle)
                                .font(metaFont)
                                .foregroundStyle(.secondary)
                                .shadow(color: useTransparentBackground ? Color.black.opacity(0.2) : .clear, radius: 1, x: 0, y: 1)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            if Calendar.current.isDateInToday(item.date) {
                                Text(item.date, format: .dateTime.hour().minute().locale(Locale(identifier: "de_DE")))
                                    .font(metaFont)
                                    .foregroundStyle(.secondary)
                                    .shadow(color: useTransparentBackground ? Color.black.opacity(0.2) : .clear, radius: 1, x: 0, y: 1)
                                    .lineLimit(1)
                            } else if let label = displayDateLabel(item.date) {
                                Text(label)
                                    .font(metaFont)
                                    .foregroundStyle(.secondary)
                                    .shadow(color: useTransparentBackground ? Color.black.opacity(0.2) : .clear, radius: 1, x: 0, y: 1)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Wrap row in Link if possible
                if let url = articleDeepLink(for: item.link) {
                    Link(destination: url) { row }
                        .buttonStyle(.plain)
                } else {
                    row
                }

                if index != entry.items.count - 1 {
                    Rectangle()
                        .fill(Color.black.opacity(0.08))
                        .frame(height: 1)
                }
            }
        }
    }

    private var backgroundView: some View {
        Group {
            if useTransparentBackground, let image = entry.background {
                compensatedBackground(image)
            } else {
                LinearGradient(
                    colors: [
                        entry.accent.opacity(0.22),
                        entry.accent.opacity(0.55)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func compensatedBackground(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFill()
    }

    private var useTransparentBackground: Bool {
        entry.background != nil
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        let innerPadding: CGFloat = (family == .systemSmall) ? 10 : 12
        let outerPadding: CGFloat = (family == .systemSmall) ? 6 : 8

        if useTransparentBackground {
            content()
                .padding(innerPadding)
                .padding(outerPadding)
        } else {
            content()
                .padding(innerPadding)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.6) : Color.white.opacity(0.9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(entry.accent.opacity(0.35), lineWidth: 1)
                        )
                )
                .padding(outerPadding)
        }
    }

    private func smallCardContent(_ item: WidgetUnreadItem) -> some View {
        VStack(spacing: 6) {
            VStack(spacing: 2) {
                Text(item.title.isEmpty ? "Keine ungelesenen Artikel" : item.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .shadow(color: useTransparentBackground ? Color.black.opacity(0.25) : .clear, radius: 1.5, x: 0, y: 1)
                    .frame(maxWidth: .infinity, alignment: .center)

                if let preview = item.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .shadow(color: useTransparentBackground ? Color.black.opacity(0.2) : .clear, radius: 1, x: 0, y: 1)
                } else if item.title.isEmpty {
                    Text("Pull‑to‑Refresh in der App oder „Widgets neu laden“.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Text(item.feedTitle.isEmpty ? "NotiFeeder" : item.feedTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(item.feedColor ?? entry.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill((item.feedColor ?? entry.accent).opacity(0.15))
                    )
                Spacer(minLength: 6)
                if Calendar.current.isDateInToday(item.date) {
                    Text(item.date, format: .dateTime.hour().minute().locale(Locale(identifier: "de_DE")))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .shadow(color: useTransparentBackground ? Color.black.opacity(0.2) : .clear, radius: 1, x: 0, y: 1)
                } else if let label = displayDateLabel(item.date) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .shadow(color: useTransparentBackground ? Color.black.opacity(0.2) : .clear, radius: 1, x: 0, y: 1)
                }
            }
        }
    }
}

// MARK: - Widget

struct NotiFeeder_Widget_Small: Widget {
    let kind: String = "NotiFeeder_Widget_Small"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ChooseSmallWidgetPositionIntent.self, provider: SmallWidgetProvider()) { entry in
            NotiFeeder_WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("NotiFeeder (Klein)")
        .description("Zeigt ungelesene Einträge mit optional transparentem Hintergrund (Klein).")
        .supportedFamilies([.systemSmall])
    }
}

struct NotiFeeder_Widget_Medium: Widget {
    let kind: String = "NotiFeeder_Widget_Medium"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ChooseMediumWidgetPositionIntent.self, provider: MediumWidgetProvider()) { entry in
            NotiFeeder_WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("NotiFeeder (Mittel)")
        .description("Zeigt ungelesene Einträge mit optional transparentem Hintergrund (Mittel).")
        .supportedFamilies([.systemMedium])
    }
}

struct NotiFeeder_Widget_Large: Widget {
    let kind: String = "NotiFeeder_Widget_Large"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ChooseLargeWidgetPositionIntent.self, provider: LargeWidgetProvider()) { entry in
            NotiFeeder_WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("NotiFeeder (Groß)")
        .description("Zeigt ungelesene Einträge mit optional transparentem Hintergrund (Groß).")
        .supportedFamilies([.systemLarge])
    }
}

private extension DateFormatter {
    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM"
        return f
    }()
}

public extension Color {
     static func fromHex(_ hex: String) -> Color {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&int)

        let r, g, b: UInt64
        switch sanitized.count {
        case 6:
            r = (int >> 16) & 0xFF
            g = (int >> 8) & 0xFF
            b = int & 0xFF
        default:
            r = 128
            g = 128
            b = 128
        }

        return Color(.sRGB,
                     red: Double(r) / 255.0,
                     green: Double(g) / 255.0,
                     blue: Double(b) / 255.0,
                     opacity: 1.0)
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    NotiFeeder_Widget_Small()
} timeline: {
    WidgetEntry(
        date: Date(),
        items: [
            WidgetUnreadItem(id: UUID(), title: "Introducing Widgets in SwiftUI", feedTitle: "Swift Blog", feedColor: nil, date: Date().addingTimeInterval(-3600), imageURL: nil, link: "https://swift.org/blog/widgets", preview: nil),
            WidgetUnreadItem(id: UUID(), title: "What's New in iOS", feedTitle: "Apple Newsroom", feedColor: nil, date: Date().addingTimeInterval(-7200), imageURL: nil, link: "https://apple.com/news/ios", preview: nil)
        ],
        accent: .accentColor, background: nil, position: .topLeft
    )
}

#Preview(as: .systemMedium) {
    NotiFeeder_Widget_Medium()
} timeline: {
    WidgetEntry(
        date: Date(),
        items: [
            WidgetUnreadItem(id: UUID(), title: "Introducing Widgets in SwiftUI", feedTitle: "Swift Blog", feedColor: nil, date: Date().addingTimeInterval(-3600), imageURL: nil, link: "https://swift.org/blog/widgets", preview: nil),
            WidgetUnreadItem(id: UUID(), title: "What's New in iOS", feedTitle: "Apple Newsroom", feedColor: nil, date: Date().addingTimeInterval(-7200), imageURL: nil, link: "https://apple.com/news/ios", preview: nil)
        ],
        accent: .accentColor, background: nil, position: .topLeft
    )
}

#Preview(as: .systemLarge) {
    NotiFeeder_Widget_Large()
} timeline: {
    WidgetEntry(
        date: Date(),
        items: [
            WidgetUnreadItem(id: UUID(), title: "Introducing Widgets in SwiftUI", feedTitle: "Swift Blog", feedColor: nil, date: Date().addingTimeInterval(-3600), imageURL: nil, link: "https://swift.org/blog/widgets", preview: nil),
            WidgetUnreadItem(id: UUID(), title: "What's New in iOS", feedTitle: "Apple Newsroom", feedColor: nil, date: Date().addingTimeInterval(-7200), imageURL: nil, link: "https://apple.com/news/ios", preview: nil)
        ],
        accent: .accentColor, background: nil, position: .topLeft
    )
}
