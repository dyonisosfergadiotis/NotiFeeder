//
//  AddFeedView.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.11.25.
//

import Foundation
import SwiftUI

struct AddFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var theme: ThemeSettings
    @State private var title = ""
    @State private var url = ""
    @State private var selectedColor = FeedColorOption.palette.first!
    var onSave: (String, String) -> Void

    var body: some View {
        NavigationView {
            Form {
                TextField("Titel", text: $title)
                TextField("RSS-URL", text: $url)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
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
            .navigationTitle("Feed hinzufügen")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedTitle.isEmpty, !trimmedURL.isEmpty else { return }
                        onSave(trimmedTitle, trimmedURL)
                        theme.setColor(selectedColor, for: trimmedURL)
                        dismiss()
                    }.disabled(title.isEmpty || url.isEmpty)
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

