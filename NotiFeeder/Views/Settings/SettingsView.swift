import SwiftUI
import UIKit

enum UserProfileStore {
    static let displayNameKey = "profile.displayName"
    static let avatarImageDataKey = "profile.avatarImageData"

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

    static func normalizedAvatarData(from image: UIImage) -> Data? {
        let maxDimension: CGFloat = 1024
        let maxSide = max(image.size.width, image.size.height)
        let scale = maxSide > maxDimension ? (maxDimension / maxSide) : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}

struct SettingsView: View {
    @Binding var feeds: [FeedSource]
    @Binding var savedFeedsData: Data
    var onFeedsDidChange: () -> Void = {}
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage(UserProfileStore.displayNameKey) private var profileDisplayName: String = ""
    @AppStorage(UserProfileStore.avatarImageDataKey) private var profileAvatarData: Data = Data()
    @AppStorage("ui.cards.style.fullColor") private var fullColorCards: Bool = false
    @AppStorage(FeedStorage.Keys.offlineRetainedFetchedArticleLimit, store: FeedStorage.defaults)
    private var offlineRetainedFetchedArticleLimitRaw: Int = OfflineArticleRetentionLimit.defaultValue.rawValue

    var body: some View {
        NavigationStack {
            List {
                profileSection

                Section("Inhalte") {
                    SettingsNavigationRow(
                        icon: "dot.radiowaves.left.and.right",
                        iconTint: theme.uiAccentColor,
                        title: "Feeds",
                        subtitle: "\(feeds.count) gespeicherte Feeds"
                    ) {
                        FeedsSettingsView(
                            feeds: $feeds,
                            savedFeedsData: $savedFeedsData,
                            onFeedsDidChange: onFeedsDidChange
                        )
                            .environmentObject(theme)
                    }

                    SettingsNavigationRow(
                        icon: "arrow.down.circle",
                        iconTint: theme.uiAccentColor,
                        title: "Offline",
                        subtitle: "Neueste: \(offlineRetentionLimit.title)"
                    ) {
                        OfflineStorageSettingsView()
                            .environmentObject(theme)
                    }
                }

                Section("Darstellung") {
                    SettingsNavigationRow(
                        icon: "paintpalette",
                        iconTint: theme.uiAccentColor,
                        title: "Karten & Layout",
                        subtitle: fullColorCards ? "Vollflächige Kacheln aktiv" : "Standard-Karten aktiv"
                    ) {
                        PersonalizationViewPlaceholder()
                    }

                    SettingsNavigationRow(
                        icon: "square.grid.2x2",
                        iconTint: theme.uiAccentColor,
                        title: "Widgets",
                        subtitle: "Darstellung und Inhalte"
                    ) {
                        WidgetSettingsView()
                            .environmentObject(theme)
                    }
                }

                Section("App") {
                    SettingsNavigationRow(
                        icon: "info.circle",
                        iconTint: theme.uiAccentColor,
                        title: "App & Info",
                        subtitle: "Autor und Links"
                    ) {
                        InfoViewPlaceholder()
                    }
                }
            }
            .sheetCornerAlignedScrollContent()
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
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
        .onChange(of: fullColorCards) { _, newValue in
            FeedICloudSyncManager.shared.pushLocalPreferenceValue(newValue, for: FeedStorage.Keys.uiCardsStyleFullColor)
        }
    }

    private var displayName: String {
        let cleaned = UserProfileStore.sanitizedDisplayName(profileDisplayName)
        return cleaned.isEmpty ? "Profil einrichten" : cleaned
    }

    private var offlineRetentionLimit: OfflineArticleRetentionLimit {
        OfflineArticleRetentionLimit(rawValue: offlineRetainedFetchedArticleLimitRaw) ?? .defaultValue
    }

    private var profileSection: some View {
        Section {
            NavigationLink {
                ProfileNameEditorView()
            } label: {
                HStack(spacing: 14) {
                    ProfileAvatarBadge(name: displayName, imageData: profileAvatarData, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("Profilbild & Name")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
        }
    }
}

struct OfflineStorageSettingsView: View {
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage(FeedStorage.Keys.offlineRetainedFetchedArticleLimit, store: FeedStorage.defaults)
    private var offlineRetainedFetchedArticleLimitRaw: Int = OfflineArticleRetentionLimit.defaultValue.rawValue

    var body: some View {
        SettingsScaffold {
            SettingsSectionCard(title: "Offline speichern", spacing: 12) {
                HStack(spacing: 12) {
                    SettingsListIconBadge(systemName: "tray.and.arrow.down.fill", tint: theme.uiAccentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gefetchte Artikel")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text("Zusätzlich zu Ungelesenen und Lesezeichen")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Menu {
                        ForEach(OfflineArticleRetentionLimit.allCases) { limit in
                            Button {
                                offlineRetainedFetchedArticleLimitRaw = limit.rawValue
                            } label: {
                                HStack {
                                    Text(limit.title)
                                    if limit.rawValue == offlineRetainedFetchedArticleLimitRaw {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(currentOfflineRetentionLimit.title)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.uiAccentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(theme.uiAccentColor.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Text("Ungelesene Artikel und Lesezeichen bleiben zusätzlich offline verfügbar. Sobald ein Artikel gelesen und nicht mehr als Lesezeichen markiert ist, zählt wieder das Limit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Offline")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.uiAccentColor)
    }

    private var currentOfflineRetentionLimit: OfflineArticleRetentionLimit {
        OfflineArticleRetentionLimit(rawValue: offlineRetainedFetchedArticleLimitRaw) ?? .defaultValue
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
        AppHaptics.success()
        onSave(sanitizedDraft)
    }
}

private struct SettingsNavigationRow<Destination: View>: View {
    let icon: String
    let iconTint: Color
    let title: String
    let subtitle: String?
    private let destination: Destination

    init(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String? = nil,
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
                SettingsListIconBadge(systemName: icon, tint: iconTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
    }
}

struct ProfileNameEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeSettings
    @AppStorage(UserProfileStore.displayNameKey) private var profileDisplayName: String = ""
    @AppStorage(UserProfileStore.avatarImageDataKey) private var profileAvatarData: Data = Data()
    @State private var draftName: String = ""
    @State private var showAvatarSourceDialog = false
    @State private var imagePickerSource: AvatarImageSource?

    var body: some View {
        List {
            Section("Profilbild") {
                HStack(spacing: 14) {
                    Button {
                        AppHaptics.selection()
                        showAvatarSourceDialog = true
                    } label: {
                        ProfileAvatarBadge(name: effectiveDraftName, imageData: profileAvatarData, size: 64)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profilbild ändern")

                    VStack(alignment: .leading, spacing: 4) {
                        Text(effectiveDraftName)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("Tippe auf die Initialen, um ein Foto aufzunehmen oder ein Bild auszuwählen.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                TextField("Dein Name", text: $draftName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            } header: {
                Text("Name")
            } footer: {
                Text("Der Name erscheint oben in den Einstellungen.")
                    .font(.footnote)
            }
        }
        .sheetCornerAlignedScrollContent()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
        .navigationTitle("Profil")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.uiAccentColor)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Speichern", action: save)
                    .disabled(sanitizedDraft.isEmpty || sanitizedDraft == UserProfileStore.sanitizedDisplayName(profileDisplayName))
            }
        }
        .confirmationDialog("Profilbild", isPresented: $showAvatarSourceDialog) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Foto aufnehmen") {
                    AppHaptics.selection()
                    imagePickerSource = .camera
                }
            }

            Button("Bild auswählen") {
                AppHaptics.selection()
                imagePickerSource = .photoLibrary
            }

            if !profileAvatarData.isEmpty {
                Button("Profilbild entfernen", role: .destructive) {
                    AppHaptics.warning()
                    profileAvatarData = Data()
                }
            }
        }
        .sheet(item: $imagePickerSource) { source in
            ProfileImagePicker(
                sourceType: source.uiKitSourceType,
                allowsEditing: true
            ) { image in
                guard let image, let data = UserProfileStore.normalizedAvatarData(from: image) else { return }
                profileAvatarData = data
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
        AppHaptics.success()
        profileDisplayName = sanitizedDraft
        dismiss()
    }

    private enum AvatarImageSource: String, Identifiable {
        case camera
        case photoLibrary

        var id: String { rawValue }

        var uiKitSourceType: UIImagePickerController.SourceType {
            switch self {
            case .camera:
                return .camera
            case .photoLibrary:
                return .photoLibrary
            }
        }
    }
}

private struct ProfileImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let allowsEditing: Bool
    let onImagePicked: (UIImage?) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked, dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = sourceType
        controller.allowsEditing = allowsEditing
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onImagePicked: (UIImage?) -> Void
        private let dismissAction: DismissAction

        init(onImagePicked: @escaping (UIImage?) -> Void, dismiss: DismissAction) {
            self.onImagePicked = onImagePicked
            self.dismissAction = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onImagePicked(nil)
            dismissAction()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let edited = info[.editedImage] as? UIImage
            let original = info[.originalImage] as? UIImage
            onImagePicked(edited ?? original)
            dismissAction()
        }
    }
}

struct SettingsScaffold<Content: View>: View {
    @EnvironmentObject private var theme: ThemeSettings

    private let content: Content

    init(spacing: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        List {
            content
        }
        .sheetCornerAlignedScrollContent()
        .listStyle(.insetGrouped)
        .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
        .scrollContentBackground(.hidden)
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
        Section {
            if spacing == 0 {
                content
            } else {
                VStack(alignment: .leading, spacing: spacing) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } header: {
            if let title, !title.isEmpty {
                Text(title)
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var sectionHeadingColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.74) : Color.secondary.opacity(0.92)
    }
}

struct SettingsCardSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .background { cardBackground }
            .clipShape(cardShape)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    private var cardBackground: some View {
        cardShape
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
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

struct SettingsListIconBadge: View {
    let systemName: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint)
                .frame(width: 29, height: 29)

            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
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
                .font(.system(size: 15))
                .fontWeight(.light)
                .foregroundStyle(tint)
        }
    }
}

struct SettingsChromeBackground: View {
    let accent: Color

    var body: some View {
        Color(uiColor: .systemGroupedBackground)
    }
}

private struct ProfileAvatarBadge: View {
    let name: String
    let imageData: Data?
    let size: CGFloat

    var body: some View {
        ZStack {
            if let image = avatarImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: UIStylePolicy.Brand.iconGradientColors(),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if UserProfileStore.sanitizedDisplayName(name).isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.34))
                        .fontWeight(.light)
                        .foregroundStyle(.white.opacity(0.94))
                } else {
                    Text(UserProfileStore.initials(for: name))
                        .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var avatarImage: UIImage? {
        guard let imageData, !imageData.isEmpty else { return nil }
        return UIImage(data: imageData)
    }
}

extension FeedColorOption {
    static var palette: [FeedColorOption] { FeedColorOption.defaultPalette }
}
