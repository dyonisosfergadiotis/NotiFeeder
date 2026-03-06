import SwiftUI

enum UserProfileStore {
    static let displayNameKey = "profile.displayName"

    static func sanitizedDisplayName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func initials(for value: String) -> String {
        let cleaned = sanitizedDisplayName(value)
        guard !cleaned.isEmpty else { return "?" }

        let words = cleaned.split(whereSeparator: { $0.isWhitespace })
        if words.count >= 2 {
            let first = words[0].prefix(1)
            let second = words[1].prefix(1)
            return "\(first)\(second)".uppercased()
        }
        return String(cleaned.prefix(2)).uppercased()
    }
}

struct SettingsView: View {
    @Binding var feeds: [FeedSource]
    @Binding var savedFeedsData: Data
    @EnvironmentObject private var theme: ThemeSettings
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(UserProfileStore.displayNameKey) private var profileDisplayName: String = ""
    @AppStorage("ui.cards.previewLines") private var previewLines: Int = 3

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    profileSection

                    settingsSection(title: "Inhalte") {
                        SettingsNavigationRow(
                            icon: "dot.radiowaves.left.and.right",
                            iconTint: theme.uiAccentColor,
                            title: "Feeds",
                            subtitle: feedsSubtitle
                        ) {
                            FeedsSettingsViewPlaceholder()
                                .environmentObject(theme)
                        }
                        sectionDivider
                        SettingsNavigationRow(
                            icon: "line.3.horizontal.decrease.circle",
                            iconTint: theme.uiAccentColor,
                            title: "Filter",
                            subtitle: "Ungelesen & Listenansicht"
                        ) {
                            FeedBehaviorSettingsView()
                        }
                    }

                    settingsSection(title: "Darstellung") {
                        SettingsNavigationRow(
                            icon: "paintpalette",
                            iconTint: theme.uiAccentColor,
                            title: "Kacheln",
                            subtitle: "\(previewLines) Zeilen · Kartenstil"
                        ) {
                            PersonalizationViewPlaceholder()
                        }
                    }

                    settingsSection(title: "Widgets") {
                        SettingsNavigationRow(
                            icon: "square.grid.2x2",
                            iconTint: theme.uiAccentColor,
                            title: "Hintergrund",
                            subtitle: "Transparenz & Position"
                        ) {
                            WidgetSettingsView()
                                .environmentObject(theme)
                        }
                    }

                    settingsSection(title: "Info") {
                        SettingsNavigationRow(
                            icon: "info.circle",
                            iconTint: theme.uiAccentColor,
                            title: "Über App & Dev",
                            subtitle: appVersionString
                        ) {
                            InfoViewPlaceholder()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .sheetCornerAlignedScrollContent()
            .scrollContentBackground(.hidden)
            .background(backgroundGradient.ignoresSafeArea())
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.large)
        }
        .tint(theme.uiAccentColor)
    }

    private var displayName: String {
        let cleaned = UserProfileStore.sanitizedDisplayName(profileDisplayName)
        return cleaned.isEmpty ? "Profil einrichten" : cleaned
    }

    private var feedsSubtitle: String {
        feeds.count == 1 ? "1 Feed gespeichert" : "\(feeds.count) Feeds gespeichert"
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "Version \(version) (\(build))"
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profil")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(sectionHeadingColor)
                .padding(.leading, 6)

            NavigationLink {
                ProfileNameEditorView()
            } label: {
                HStack(spacing: 14) {
                    ProfileAvatarBadge(name: displayName, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(1)
                        Text("Profilbild & Name")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(secondaryTextColor)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(chevronColor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background { cardBackground }
            .overlay {
                cardBorder
            }
            .clipShape(cardShape)
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(sectionHeadingColor)
                .padding(.leading, 6)

            VStack(spacing: 0) {
                content()
            }
            .padding(.vertical, 6)
            .background { cardBackground }
            .overlay {
                cardBorder
            }
            .clipShape(cardShape)
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.10))
            .frame(height: 1)
            .padding(.leading, 56)
            .padding(.trailing, 14)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
    }

    private var cardBorder: some View {
        cardShape
            .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 1)
    }

    private var cardBackground: some View {
        cardShape
            .fill(colorScheme == .dark ? Color.black.opacity(0.33) : Color.white.opacity(0.72))
            .overlay {
                cardShape.fill(
                    LinearGradient(
                        colors: [
                            theme.uiAccentColor.opacity(colorScheme == .dark ? 0.15 : 0.10),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
    }

    private var sectionHeadingColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.86) : Color.primary.opacity(0.82)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.96) : Color.primary
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.62) : Color.secondary
    }

    private var chevronColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.42) : Color.secondary.opacity(0.9)
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: UIStylePolicy.accentBackgroundColors(accent: theme.uiAccentColor, colorScheme: colorScheme),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    theme.uiAccentColor.opacity(colorScheme == .dark ? 0.08 : 0.06),
                    .clear,
                    colorScheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.22)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct FirstLaunchProfileSetupView: View {
    @FocusState private var focused: Bool
    @State private var draftName: String
    let onSave: (String) -> Void

    init(initialName: String = "", onSave: @escaping (String) -> Void) {
        self._draftName = State(initialValue: UserProfileStore.sanitizedDisplayName(initialName))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Wie sollen wir dich nennen?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("Der Name erscheint oben in den Einstellungen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Dein Name", text: $draftName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                Button(action: save) {
                    Text("Speichern")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sanitizedDraft.isEmpty)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focused = true
                }
            }
        }
    }

    private var sanitizedDraft: String {
        UserProfileStore.sanitizedDisplayName(draftName)
    }

    private func save() {
        guard !sanitizedDraft.isEmpty else { return }
        onSave(sanitizedDraft)
    }
}

