import PhotosUI
import SwiftUI
import UIKit
import WidgetKit

struct WidgetSettingsView: View {
    @EnvironmentObject private var theme: ThemeSettings
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(WidgetSettingsStore.transparentEnabledKey, store: WidgetSettingsStore.defaults)
    private var transparentEnabled: Bool = false
    @AppStorage(WidgetSettingsStore.iconSizeKey, store: WidgetSettingsStore.defaults)
    private var iconSizeSelection: String = WidgetSettingsStore.iconSizeSmall
    @AppStorage(WidgetSettingsStore.refreshTokenKey, store: WidgetSettingsStore.defaults)
    private var refreshToken: Double = 0

    @State private var selectedItem: PhotosPickerItem?
    @State private var backgroundImage: UIImage?
    @State private var isLoadingImage = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $transparentEnabled) {
                    HStack(spacing: 12) {
                        SettingsListIconBadge(systemName: "square.on.square.intersection.dashed", tint: theme.uiAccentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Transparenter Hintergrund")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text("Dein Widget übernimmt den Hintergrund von einem Homescreen-Screenshot.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tint(theme.uiAccentColor)
            }

            if transparentEnabled {
                Section {
                    PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                        screenshotPreview
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingImage)
                    .accessibilityLabel(backgroundImage == nil ? "Screenshot auswählen" : "Screenshot ersetzen")
                    .contextMenu {
                        if backgroundImage != nil {
                            Button(role: .destructive) {
                                AppHaptics.warning()
                                WidgetSettingsStore.clearBackground()
                                backgroundImage = nil
                                WidgetCenter.shared.reloadAllTimelines()
                            } label: {
                                Label("Screenshot entfernen", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Homescreen-Screenshot")
                } footer: {
                    Text("Screenshot ohne Widgets aufnehmen und das Vorschaufeld antippen. So bleibt das Cropping deckungsgleich.")
                        .font(.footnote)
                }

                Section {
                    Picker("Icon-Größe", selection: $iconSizeSelection) {
                        Text("Klein").tag(WidgetSettingsStore.iconSizeSmall)
                        Text("Groß").tag(WidgetSettingsStore.iconSizeLarge)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Home Screen Icons")
                } footer: {
                    Text("Die Transparenz hängt von der Icon-Größe ab. Die Auswahl hier muss deinem Homescreen entsprechen.")
                        .font(.footnote)
                }

                Section {
                    Button {
                        AppHaptics.success()
                        WidgetSettingsStore.touchRefreshToken()
                        refreshToken = Date().timeIntervalSince1970
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        actionButtonLabel(title: "Widgets neu laden", systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("Aktualisieren")
                } footer: {
                    Text("Nutze das, wenn Hintergrund oder Inhalte nicht sofort übernommen werden.")
                        .font(.footnote)
                }
            }
        }
        .sheetCornerAlignedScrollContent()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .tint(theme.uiAccentColor)
        .onAppear {
            backgroundImage = WidgetSettingsStore.loadBackground()
        }
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            isLoadingImage = true
            Task {
                let data = try? await newItem.loadTransferable(type: Data.self)
                let image = data.flatMap { UIImage(data: $0) }
                if let image {
                    WidgetSettingsStore.saveBackground(image)
                }
                await MainActor.run {
                    backgroundImage = image
                    if image != nil {
                        AppHaptics.success()
                    }
                    WidgetCenter.shared.reloadAllTimelines()
                    isLoadingImage = false
                }
            }
        }
        .onChange(of: transparentEnabled) {
            AppHaptics.selection()
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: iconSizeSelection) {
            AppHaptics.selection()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private var screenshotPreview: some View {
        Group {
            if let image = backgroundImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 164)
                    .clipShape(previewShape)
                    .overlay {
                        previewShape
                            .strokeBorder(previewBorderColor, lineWidth: 1)
                    }
            } else {
                previewShape
                    .fill(Color.secondary.opacity(UIStylePolicy.glassAccentOpacity))
                    .frame(height: 132)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.system(size: 22))
                                .fontWeight(.regular)
                                .foregroundStyle(theme.uiAccentColor)
                            Text(isLoadingImage ? "Lädt Screenshot…" : "Kein Screenshot ausgewählt")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
    }

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: UIStylePolicy.Radius.large, style: .continuous)
    }

    private var previewBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    private func actionButtonLabel(
        title: String,
        systemName: String,
        iconTint: Color? = nil,
        textColor: Color = .primary,
        showsChevron: Bool = true
    ) -> some View {
        HStack(spacing: 12) {
            SettingsListIconBadge(systemName: systemName, tint: iconTint ?? theme.uiAccentColor)
            Text(title)
                .font(.body)
                .foregroundStyle(textColor)
            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

private enum WidgetSettingsStore {
    static let suiteName = AppGroupDefaults.suiteName
    static let transparentEnabledKey = "nf_widget_transparent_enabled"
    static let iconSizeKey = "nf_widget_icon_size"
    static let iconSizeSmall = "small"
    static let iconSizeLarge = "large"
    static let refreshTokenKey = "nf_widget_refresh_token"

    static let defaults: UserDefaults = {
        AppGroupDefaults.defaults(suiteName: suiteName, fallback: .standard)
    }()

    static func backgroundKey() -> String {
        "nf_widget_bg_latest"
    }

    static func loadBackground() -> UIImage? {
        let key = backgroundKey()
        guard let data = AppGroupBlobStore.data(forKey: key) ?? defaults.data(forKey: key) else { return nil }
        return UIImage(data: data)
    }

    static func saveBackground(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.82) ?? image.pngData() else { return }
        let key = backgroundKey()
        AppGroupBlobStore.write(data, forKey: key)
        defaults.removeObject(forKey: key)
    }

    static func clearBackground() {
        let key = backgroundKey()
        defaults.removeObject(forKey: key)
        AppGroupBlobStore.remove(forKey: key)
    }

    static func touchRefreshToken() {
        defaults.set(Date().timeIntervalSince1970, forKey: refreshTokenKey)
    }
}
