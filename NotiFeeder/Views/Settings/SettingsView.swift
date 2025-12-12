import SwiftUI

struct SettingsView: View {
    @Binding var feeds: [FeedSource]
    @Binding var savedFeedsData: Data
    @EnvironmentObject private var theme: ThemeSettings
    @State private var showingAddFeed = false
    @State private var feedBeingEdited: FeedSource? = nil
    @State private var showingAccentPicker = false
    
    var body: some View {
        NavigationStack {
            List {
                if !bannerDismissed {
                    Section {
                        SettingsSummaryCard(feedCount: feeds.count,
                                            accentColor: theme.uiAccentColor,
                                            onClose: { bannerDismissed = true })
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }

                FeedsSection(
                    feeds: feeds,
                    onDelete: { indexSet in
                        let removedFeeds = indexSet.compactMap { feeds.indices.contains($0) ? feeds[$0] : nil }
                        feeds.remove(atOffsets: indexSet)
                        removedFeeds.forEach { theme.resetColor(for: $0.url) }
                        saveFeeds()
                    },
                    onAdd: { showingAddFeed = true },
                    onEdit: { feed in feedBeingEdited = feed },
                    accentColor: theme.uiAccentColor
                )
                .environmentObject(theme)
                
                Section(header: Text("Personalisierung")) {
                    Button {
                        showingAccentPicker = true
                    } label: {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(theme.uiAccentColor)
                                .frame(width: 33, height: 33)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Akzentfarbe")
                                    .appTitle()
                                Text("Wähle eine Pastellfarbe")
                                    .appSecondary()
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .tint(theme.uiAccentColor)
                    .sheet(isPresented: $showingAccentPicker) {
                        AccentColorPickerSheet(selected: theme.uiAccentColor) { newColor in
                            theme.setUIAccentColor(newColor)
                        }
                        .presentationDetents([.fraction(0.47)])
                        .presentationDragIndicator(.visible)
                    }
                }
                
                InfoSection(appVersionString: appVersionString)
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.large)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
        }
        .sheet(isPresented: $showingAddFeed) {
            AddFeedView { title, url in
                let newFeed = FeedSource(title: title, url: url)
                feeds.append(newFeed)
                saveFeeds()
            }
        }
        .sheet(item: $feedBeingEdited) { feed in
            EditFeedView(feed: feed,
                         initialColor: theme.colorOption(for: feed.url)) { updatedFeed, colorOption in
                handleFeedEdit(original: feed, updated: updatedFeed, colorOption: colorOption)
            }
            .environmentObject(theme)
        }
        .onAppear {
            // Removed calls to refreshNotificationSettings() and loadNotificationPreferences()
        }
    }
    
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        return version
    }
    
    private func handleFeedEdit(original: FeedSource, updated: FeedSource, colorOption: FeedColorOption) {
        guard let index = feeds.firstIndex(where: { $0.id == original.id }) else { return }
        feeds[index] = updated
        if original.url != updated.url {
            theme.resetColor(for: original.url)
        }
        theme.setColor(colorOption, for: updated.url)
        saveFeeds()
        // Removed pruneNotificationPreferences() and saveNotificationPreferences() calls
    }
    
    func deleteFeeds(at offsets: IndexSet) {
        // Remove feeds at specified offsets
        feeds.remove(atOffsets: offsets)
        saveFeeds()
    }
    
    func saveFeeds() {
        if let data = try? JSONEncoder().encode(feeds) {
            savedFeedsData = data
        }
    }
    
    @AppStorage("settingsBannerDismissed") private var bannerDismissed = false
}

private struct AccentColorPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeSettings
    let selected: Color
    let onPick: (Color) -> Void

    // 12 pastel colors (3x4 grid)
    private let pastelColors: [Color] = [
        Color(red: 0.98, green: 0.68, blue: 0.68), // Rot
        Color(red: 0.99, green: 0.78, blue: 0.63), // Orange
        Color(red: 0.99, green: 0.88, blue: 0.60), // Gelb
        Color(red: 0.97, green: 0.93, blue: 0.65), // Gelb-Grün
        Color(red: 0.90, green: 0.95, blue: 0.67), // Grün
        Color(red: 0.80, green: 0.95, blue: 0.72), // Grün-Blau
        Color(red: 0.72, green: 0.93, blue: 0.78), // Türkis
        Color(red: 0.64, green: 0.88, blue: 0.88), // Blau-Grün
        Color(red: 0.64, green: 0.84, blue: 0.92), // Hellblau
        Color(red: 0.70, green: 0.82, blue: 0.95), // Blau
        Color(red: 0.75, green: 0.78, blue: 0.98), // Blau-Violett
        Color(red: 0.80, green: 0.74, blue: 0.97), // Violett
        Color(red: 0.88, green: 0.78, blue: 0.96), // Rose-Violett
        Color(red: 0.92, green: 0.82, blue: 0.95), // Rose
        Color(red: 0.96, green: 0.88, blue: 0.94), // Rosa-Hell
        Color(red: 0.99, green: 0.96, blue: 0.99)  // Weiß
    ]

