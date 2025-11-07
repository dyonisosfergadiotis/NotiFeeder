import Combine
import SwiftUI

struct AppVersion {
    static let current = "1.2"
}

final class ReleaseNotesManager: ObservableObject {
    @AppStorage("lastLaunchedVersion") private var lastLaunchedVersion: String = ""
    @Published var shouldShowWhatsNew: Bool = false

    init() {
        evaluate()
    }

    func evaluate() {
        if lastLaunchedVersion != AppVersion.current {
            shouldShowWhatsNew = true
            lastLaunchedVersion = AppVersion.current
        } else {
            shouldShowWhatsNew = false
        }
    }

    func dismiss() {
        shouldShowWhatsNew = false
    }
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "sparkles")
                        .imageScale(.large)
                        .foregroundStyle(.tint)
                    Text("Neu in Version 1.2")
                        .font(.title2).bold()
                }

                Group {
                    Label("Color Picker verbessert", systemImage: "eyedropper")
                    Label("Lesezeichen hinzugefügt", systemImage: "bookmark")
                    Label("UI minimalisiert", systemImage: "rectangle.dashed")
                }
                .font(.body)

                Spacer()

                Button {
                    onDismiss()
                    dismiss()
                } label: {
                    Text("Los geht's")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Was ist neu")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension View {
    /// Presents the What's New sheet once after an app update to a new version.
    func whatsNewOnUpdate(manager: ReleaseNotesManager) -> some View {
        modifier(WhatsNewPresenter(manager: manager))
    }
}

private struct WhatsNewPresenter: ViewModifier {
    @ObservedObject var manager: ReleaseNotesManager

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { manager.shouldShowWhatsNew }, set: { newVal in
                if !newVal { manager.dismiss() }
            })) {
                WhatsNewView { manager.dismiss() }
            }
    }
}

#Preview {
    ZStack {
        Color(.systemBackground)
        Text("App Inhalt")
    }
    .whatsNewOnUpdate(manager: ReleaseNotesManager())
}

