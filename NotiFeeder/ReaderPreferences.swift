import SwiftUI

enum ReaderFontFamily: String, CaseIterable, Identifiable {
    case system
    case serif
    case rounded
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .serif: return "Serif"
        case .rounded: return "Rund"
        case .mono: return "Mono"
        }
    }

    var cssValue: String {
        switch self {
        case .system:
            return "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
        case .serif:
            return "'Times New Roman', Georgia, serif"
        case .rounded:
            return "'SF Pro Rounded', 'SF Pro', -apple-system, sans-serif"
        case .mono:
            return "'SFMono-Regular', Menlo, monospace"
        }
    }
}

struct ReaderSettingsPanel: View {
    @Binding var fontScale: Double
    @Binding var fontFamily: String
    @Binding var lineSpacing: Double
    @Environment(\.dismiss) private var dismiss

    private var displayedFont: ReaderFontFamily {
        ReaderFontFamily(rawValue: fontFamily) ?? .system
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

                Section(header: Text("Schriftart")) {
                    Picker("Schriftart", selection: $fontFamily) {
                        ForEach(ReaderFontFamily.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Zeilenabstand")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Slider(value: $lineSpacing, in: 1.2...2.0, step: 0.05) {
                            Text("Zeilenabstand")
                        }
                        Text(String(format: "%.1f", lineSpacing))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Vorschau")) {
                    Text("Schneller Fuchs rennt über faule Hunde.")
                        .font(.system(size: 18 * fontScale))
                        .fontDesign(fontDesign(for: displayedFont))
                        .lineSpacing(CGFloat((lineSpacing - 1) * 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle("Lesemodus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fontDesign(for option: ReaderFontFamily) -> Font.Design {
        switch option {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .mono: return .monospaced
        }
    }
}
