import SwiftUI

enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case modern
    case serif
    case rounded
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modern: return "Modern"
        case .serif: return "Serif"
        case .rounded: return "Rund"
        case .mono: return "Mono"
        }
    }

    var cssValue: String {
        switch self {
        case .modern:
            return "'Avenir Next', 'Segoe UI', 'Helvetica Neue', sans-serif"
        case .serif:
            return "'Times New Roman', Georgia, serif"
        case .rounded:
            return "'SF Pro Rounded', 'SF Pro', -apple-system, sans-serif"
        case .mono:
            return "'SFMono-Regular', Menlo, monospace"
        }
    }

    var fontDesign: Font.Design {
        switch self {
        case .serif: return .serif
        case .rounded: return .rounded
        case .mono: return .monospaced
        case .modern: return .rounded
        }
    }
}

struct ReaderSettingsPanel: View {
    @Binding var textAlignment: String
    @Binding var fontScale: Double
    @Binding var fontFamily: String
    @Binding var lineSpacing: Double
    @Binding var paragraphSpacing: Double
    @Binding var contentWidth: Double
    @Binding var feedColor: Color

    private var fontGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 110), spacing: 10)]
    }

    private var selectedContentWidthPreset: Binding<ReaderContentWidthPreset> {
        Binding {
            ReaderContentWidthPreset.nearest(to: contentWidth)
        } set: { preset in
            contentWidth = preset.rawValue
        }
    }

    private var fontScaleLabel: String {
        "\(Int(fontScale * 100)) %"
    }

    private var paragraphSpacingLabel: String {
        "\(Int(paragraphSpacing * 100)) %"
    }

    private var lineSpacingLabel: String {
        switch lineSpacing {
        case ..<1.3:
            return "Kompakt"
        case 1.3..<1.46:
            return "Standard"
        default:
            return "Weit"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ReaderSettingsGroup(title: "Grundlagen") {
                        readerSlider(
                            title: "Schriftgröße",
                            value: $fontScale,
                            range: 0.75...1.5,
                            step: 0.05,
                            valueLabel: fontScaleLabel
                        )

                        ReaderSegmentedControl(title: "Ausrichtung") {
                            Picker("Ausrichtung", selection: $textAlignment) {
                                Text("Links").tag("left")
                                Text("Mitte").tag("center")
                                Text("Rechts").tag("right")
                                Text("Block").tag("justified")
                            }
                        }
                    }

                    ReaderSettingsGroup(title: "Schriftart") {
                        LazyVGrid(columns: fontGridColumns, spacing: 10) {
                            ForEach(ReaderFontFamily.allCases) { option in
                                Button {
                                    fontFamily = option.rawValue
                                } label: {
                                    VStack(spacing: 6) {
                                        Text("Aa")
                                            .font(.system(size: 20, weight: .semibold, design: option.fontDesign))
                                            .foregroundStyle(.primary)
                                        Text(option.displayName)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .foregroundStyle(.primary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(fontFamily == option.rawValue ? feedColor : Color.secondary.opacity(0.45), lineWidth: fontFamily == option.rawValue ? 2 : 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    ReaderSettingsGroup(title: "Weitere Einstellungen") {
                        readerSlider(
                            title: "Zeilenhöhe",
                            value: $lineSpacing,
                            range: 0.75...1.5,
                            step: 0.05,
                            valueLabel: lineSpacingLabel
                        )

                        readerSlider(
                            title: "Absatzabstand",
                            value: $paragraphSpacing,
                            range: 0.35...1.25,
                            step: 0.05,
                            valueLabel: paragraphSpacingLabel
                        )

                        ReaderSegmentedControl(title: "Artikelbreite") {
                            Picker("Artikelbreite", selection: selectedContentWidthPreset) {
                                ForEach(ReaderContentWidthPreset.allCases) { preset in
                                    Text(preset.displayName).tag(preset)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .navigationTitle("Reader Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .sheetCornerAlignedScrollContent()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func readerSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(valueLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .tint(feedColor)
                .accessibilityLabel(title)
                .accessibilityValue(valueLabel)
        }
    }
}

private enum ReaderContentWidthPreset: Double, CaseIterable, Identifiable {
    case narrow = 600
    case standard = 720
    case wide = 860

    var id: Double { rawValue }

    var displayName: String {
        switch self {
        case .narrow: return "Schmal"
        case .standard: return "Standard"
        case .wide: return "Breit"
        }
    }

    static func nearest(to width: Double) -> ReaderContentWidthPreset {
        allCases.min { lhs, rhs in
            abs(lhs.rawValue - width) < abs(rhs.rawValue - width)
        } ?? .standard
    }
}

private struct ReaderSettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            VStack(spacing: 16) {
                content
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }
}

private struct ReaderSegmentedControl<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            content
                .pickerStyle(.segmented)
                .tint(UIStylePolicy.Brand.fallbackAccent)
        }
    }
}
