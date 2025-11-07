import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Binding var feeds: [FeedSource]
    @Binding var savedFeedsData: Data
    @EnvironmentObject private var theme: ThemeSettings
    @State private var showingAddFeed = false
    @AppStorage("notificationFeedPreferences") private var notificationFeedPreferencesData: Data = Data()
    @State private var notificationFeedPreferences: Set<String> = []
    @State private var knownNotificationFeedIDs: Set<String> = []
    @AppStorage("settingsBannerDismissed") private var bannerDismissed = false
    @AppStorage("notificationsEnabledPreference") private var notificationsEnabledPreference: Bool = true
    @State private var feedBeingEdited: FeedSource? = nil
    
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    
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

                NotificationSettingsSection(
                    notificationStatus: $notificationStatus,
                    notificationsEnabled: $notificationsEnabledPreference,
                    onRequestPermission: { requestNotificationPermission() },
                    onRefreshStatus: { refreshNotificationSettings() },
                    onOpenSystemSettings: { openSystemSettings() },
                    accentColor: theme.uiAccentColor,
                    feeds: feeds,
                    selectedFeeds: $notificationFeedPreferences
                )
                
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
            refreshNotificationSettings()
            loadNotificationPreferences()
        }
        .onChange(of: feeds) { _ in
            pruneNotificationPreferences()
            saveNotificationPreferences()
        }
        .onChange(of: notificationFeedPreferences) { _ in
            saveNotificationPreferences()
        }
    }
    
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        return version
    }
    
    private func refreshNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.notificationStatus = settings.authorizationStatus
                if settings.authorizationStatus == .denied {
                    self.notificationsEnabledPreference = false
                }
            }
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.notificationsEnabledPreference = granted
                self.refreshNotificationSettings()
            }
        }
    }
    
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    
    private func handleFeedEdit(original: FeedSource, updated: FeedSource, colorOption: FeedColorOption) {
        guard let index = feeds.firstIndex(where: { $0.id == original.id }) else { return }
        feeds[index] = updated
        if original.url != updated.url {
            theme.resetColor(for: original.url)
        }
        theme.setColor(colorOption, for: updated.url)
        saveFeeds()
        pruneNotificationPreferences()
        saveNotificationPreferences()
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

    private func loadNotificationPreferences() {
        if let payload = try? JSONDecoder().decode(NotificationPreferencesPayload.self, from: notificationFeedPreferencesData) {
            notificationFeedPreferences = payload.enabledFeeds
            knownNotificationFeedIDs = payload.knownFeeds
        } else if let decodedLegacy = try? JSONDecoder().decode(Set<String>.self, from: notificationFeedPreferencesData) {
            notificationFeedPreferences = decodedLegacy
            knownNotificationFeedIDs = decodedLegacy
        } else {
            notificationFeedPreferences = Set(feeds.map(\.url))
            knownNotificationFeedIDs = notificationFeedPreferences
        }
        pruneNotificationPreferences()
        saveNotificationPreferences()
    }

    private func pruneNotificationPreferences() {
        let valid = Set(feeds.map(\.url))
        let existingSelection = notificationFeedPreferences.intersection(valid)
        let removed = knownNotificationFeedIDs.subtracting(valid)
        knownNotificationFeedIDs.subtract(removed)

        let newFeeds = valid.subtracting(knownNotificationFeedIDs)
        knownNotificationFeedIDs.formUnion(newFeeds)

        notificationFeedPreferences = existingSelection.union(newFeeds)

        if notificationFeedPreferences.isEmpty {
            notificationFeedPreferences = valid
        }
    }

    private func saveNotificationPreferences() {
        let payload = NotificationPreferencesPayload(enabledFeeds: notificationFeedPreferences,
                                                     knownFeeds: knownNotificationFeedIDs)
        if let data = try? JSONEncoder().encode(payload) {
            notificationFeedPreferencesData = data
        }
    }
}

private struct NotificationSettingsSection: View {
    @Binding var notificationStatus: UNAuthorizationStatus
    @Binding var notificationsEnabled: Bool
    var onRequestPermission: () -> Void
    var onRefreshStatus: () -> Void
    var onOpenSystemSettings: () -> Void
    var accentColor: Color
    var feeds: [FeedSource]
    @Binding var selectedFeeds: Set<String>