    private let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4),
                    spacing: 22
                ) {
                    ForEach(pastelColors.indices, id: \.self) { idx in
                        let color = pastelColors[idx]
                        Button {
                            onPick(color)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(color)
                                    .frame(width: 58, height: 58)
                                if colorsEqual(color, selected) || colorsEqual(color, theme.uiAccentColor) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.95))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Farbe \(idx + 1)")
                    }
                }
                .padding(.top, 5)
                .padding(.bottom, 10)
                .padding(.horizontal, 8)
            }
            .navigationTitle("Akzentfarbe")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(theme.uiAccentColor)
    
    }

    private func colorsEqual(_ a: Color, _ b: Color) -> Bool {
        // Best-effort comparison by converting to UIColor and comparing RGBA
        #if canImport(UIKit)
        let ua = UIColor(a)
        let ub = UIColor(b)
        var ra: CGFloat = 0, ga: CGFloat = 0, ba: CGFloat = 0, aa: CGFloat = 0
        var rb: CGFloat = 0, gb: CGFloat = 0, bb: CGFloat = 0, ab: CGFloat = 0
        ua.getRed(&ra, green: &ga, blue: &ba, alpha: &aa)
        ub.getRed(&rb, green: &gb, blue: &bb, alpha: &ab)
        return abs(ra - rb) < 0.01 && abs(ga - gb) < 0.01 && abs(ba - bb) < 0.01 && abs(aa - ab) < 0.01
        #else
        return false
        #endif
    }
}

private struct FeedsSection: View {
    var feeds: [FeedSource]
    var onDelete: (IndexSet) -> Void
    var onAdd: () -> Void
    var onEdit: (FeedSource) -> Void
    var accentColor: Color
    @EnvironmentObject private var theme: ThemeSettings

    var body: some View {
        Section(header: Text("Gespeicherte Feeds")) {
            ForEach(feeds) { feed in
                HStack(spacing: 14) {
                    if let faviconURL = feed.faviconURL {
                        FaviconImageView(url: faviconURL)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feed.title)
                            .appTitle()
                            .foregroundStyle(theme.color(for: feed.url))
                        Text(feed.url)
                            .appSecondary()
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button {
                        onEdit(feed)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("Feed bearbeiten")
                    .tint(theme.color(for: feed.url))
                }
            }
            .onDelete(perform: onDelete)
            
            Button(action: onAdd) {
                Label("Feed hinzufügen", systemImage: "plus")
            }
            .tint(accentColor)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
        }
    }
}

// MARK: - FaviconImageView mit dauerhaftem Caching und Aktualisierung
private struct FaviconImageView: View {
    let url: URL
    @State private var image: Image? = nil
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image = image {
                image.resizable().scaledToFit()
            } else {
                Circle().fill(Color.gray.opacity(0.3))
                    .onAppear {
                        loadFavicon()
                    }
            }
        }
    }

    private func loadFavicon() {
        guard !isLoading else { return }
        isLoading = true

        let fileManager = FileManager.default
        if let cachedURL = FaviconCacheHelper.cachedURL(for: url),
           let attributes = try? fileManager.attributesOfItem(atPath: cachedURL.path),
           let modificationDate = attributes[.modificationDate] as? Date {
            // Optional: update icon if older than 24h
            if Date().timeIntervalSince(modificationDate) < 24*60*60,
               let uiImage = UIImage(contentsOfFile: cachedURL.path) {
                image = Image(uiImage: uiImage)
                return
            }
        }

        Task {
            if let uiImage = await FaviconCacheHelper.downloadAndCacheFavicon(from: url) {
                await MainActor.run { image = Image(uiImage: uiImage) }
            }
        }
    }
}

private enum FaviconCacheHelper {
    static func cachedURL(for url: URL) -> URL? {
        let fileURL = cacheURL(for: url)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return nil
    }