private struct SettingsNavigationRow<Destination: View>: View {
    let icon: String
    let iconTint: Color
    let title: String
    let subtitle: String
    @Environment(\.colorScheme) private var colorScheme
    private let destination: Destination

    init(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String,
        @ViewBuilder destination: () -> Destination
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconTint.opacity(colorScheme == .dark ? 0.24 : 0.16))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.60) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.40) : Color.secondary.opacity(0.9))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProfileNameEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UserProfileStore.displayNameKey) private var profileDisplayName: String = ""
    @State private var draftName: String = ""

    var body: some View {
        Form {
            Section("Profilbild") {
                HStack(spacing: 14) {
                    ProfileAvatarBadge(name: effectiveDraftName, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(effectiveDraftName)
                            .font(.headline)
                        Text("Das Profilbild wird automatisch aus deinen Initialen erzeugt.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Name") {
                TextField("Dein Name", text: $draftName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            }
        }
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .sheetCornerAlignedScrollContent()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Speichern", action: save)
                    .disabled(sanitizedDraft.isEmpty || sanitizedDraft == UserProfileStore.sanitizedDisplayName(profileDisplayName))
            }
        }
        .onAppear {
            if draftName.isEmpty {
                draftName = UserProfileStore.sanitizedDisplayName(profileDisplayName)
            }
        }
    }

    private var sanitizedDraft: String {
        UserProfileStore.sanitizedDisplayName(draftName)
    }

    private var effectiveDraftName: String {
        sanitizedDraft.isEmpty ? "Profil einrichten" : sanitizedDraft
    }

    private func save() {
        guard !sanitizedDraft.isEmpty else { return }
        profileDisplayName = sanitizedDraft
        dismiss()
    }
}

private struct FeedBehaviorSettingsView: View {
    @AppStorage("feed.filter.unreadOnly", store: FeedStorage.defaults) private var unreadOnly: Bool = false
    @AppStorage("ui.cards.previewLines") private var previewLines: Int = 3

    var body: some View {
        Form {
            Section("Filter") {
                Toggle("Nur ungelesene Artikel anzeigen", isOn: $unreadOnly)
            }

            Section("Vorschau") {
                Stepper(value: $previewLines, in: 0...6) {
                    Text("Anzahl Vorschauzeilen: \(previewLines)")
                }
            }
        }
        .navigationTitle("Filter")
        .navigationBarTitleDisplayMode(.inline)
        .sheetCornerAlignedScrollContent()
    }
}

private struct ProfileAvatarBadge: View {
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.20, green: 0.52, blue: 0.93),
                            Color(red: 0.08, green: 0.27, blue: 0.52)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if UserProfileStore.sanitizedDisplayName(name).isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
            } else {
                Text(UserProfileStore.initials(for: name))
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
            }
        }
        .frame(width: size, height: size)
    }
}

extension FeedColorOption {
    static var palette: [FeedColorOption] { FeedColorOption.defaultPalette }
}

#Preview("Settings Light") {
    SettingsView(
        feeds: .constant([]),
        savedFeedsData: .constant(Data())
    )
    .environmentObject(ThemeSettings())
    .preferredColorScheme(.light)
}

#Preview("Settings Dark") {
    SettingsView(
        feeds: .constant([]),
        savedFeedsData: .constant(Data())
    )
    .environmentObject(ThemeSettings())
    .preferredColorScheme(.dark)
}