    var body: some View {
        Section(header: Text("Benachrichtigungen"), footer: footerView) {
            if !feeds.isEmpty {
                NavigationLink {
                    NotificationFeedSelectionView(
                        feeds: feeds,
                        notificationsEnabled: $notificationsEnabled,
                        selectedFeeds: $selectedFeeds,
                        accentColor: accentColor,
                        notificationStatus: notificationStatus,
                        onRequestPermission: onRequestPermission,
                        onOpenSystemSettings: onOpenSystemSettings
                    )
                } label: {
                    HStack {
                        Label("Anpassen", systemImage: "bell.badge")
                        Spacer()
                        Text(selectionSummary)
                            .appSecondary()
                    }
                }
                .tint(accentColor)
                .padding(.top, 4)
            }
            if notificationStatus == .denied {
                Button(role: .none) {
                    onOpenSystemSettings()
                } label: {
                    Label("iOS-Einstellungen öffnen", systemImage: "gearshape")
                        .fontWeight(.semibold)
                }
                .tint(accentColor)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        if notificationStatus == .denied {
            Text("Benachrichtigungen sind in iOS deaktiviert. Du kannst sie in den Systemeinstellungen aktivieren.")
        } else if notificationStatus == .notDetermined {
            Text("Erlaube Benachrichtigungen, um neue Artikel im Hintergrund zu erhalten.")
        } else {
            EmptyView()
        }
    }

    private var selectionSummary: String {
        let validFeeds = Set(feeds.map(\.url))
        let enabledCount = selectedFeeds.intersection(validFeeds).count
        if feeds.isEmpty { return "0" }
        if !systemAllowsNotifications || !notificationsEnabled { return "0" }
        return String(enabledCount)
    }

    private var systemAllowsNotifications: Bool {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
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
                        Label("Bearbeiten", systemImage: "pencil")
                    }
                    .tint(theme.color(for: feed.url))
                }
            }
            .onDelete(perform: onDelete)

            Button(action: onAdd) {
                Label("Feed hinzufügen", systemImage: "plus")
            }
            .tint(accentColor)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))

            Text("Tipp: Streiche nach rechts und tippe auf \"Bearbeiten\", um Titel, URL oder Farbe anzupassen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 8, trailing: 16))
        }
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
                        .padding(.vertical, 6)
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

private struct NotificationFeedSelectionView: View {
    var feeds: [FeedSource]
    @Binding var notificationsEnabled: Bool
    @Binding var selectedFeeds: Set<String>
    var accentColor: Color
    var notificationStatus: UNAuthorizationStatus
    var onRequestPermission: () -> Void
    var onOpenSystemSettings: () -> Void

    private var sortedFeeds: [FeedSource] {
        feeds.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            if sortedFeeds.isEmpty {
                Text("Keine Feeds verfügbar. Füge zunächst Feeds hinzu, um Benachrichtigungen anzupassen.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    if notificationStatus == .denied || notificationStatus == .notDetermined {
                        Button {
                            if notificationStatus == .denied {
                                onOpenSystemSettings()
                            } else {
                                onRequestPermission()
                            }
                        } label: {
                            Label(notificationStatus == .denied ? "In iOS aktivieren" : "Benachrichtigungen anfragen",
                                  systemImage: notificationStatus == .denied ? "gearshape" : "bell.badge")
                        }
                        .tint(accentColor)
                    }
                    
                    Toggle("Benachrichtigungen senden", isOn: $notificationsEnabled)
                        .tint(accentColor)
                        .disabled(!systemAllowsNotifications)
                        .onChange(of: notificationsEnabled) { newValue in
                            if !newValue {
                                selectedFeeds = []
                            }
                        }
                    Section {
                    } footer: {
                        EmptyView()
                    }
                    Spacer()
                    ForEach(sortedFeeds) { feed in
                        Toggle(isOn: binding(for: feed)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(feed.title)
                                    .appTitle()
                                Text(feed.url)
                                    .appSecondary()
                            }
                        }
                        .tint(accentColor)
                        .disabled(!notificationsEnabled || !systemAllowsNotifications)
                    }
                } footer: {
                    Text("Aktiviere Benachrichtigungen und entscheide anschließend, welche Feeds Meldungen senden dürfen.")
                }
            }
        }
        .navigationTitle("Benachrichtigungen anpassen")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                statusToolbarItem
            }
        }
    }

    @ViewBuilder
    private var statusToolbarItem: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            if !notificationsEnabled {
                Image(systemName: "bell.slash")
                    .foregroundStyle(accentColor)
                    .accessibilityLabel("Benachrichtigungen deaktiviert")
            } else {
                EmptyView()
            }
        case .notDetermined:
            Button {
                onRequestPermission()
            } label: {
                Image(systemName: "bell.badge")
                    .foregroundStyle(accentColor)
            }
            .accessibilityLabel("Benachrichtigungen anfragen")
        case .denied:
            Button {
                onOpenSystemSettings()
            } label: {
                Image(systemName: "bell.slash")
                    .foregroundStyle(accentColor)
            }
            .accessibilityLabel("Benachrichtigungen in iOS aktivieren")
        @unknown default:
            Image(systemName: "bell")
                .foregroundStyle(accentColor)
        }
    }

    private func binding(for feed: FeedSource) -> Binding<Bool> {
        Binding(
            get: { notificationsEnabled && systemAllowsNotifications && selectedFeeds.contains(feed.url) },
            set: { newValue in
                guard notificationsEnabled && systemAllowsNotifications else {
                    selectedFeeds.remove(feed.url)
                    return
                }
                if newValue {
                    selectedFeeds.insert(feed.url)
                } else {
                    selectedFeeds.remove(feed.url)
                }
            }
        )
    }

    private var systemAllowsNotifications: Bool {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
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
                    Text("Mach NotiFeeder zu deinem Feed")
                        .appTitle()
                        .fontWeight(.semibold)
                } icon: {
                    Image(systemName: "sparkles")
                        .symbolVariant(.fill)
                        .font(.system(size: 24, weight: .medium))
                }
                .foregroundStyle(Color(.systemBackground))
            }
                Spacer()
            HStack {
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
