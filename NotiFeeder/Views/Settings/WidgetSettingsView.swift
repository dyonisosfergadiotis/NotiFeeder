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
    @AppStorage(WidgetSettingsStore.offsetXKey, store: WidgetSettingsStore.defaults)
    private var offsetX: Double = 0
    @AppStorage(WidgetSettingsStore.offsetYKey, store: WidgetSettingsStore.defaults)
    private var offsetY: Double = 0
    @AppStorage(WidgetSettingsStore.refreshTokenKey, store: WidgetSettingsStore.defaults)
    private var refreshToken: Double = 0

    @State private var selectedItem: PhotosPickerItem?
    @State private var backgroundImage: UIImage?
    @State private var isLoadingImage = false

    var body: some View {
        SettingsScaffold {
            SettingsSectionCard(title: "Anzeige") {
                Toggle(isOn: $transparentEnabled) {
                    HStack(spacing: 12) {
                        SettingsIconTile(systemName: "square.on.square.intersection.dashed", tint: theme.uiAccentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Transparenter Hintergrund")
                                .appTitle()
                                .foregroundStyle(primaryTextColor)
                            Text("Dein Widget übernimmt den Hintergrund von einem Homescreen-Screenshot.")
                                .appSecondary()
                                .foregroundStyle(secondaryTextColor)
                        }
                    }
                }
                .tint(theme.uiAccentColor)
            }

            if transparentEnabled {
                SettingsSectionCard(title: "Homescreen-Screenshot") {
                    Text("Screenshot ohne Widgets aufnehmen und hier auswählen. So bleibt das Cropping deckungsgleich.")
                        .appSecondary()
                        .foregroundStyle(secondaryTextColor)

                    screenshotPreview

                    PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                        actionButtonLabel(
                            title: backgroundImage == nil ? "Screenshot auswählen" : "Screenshot ersetzen",
                            systemName: "photo.badge.plus"
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingImage)

                    if backgroundImage != nil {
                        Button(role: .destructive) {
                            WidgetSettingsStore.clearBackground()
                            backgroundImage = nil
                            WidgetCenter.shared.reloadAllTimelines()
                        } label: {
                            actionButtonLabel(title: "Screenshot entfernen", systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }

                SettingsSectionCard(title: "Home Screen Icons") {
                    Picker("Icon-Größe", selection: $iconSizeSelection) {
                        Text("Klein").tag(WidgetSettingsStore.iconSizeSmall)
                        Text("Groß").tag(WidgetSettingsStore.iconSizeLarge)
                    }
                    .pickerStyle(.segmented)

                    Text("Die Transparenz hängt von der Icon-Größe ab. Die Auswahl hier muss deinem Homescreen entsprechen.")
                        .appSecondary()
                        .foregroundStyle(secondaryTextColor)
                }

                SettingsSectionCard(title: "Feinabstimmung", spacing: 18) {
                    offsetControl(
                        title: "Horizontal",
                        systemName: "arrow.left.and.right",
                        valueText: "\(Int(offsetX)) px",
                        value: $offsetX,
                        range: -80...80
                    )

                    offsetControl(
                        title: "Vertikal",
                        systemName: "arrow.up.and.down",
                        valueText: "\(Int(offsetY)) px",
                        value: $offsetY,
                        range: -120...120
                    )

                    Text("Nur nötig, wenn das Widget minimal versetzt wirkt.")
                        .appSecondary()
                        .foregroundStyle(secondaryTextColor)
                }

                SettingsSectionCard(title: "Aktualisieren") {
                    Button {
                        WidgetSettingsStore.touchRefreshToken()
                        refreshToken = Date().timeIntervalSince1970
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        actionButtonLabel(title: "Widgets neu laden", systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)

                    Text("Nutze das, wenn Hintergrund oder Inhalte nicht sofort übernommen werden.")
                        .appSecondary()
                        .foregroundStyle(secondaryTextColor)
                }
            } else {
                SettingsSectionCard(title: "Akzent-Hintergrund") {
                    Text("Wenn Transparenz aus ist, nutzt das Widget dieselbe Akzentfarbe wie die restliche App.")
                        .appSecondary()
                        .foregroundStyle(secondaryTextColor)

                    accentPreview
                        .frame(height: 118)
                }
            }
        }
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
                    WidgetCenter.shared.reloadAllTimelines()
                    isLoadingImage = false
                }
            }
        }
        .onChange(of: transparentEnabled) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: iconSizeSelection) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: offsetX) {
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: offsetY) {
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
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(theme.uiAccentColor)
                            Text(isLoadingImage ? "Lädt Screenshot…" : "Kein Screenshot ausgewählt")
                                .appSecondary()
                                .foregroundStyle(secondaryTextColor)
                        }
                    }
            }
        }
    }

    private var accentPreview: some View {
        RoundedRectangle(cornerRadius: UIStylePolicy.Radius.large, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        theme.uiAccentColor.opacity(UIStylePolicy.chipTintOpacityUnread + 0.03),
                        theme.uiAccentColor.opacity(0.6)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                VStack(alignment: .leading, spacing: 4) {
                    Text("NotiFeeder")
                        .font(.headline)
                        .foregroundStyle(theme.uiAccentColor)
                    Text("Akzent-Hintergrund")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(UIStylePolicy.Spacing.medium),
                alignment: .bottomLeading
            )
            .overlay(
                RoundedRectangle(cornerRadius: UIStylePolicy.Radius.large, style: .continuous)
                    .strokeBorder(theme.uiAccentColor.opacity(UIStylePolicy.chipTintOpacityUnread + 0.03))
            )
    }

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: UIStylePolicy.Radius.large, style: .continuous)
    }

    private var previewBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.96) : Color.primary
    }

    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.62) : Color.secondary
    }

    private func offsetControl(
        title: String,
        systemName: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SettingsIconTile(systemName: systemName, tint: theme.uiAccentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .appTitle()
                        .foregroundStyle(primaryTextColor)
                    Text("Verschiebt das transparente Cropping in \(title.lowercased())er Richtung.")
                        .appSecondary()
                        .foregroundStyle(secondaryTextColor)
                }

                Spacer(minLength: 0)
                SettingsValuePill(text: valueText)
            }

            Slider(value: value, in: range, step: 1)
                .tint(theme.uiAccentColor)
        }
    }

    private func actionButtonLabel(title: String, systemName: String) -> some View {
        HStack(spacing: 12) {
            SettingsIconTile(systemName: systemName, tint: theme.uiAccentColor)
            Text(title)
                .appTitle()
                .foregroundStyle(primaryTextColor)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(secondaryTextColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.uiAccentColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
        )
    }
}

private enum WidgetSettingsStore {
    static let suiteName = "group.notiFeeder"
    static let transparentEnabledKey = "nf_widget_transparent_enabled"
    static let iconSizeKey = "nf_widget_icon_size"
    static let iconSizeSmall = "small"
    static let iconSizeLarge = "large"
    static let offsetXKey = "nf_widget_offset_x"
    static let offsetYKey = "nf_widget_offset_y"
    static let refreshTokenKey = "nf_widget_refresh_token"

    static let defaults: UserDefaults = {
        UserDefaults(suiteName: suiteName) ?? .standard
    }()

    static func backgroundKey() -> String {
        "nf_widget_bg_latest"
    }

    static func loadBackground() -> UIImage? {
        guard let data = defaults.data(forKey: backgroundKey()) else { return nil }
        return UIImage(data: data)
    }

    static func saveBackground(_ image: UIImage) {
        if let data = image.pngData() {
            defaults.set(data, forKey: backgroundKey())
        }
    }

    static func clearBackground() {
        defaults.removeObject(forKey: backgroundKey())
    }

    static func touchRefreshToken() {
        defaults.set(Date().timeIntervalSince1970, forKey: refreshTokenKey)
    }
}