    static func cacheURL(for url: URL) -> URL {
        let fileName = cacheFileName(for: url)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent(fileName)
    }

    static func cacheFileName(for url: URL) -> String {
        // Use a hash of the url as filename for uniqueness
        let base = url.absoluteString
        let hash = String(base.hashValue)
        let ext = (url.pathExtension.isEmpty ? "png" : url.pathExtension)
        return "favicon_\(hash).\(ext)"
    }

    static func downloadAndCacheFavicon(from url: URL) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                let fileURL = cacheURL(for: url)
                try? data.write(to: fileURL)
                return image
            }
        } catch {
            // Ignore error, fallback to placeholder
        }
        return nil
    }
}

private struct InfoSection: View {
    var appVersionString: String
    var body: some View {
        Section(header: Text("Info")) {
            HStack { Text("Version"); Spacer(); Text(appVersionString).foregroundColor(.secondary) }
            HStack {
                Text("Autor")
                Spacer()
                Link("Dyonisos Fergadiotis", destination: URL(string: "https://dyonisosfergadiotis.de")!)
            }
        }
    }
}

private struct EditFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeSettings
    @State private var title: String
    @State private var url: String
    @State private var selectedColor: FeedColorOption
    let onSave: (FeedSource, FeedColorOption) -> Void

    init(feed: FeedSource, initialColor: FeedColorOption, onSave: @escaping (FeedSource, FeedColorOption) -> Void) {
        self._title = State(initialValue: feed.title)
        self._url = State(initialValue: feed.url)
        self._selectedColor = State(initialValue: initialColor)
        self.onSave = onSave
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Details") {
                    TextField("Titel", text: $title)
                    TextField("RSS-URL", text: $url)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                Section("Farbe") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(FeedColorOption.palette) { option in
                                Button {
                                    selectedColor = option
                                } label: {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 44, height: 44)
                                        .overlay {
                                            if option == selectedColor {
                                                Circle()
                                                    .stroke(theme.uiAccentColor, lineWidth: 4)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(option.name)
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.leading, 8)
                        .padding(.trailing, 8)
                    }
                }
            }
            .navigationTitle("Feed bearbeiten")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedTitle.isEmpty, !trimmedURL.isEmpty else { return }
                        let updated = FeedSource(title: trimmedTitle, url: trimmedURL)
                        onSave(updated, selectedColor)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .tint(theme.uiAccentColor)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                    }
                    .tint(theme.uiAccentColor)
                    .accessibilityLabel("Schließen")
                }
            }
        }
        .tint(theme.uiAccentColor)
    }
}

private struct SettingsSummaryCard: View {
    var feedCount: Int
    var accentColor: Color
    var onClose: () -> Void

    private var feedText: String {
        feedCount == 1 ? "1 Feed aktiv" : "\(feedCount) Feeds aktiv"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label {
                    Text("Personalisiere deinen Feed")
                        .appTitle()
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: "sparkles")
                        .symbolVariant(.fill)
                        .font(.system(size: 20, weight: .medium))
                }
                .foregroundStyle(Color(.systemBackground))
            //}
                Spacer()
          // HStack {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color(.systemBackground).opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Banner schließen")
            }

            Text("Passe Benachrichtigungen, Feeds und Farben an, damit neue Artikel perfekt zu dir durchdringen.")
                .appSecondary()

            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.subheadline)
                Text(feedText)
                    .appSecondary()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.systemBackground).opacity(0.18), in: Capsule())
            .foregroundStyle(Color(.systemBackground))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [accentColor.opacity(0.92), accentColor.opacity(0.7)],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
        )
    }
}

extension FeedColorOption {
    static var palette: [FeedColorOption] { FeedColorOption.defaultPalette }

    func nextInPalette() -> FeedColorOption {
        let all = Self.palette
        guard let idx = all.firstIndex(of: self) else { return self }
        let nextIdx = all.index(after: idx)
        return nextIdx < all.endIndex ? all[nextIdx] : all.first ?? self
    }

    func previousInPalette() -> FeedColorOption {
        let all = Self.palette
        guard let idx = all.firstIndex(of: self) else { return self }
        return idx > all.startIndex ? all[all.index(before: idx)] : (all.last ?? self)
    }
}

#Preview {
    SettingsView(
        feeds: .constant([]),
        savedFeedsData: .constant(Data())
    )
    .environmentObject(ThemeSettings())
}
