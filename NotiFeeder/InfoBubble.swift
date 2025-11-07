import Combine
import SwiftUI

final class DismissedHints: ObservableObject {
    static let shared = DismissedHints()

    @AppStorage("dismissedHintIDs") private var dismissedIDsData: Data = Data()
    @Published private(set) var dismissed: Set<String> = []

    private init() {
        load()
    }

    func isDismissed(_ id: String) -> Bool {
        dismissed.contains(id)
    }

    func dismiss(_ id: String) {
        guard !dismissed.contains(id) else { return }
        dismissed.insert(id)
        save()
        objectWillChange.send()
    }

    private func load() {
        if let set = try? JSONDecoder().decode(Set<String>.self, from: dismissedIDsData) {
            dismissed = set
        } else {
            dismissed = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(dismissed) {
            dismissedIDsData = data
        }
    }
}

struct InfoBubble<Content: View>: View {
    let id: String
    let content: Content
    @ObservedObject private var hints = DismissedHints.shared

    init(id: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.content = content()
    }

    var body: some View {
        Group {
            if !hints.isDismissed(id) {
                bubble
            }
        }
    }

    private var bubble: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.2))
            )

            Button(action: { hints.dismiss(id) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
                    .padding(6)
            }
            .accessibilityLabel(Text("Schließen"))
        }
    }
}

extension View {
    /// Conditionally shows an InfoBubble only if it hasn't been dismissed before.
    /// - Parameters:
    ///   - id: Stable identifier for this hint location.
    ///   - alignment: Where to overlay the bubble relative to this view.
    ///   - content: The bubble contents.
    /// - Returns: A view that overlays the bubble.
    func infoBubble(id: String, alignment: Alignment = .topTrailing, @ViewBuilder content: () -> some View) -> some View {
        overlay(
            InfoBubble(id: id, content: content)
                .padding(4),
            alignment: alignment
        )
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        Text("Einstellungen-Beispiel")
            .font(.headline)
            .infoBubble(id: "settings.header.tip") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tipp")
                        .font(.caption).bold()
                    Text("Hier kannst du das Erscheinungsbild deiner Feeds anpassen.")
                        .font(.caption)
                }
            }

        RoundedRectangle(cornerRadius: 8)
            .fill(Color.blue.opacity(0.1))
            .frame(height: 60)
            .overlay(Text("Ein anderes Element"))
            .infoBubble(id: "settings.other.tip", alignment: .topTrailing) {
                Text("Ziehe, um die Reihenfolge zu ändern.")
                    .font(.caption)
            }
    }
    .padding()
}

