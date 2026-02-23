import PhotosUI
import SwiftUI
import UIKit
import WidgetKit

struct WidgetSettingsView: View {
    @EnvironmentObject private var theme: ThemeSettings

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
        Form {
            Section {
                Toggle(isOn: $transparentEnabled) {
                    VStack(alignment: .leading, spacing: UIStylePolicy.Spacing.xSmall) {
                        Text("Transparenter Hintergrund")
                            .font(.headline)
                        Text("Dein Widget übernimmt den Hintergrund vom Homescreen-Screenshot.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(theme.uiAccentColor)
            }

            if transparentEnabled {
                Section("Homescreen-Screenshot") {
                    VStack(alignment: .leading, spacing: UIStylePolicy.Spacing.small + 2) {
                        Text("Screenshot ohne Widgets aufnehmen, dann hier auswählen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let image = backgroundImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: UIStylePolicy.Radius.medium, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: UIStylePolicy.Radius.medium, style: .continuous)
                                        .strokeBorder(Color.black.opacity(UIStylePolicy.glassAccentOpacity))
                                )
                        } else {
                            RoundedRectangle(cornerRadius: UIStylePolicy.Radius.medium, style: .continuous)
                                .fill(Color.secondary.opacity(UIStylePolicy.glassAccentOpacity))
                                .frame(height: 120)
                                .overlay(
                                    VStack(spacing: 6) {
                                        Image(systemName: "photo")
                                            .font(.system(size: 20, weight: .semibold))
                                        Text("Kein Screenshot ausgewählt")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                )
                        }

                        PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                            Label(backgroundImage == nil ? "Screenshot auswählen" : "Screenshot ersetzen", systemImage: "square.and.arrow.up")
                        }
                        .tint(theme.uiAccentColor)
                        .disabled(isLoadingImage)

                        if backgroundImage != nil {
                            Button(role: .destructive) {
                                WidgetSettingsStore.clearBackground()
                                backgroundImage = nil
                                WidgetCenter.shared.reloadAllTimelines()
                            } label: {
                                Label("Screenshot entfernen", systemImage: "trash")
                            }
                        }
                    }
                }

                Section("Position im Homescreen") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Die Position wählst du direkt in den Widget-Einstellungen auf dem Homescreen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Damit das Cropping passt, platziere das Widget später an genau derselben Stelle.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Home Screen Icons") {
                    Picker("Icon-Größe", selection: $iconSizeSelection) {
                        Text("Klein (mit Labels)").tag(WidgetSettingsStore.iconSizeSmall)
                        Text("Groß (ohne Labels)").tag(WidgetSettingsStore.iconSizeLarge)
                    }
                    .pickerStyle(.segmented)
                    Text("Die Transparenz hängt von der Icon-Größe ab. Stelle sie identisch zu deinem Homescreen ein.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Feinabstimmung") {
                    VStack(alignment: .leading, spacing: UIStylePolicy.Spacing.medium) {
                        VStack(alignment: .leading, spacing: UIStylePolicy.Spacing.small - 2) {
                            HStack {
                                Text("Horizontal")
                                Spacer()
                                Text("\(Int(offsetX)) px")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $offsetX, in: -80...80, step: 1)
                                .tint(theme.uiAccentColor)
                        }
                        VStack(alignment: .leading, spacing: UIStylePolicy.Spacing.small - 2) {
                            HStack {
                                Text("Vertikal")
                                Spacer()
                                Text("\(Int(offsetY)) px")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $offsetY, in: -120...120, step: 1)
                                .tint(theme.uiAccentColor)
                        }
                        Text("Nur nötig, wenn die Ausrichtung minimal daneben liegt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Widget-Refresh") {
                    Button {
                        WidgetSettingsStore.touchRefreshToken()
                        refreshToken = Date().timeIntervalSince1970
                        WidgetCenter.shared.reloadAllTimelines()
                    } label: {
                        Label("Widgets neu laden", systemImage: "arrow.clockwise")
                    }
                    .tint(theme.uiAccentColor)
                    Text("Wenn Hintergrund oder Inhalte nicht aktualisieren, hier einmal manuell neu laden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Akzent-Hintergrund") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Wenn Transparenz aus ist, nutzt das Widget deine Akzentfarbe.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        accentPreview
                            .frame(height: 110)
                    }
                }
            }
        }
        .navigationTitle("Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .sheetCornerAlignedScrollContent()
        .onAppear {
            backgroundImage = WidgetSettingsStore.loadBackground()
        }
        .onChange(of: selectedItem) { newItem in
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
        .onChange(of: transparentEnabled) { _ in
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: iconSizeSelection) { _ in
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: offsetX) { _ in
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: offsetY) { _ in
            WidgetCenter.shared.reloadAllTimelines()
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
