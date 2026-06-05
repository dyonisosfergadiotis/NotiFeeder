//
//  AddFeedView.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.11.25.
//

import Foundation
import SwiftUI

struct FeedDraft {
    let title: String
    let url: String

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasTitleAndURL: Bool {
        !trimmedTitle.isEmpty && !trimmedURL.isEmpty
    }

    var normalizedURLString: String? {
        guard !trimmedURL.isEmpty else { return nil }

        if
            let direct = URL(string: trimmedURL),
            let scheme = direct.scheme,
            !scheme.isEmpty,
            direct.host != nil
        {
            return direct.absoluteString
        }

        if
            let httpsPrefixed = URL(string: "https://\(trimmedURL)"),
            httpsPrefixed.host != nil
        {
            return httpsPrefixed.absoluteString
        }

        return nil
    }

    func makeFeedSource(requireValidURL: Bool, fallbackTitleToURL: Bool) -> FeedSource? {
        guard !trimmedURL.isEmpty else { return nil }
        let resolvedURL: String
        if requireValidURL {
            guard let normalizedURLString else { return nil }
            resolvedURL = normalizedURLString
        } else {
            resolvedURL = trimmedURL
        }
        let fallbackTitle = URL(string: resolvedURL)?.host ?? resolvedURL
        let resolvedTitle = fallbackTitleToURL && trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle
        guard !resolvedTitle.isEmpty else { return nil }
        return FeedSource(title: resolvedTitle, url: resolvedURL)
    }
}

struct FeedColorPalettePicker: View {
    @Binding var selectedColor: FeedColorOption
    @EnvironmentObject private var theme: ThemeSettings

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIStylePolicy.Spacing.xLarge) {
                ForEach(FeedColorOption.palette) { option in
                    Button {
                        AppHaptics.selection()
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedColor = option
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(option.color)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Circle()
                                        .stroke(option == selectedColor ? theme.uiAccentColor : Color.clear, lineWidth: 3)
                                }

                            if option == selectedColor {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.black.opacity(0.72))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.name)
                    .accessibilityValue(option == selectedColor ? "Ausgewählt" : "Nicht ausgewählt")
                }
            }
            .padding(.vertical, UIStylePolicy.Spacing.small + 2)
            .padding(.leading, UIStylePolicy.Spacing.small)
            .padding(.trailing, UIStylePolicy.Spacing.small)
        }
    }
}

struct FeedEditorForm: View {
    @Binding var title: String
    @Binding var url: String
    @Binding var selectedColor: FeedColorOption
    let includeDetailsSection: Bool
    @EnvironmentObject private var theme: ThemeSettings

    var body: some View {
        Form {
            Section {
                AddFeedPreview(title: title, url: url, color: selectedColor.color)
            }

            if includeDetailsSection {
                Section("Details") {
                    fields
                }
            } else {
                fields
            }

            Section("Farbe") {
                FeedColorPalettePicker(selectedColor: $selectedColor)
            }
        }
    }

    private var fields: some View {
        Group {
            TextField("Name", text: $title)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()

            TextField("Feed URL", text: $url)
                .keyboardType(.URL)
                .autocapitalization(.none)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
    }
}

struct AddFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeSettings
    @State private var title = ""
    @State private var url = ""
    @State private var selectedColor = FeedColorOption.palette.first!
    var onSave: (String, String) -> Void

    var body: some View {
        NavigationStack {
            FeedEditorForm(
                title: $title,
                url: $url,
                selectedColor: $selectedColor,
                includeDetailsSection: false
            )
            .scrollContentBackground(.hidden)
            .background(SettingsChromeBackground(accent: theme.uiAccentColor).ignoresSafeArea())
            .listStyle(.insetGrouped)
            .navigationTitle("Feed hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .sheetCornerAlignedScrollContent()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let draft = FeedDraft(title: title, url: url)
                        guard let feed = draft.makeFeedSource(requireValidURL: true, fallbackTitleToURL: true) else { return }
                        AppHaptics.success()
                        theme.setColor(selectedColor, for: feed.url)
                        FaviconCache.prefetchFavicon(for: feed.url)
                        onSave(feed.title, feed.url)
                        dismiss()
                    }.disabled(FeedDraft(title: title, url: url).makeFeedSource(requireValidURL: true, fallbackTitleToURL: true) == nil)
                        .tint(theme.uiAccentColor)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .tint(theme.uiAccentColor)
    }
}

private struct AddFeedPreview: View {
    let title: String
    let url: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.gradient)

                Text(previewLetter)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)
            .shadow(color: color.opacity(0.22), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(previewTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(previewSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private var draft: FeedDraft {
        FeedDraft(title: title, url: url)
    }

    private var previewTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        if let host = previewHost { return host }
        return "Neuer Feed"
    }

    private var previewSubtitle: String {
        previewHost ?? "RSS-Adresse einfügen"
    }

    private var previewHost: String? {
        guard
            let normalized = draft.normalizedURLString,
            let host = URL(string: normalized)?.host
        else { return nil }
        return host
    }

    private var previewLetter: String {
        if let first = previewTitle.first {
            return String(first).uppercased()
        }
        return "N"
    }
}
