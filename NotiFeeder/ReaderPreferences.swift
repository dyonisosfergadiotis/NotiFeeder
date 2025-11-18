import SwiftUI

enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case system
    case modern
    case serif
    case editorial
    case rounded
    case relaxed
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .modern: return "Modern"
        case .serif: return "Serif"
        case .editorial: return "Editorial"
        case .rounded: return "Rund"
        case .relaxed: return "Entspannt"
        case .mono: return "Mono"
        }
    }

    var cssValue: String {
        switch self {
        case .system:
            return "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
        case .modern:
            return "'Avenir Next', 'Segoe UI', 'Helvetica Neue', sans-serif"
        case .serif:
            return "'Times New Roman', Georgia, serif"
        case .editorial:
            return "'Palatino Linotype', 'Book Antiqua', serif"
        case .rounded:
            return "'SF Pro Rounded', 'SF Pro', -apple-system, sans-serif"
        case .relaxed:
            return "'Lora', 'Merriweather', 'Georgia', serif"
        case .mono:
            return "'SFMono-Regular', Menlo, monospace"
        }
    }

    var fontDesign: Font.Design {
        switch self {
        case .system, .modern: return .default
        case .serif, .editorial, .relaxed: return .serif
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
    }
}

struct ReaderSettingsPanel: View {
    @Binding var fontScale: Double
    @Binding var fontFamily: String
    @Binding var lineSpacing: Double

    private var fontGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 110), spacing: 10)]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Schriftgröße")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Slider(value: $fontScale, in: 0.85...1.5, step: 0.05) {
                            Text("Schriftgröße")
                        }
                        Text("\(Int(fontScale * 100)) %")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section(header: Text("Zeilenabstand")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Slider(value: $lineSpacing, in: 1.2...2.0, step: 0.05) {
                            Text("Zeilenabstand")
                        }
                        Text(String(format: "%.2f", lineSpacing))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Schriftart")) {
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
                                        .stroke(fontFamily == option.rawValue ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: fontFamily == option.rawValue ? 2 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                
            }
            .navigationTitle("Lesemodus")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }

}
