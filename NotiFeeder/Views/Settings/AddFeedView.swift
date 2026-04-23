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

    func makeFeedSource(requireValidURL: Bool, fallbackTitleToURL: Bool) -> FeedSource? {
        guard !trimmedURL.isEmpty else { return nil }
        if requireValidURL, URL(string: trimmedURL) == nil {
            return nil
        }
        let resolvedTitle = fallbackTitleToURL && trimmedTitle.isEmpty ? trimmedURL : trimmedTitle
        guard !resolvedTitle.isEmpty else { return nil }
        return FeedSource(title: resolvedTitle, url: trimmedURL)
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
                        selectedColor = option
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 44, height: 44)
                            .overlay {
                                if option == selectedColor {
                                    Circle()
                                        .stroke(theme.uiAccentColor, lineWidth: UIStylePolicy.Spacing.xSmall)
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

    var body: some View {
        Form {
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
            TextField("Titel", text: $title)
            TextField("RSS-URL", text: $url)
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
        NavigationView {
            FeedEditorForm(
                title: $title,
                url: $url,
                selectedColor: $selectedColor,
                includeDetailsSection: false
            )
            .navigationTitle("Feed hinzufügen")
            .sheetCornerAlignedScrollContent()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        let draft = FeedDraft(title: title, url: url)
                        guard draft.hasTitleAndURL else { return }
                        theme.setColor(selectedColor, for: draft.trimmedURL)
                        onSave(draft.trimmedTitle, draft.trimmedURL)
                        dismiss()
                    }.disabled(!FeedDraft(title: title, url: url).hasTitleAndURL)
                        .tint(theme.uiAccentColor)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .fontWeight(.light)
                    }
                    .minimumHitTarget()
                    .tint(theme.uiAccentColor)
                    .accessibilityLabel("Schließen")
                }
            }
        }
        .tint(theme.uiAccentColor)
    }
}
