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
    @AppStorage("ui.cards.style.fullColor") private var fullColorCards: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    profileSection

                    settingsSection(title: "Inhalte") {
                        SettingsNavigationRow(
                            icon: "dot.radiowaves.left.and.right",
                            iconTint: theme.uiAccentColor,
                            title: "Feeds verwalten",
                            subtitle: feedsSubtitle
                        ) {
                            FeedsSettingsViewPlaceholder()
                                .environmentObject(theme)
                        }
                    }

                    settingsSection(title: "Darstellung") {
                        SettingsNavigationRow(
                            icon: "paintpalette",
                            iconTint: theme.uiAccentColor,
                            title: "Karten & Layout",
                            subtitle: cardsSubtitle
                        ) {
                            PersonalizationViewPlaceholder()
                        }
                        sectionDivider
                        SettingsNavigationRow(
                            icon: "square.grid.2x2",
                            iconTint: theme.uiAccentColor,
                            title: "Widgets",
                            subtitle: "Homescreen-Hintergrund & Transparenz"
                        ) {
                            WidgetSettingsView()
                                .environmentObject(theme)
                        }
                    }

                    settingsSection(title: "App") {
                        SettingsNavigationRow(
                            icon: "info.circle",
                            iconTint: theme.uiAccentColor,
                            title: "App & Info",
                            subtitle: appVersionString
                        ) {
                            InfoViewPlaceholder()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .sheetCornerAlignedScrollContent()
            .scrollContentBackground(.hidden)
            .background(backgroundGradient.ignoresSafeArea())
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.large)
        }
        .tint(theme.uiAccentColor)
        .onChange(of: profileDisplayName) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(
                UserProfileStore.sanitizedDisplayName(newValue),
                for: FeedStorage.Keys.profileDisplayName
            )
        }
        .onChange(of: previewLines) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.uiCardsPreviewLines)
        }
        .onChange(of: fullColorCards) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.uiCardsStyleFullColor)
        }
    }

    private var displayName: String {
        let cleaned = UserProfileStore.sanitizedDisplayName(profileDisplayName)
        return cleaned.isEmpty ? "Profil einrichten" : cleaned
    }

    private var feedsSubtitle: String {
        feeds.count == 1 ? "1 Feed gespeichert" : "\(feeds.count) Feeds gespeichert"
    }

    private var cardsSubtitle: String {
        "\(previewSummary) · \(cardStyleSummary)"
    }

    private var previewSummary: String {
        previewLines == 0 ? "Nur Titel" : "\(previewLines) Zeilen Vorschau"
    }

    private var cardStyleSummary: String {
        fullColorCards ? "Farbige Karten" : "Dezente Karten"
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "Version \(version) (\(build))"
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profil")
                .appSectionLabel()
                .foregroundStyle(sectionHeadingColor)
                .padding(.leading, 6)

            NavigationLink {
                ProfileNameEditorView()
            } label: {
                HStack(spacing: 14) {
                    ProfileAvatarBadge(name: displayName, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .appTitle()
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(1)
                        Text("Profilbild & Name")
                            .appSecondary()
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
                .appSectionLabel()
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
            .fill(Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.42 : 0.65))
            .frame(height: 0.6)
            .padding(.leading, 56)
            .padding(.trailing, 14)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var cardBorder: some View {
        cardShape
            .stroke(Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.30 : 0.32), lineWidth: 0.8)
    }

    private var cardBackground: some View {
        cardShape
            .fill(colorScheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : Color(uiColor: .systemBackground))
            .overlay {
                cardShape.fill(
                    LinearGradient(
                        colors: [
                            theme.uiAccentColor.opacity(colorScheme == .dark ? 0.08 : 0.04),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
    }

    private var sectionHeadingColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.74) : Color.secondary.opacity(0.92)
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
            Color(uiColor: colorScheme == .dark ? .black : .systemGroupedBackground)

            LinearGradient(
                colors: UIStylePolicy.accentBackgroundColors(accent: theme.uiAccentColor, colorScheme: colorScheme),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(colorScheme == .dark ? 0.18 : 0.10)

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(colorScheme == .dark ? 0.06 : 0.08)
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconTint.opacity(colorScheme == .dark ? 0.16 : 0.10))
                        .frame(width: 30, height: 30)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconTint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .appTitle()
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.96) : Color.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .appSecondary()
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.60) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.40) : Color.secondary.opacity(0.9))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProfileNameEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage(UserProfileStore.displayNameKey) private var profileDisplayName: String = ""
    @State private var draftName: String = ""

    var body: some View {
        SettingsScaffold {
            SettingsSectionCard(title: "Profilbild") {
                HStack(spacing: 14) {
                    ProfileAvatarBadge(name: effectiveDraftName, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(effectiveDraftName)
                            .appTitle()
                            .foregroundStyle(primaryTextColor)
                        Text("Das Profilbild wird automatisch aus deinen Initialen erzeugt.")
                            .appSecondary()
                            .foregroundStyle(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            SettingsSectionCard(title: "Name") {
                Text("Der Name erscheint oben in den Einstellungen.")
                    .appSecondary()
                    .foregroundStyle(secondaryTextColor)

                TextField("Dein Name", text: $draftName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background {
                        inputShape
                            .fill(inputFillColor)
                    }
                    .overlay {
                        inputShape
                            .stroke(inputBorderColor, lineWidth: 1)
                    }
            }
        }
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.uiAccentColor)
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

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    private var inputFillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.035)
    }

    private var inputBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.96) : Color.primary
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.62) : Color.secondary
    }

    private func save() {
        guard !sanitizedDraft.isEmpty else { return }
        profileDisplayName = sanitizedDraft
        dismiss()
    }
}

struct SettingsScaffold<Content: View>: View {
    @EnvironmentObject private var theme: ThemeSettings

    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .sheetCornerAlignedScrollContent()
        .scrollContentBackground(.hidden)
        .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
    }
}

struct SettingsSectionCard<Content: View>: View {
    let title: String?
    let spacing: CGFloat
    private let content: Content

    init(title: String? = nil, spacing: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title)
                    .appSectionLabel()
                    .foregroundStyle(sectionHeadingColor)
                    .padding(.leading, 6)
            }

            SettingsCardSurface {
                VStack(alignment: .leading, spacing: spacing) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var sectionHeadingColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.74) : Color.secondary.opacity(0.92)
    }
}

struct SettingsCardSurface<Content: View>: View {
    @EnvironmentObject private var theme: ThemeSettings
    @Environment(\.colorScheme) private var colorScheme

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background { cardBackground }
            .overlay { cardBorder }
            .clipShape(cardShape)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var cardBorder: some View {
        cardShape
            .stroke(Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.30 : 0.32), lineWidth: 0.8)
    }

    private var cardBackground: some View {
        cardShape
            .fill(colorScheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground) : Color(uiColor: .systemBackground))
            .overlay {
                cardShape.fill(
                    LinearGradient(
                        colors: [
                            theme.uiAccentColor.opacity(colorScheme == .dark ? 0.08 : 0.04),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
    }
}

struct SettingsValuePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }
}

struct SettingsIconTile: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.11))
                .frame(width: 34, height: 34)

            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}

struct SettingsChromeBackground: View {
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: colorScheme == .dark ? .black : .systemGroupedBackground)

            LinearGradient(
                colors: UIStylePolicy.accentBackgroundColors(accent: accent, colorScheme: colorScheme),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(colorScheme == .dark ? 0.18 : 0.10)

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(colorScheme == .dark ? 0.06 : 0.08)
        }
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
