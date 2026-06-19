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
    @Binding var mediaWidth: Double
    @Binding var feedColor: Color
    @State private var showsAdvancedTextOptions = false

    private var fontGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 110), spacing: 10)]
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
            Form {
                Section("Schriftgröße") {
                    VStack(alignment: .leading, spacing: 10) {
                        Slider(value: $fontScale, in: 0.75...1.5, step: 0.05) {
                            Text("Schriftgröße")
                        }
                        .tint(feedColor)
                        Text("\(Int(fontScale * 100)) %")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Ausrichtung") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Ausrichtung", selection: $textAlignment) {
                            Text("Links").tag("left")
                            Text("Zentriert").tag("center")
                            Text("Rechts").tag("right")
                            Text("Blocksatz").tag("justified")
                        }
                        .pickerStyle(.segmented)
                        .tint(UIStylePolicy.Brand.fallbackAccent)
                    }
                }

                Section("Schriftart") {
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

                Section {
                    DisclosureGroup("Weitere Textoptionen", isExpanded: $showsAdvancedTextOptions) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Zeilenhöhe")
                                Spacer()
                                Text(lineSpacingLabel)
                                    .foregroundStyle(.secondary)
                            }

                            Slider(value: $lineSpacing, in: 0.75...1.5, step: 0.05)
                                .tint(feedColor)
                                .accessibilityLabel("Zeilenhöhe")
                                .accessibilityValue(lineSpacingLabel)

                            Divider()

                            readerSlider(
                                title: "Absatzabstand",
                                value: $paragraphSpacing,
                                range: 0.35...1.25,
                                step: 0.05,
                                valueLabel: "\(Int(paragraphSpacing * 100)) %"
                            )

                            readerSlider(
                                title: "Textbreite",
                                value: $contentWidth,
                                range: 520...900,
                                step: 20,
                                valueLabel: contentWidth < 650 ? "Schmal" : contentWidth < 790 ? "Standard" : "Breit"
                            )

                            readerSlider(
                                title: "Mediengröße",
                                value: $mediaWidth,
                                range: 60...100,
                                step: 5,
                                valueLabel: "\(Int(mediaWidth)) %"
                            )
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .navigationTitle("Reader Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .sheetCornerAlignedScrollContent()
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func readerSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        valueLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueLabel)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .tint(feedColor)
                .accessibilityLabel(title)
                .accessibilityValue(valueLabel)
        }
    }
}
