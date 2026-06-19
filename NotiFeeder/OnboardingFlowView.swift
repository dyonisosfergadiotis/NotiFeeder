//
//  OnboardingFlowView.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 15.12.25.
//

import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var theme: ThemeSettings
    @ObservedObject var viewModel: OnboardingViewModel
    var onFinish: (FeedSource?, String?) -> Void

    @State private var didFinish = false

    private let visibleSteps: [OnboardingViewModel.Step] = [.intro, .enterURL, .enterDetails, .features]

    private var canGoBack: Bool {
        viewModel.step.rawValue > OnboardingViewModel.Step.intro.rawValue
            && viewModel.step != .done
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ZStack {
                switch viewModel.step {
                case .intro:
                    OnboardingIntroView()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                case .enterURL:
                    OnboardingEnterURLView(viewModel: viewModel)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                case .enterDetails:
                    OnboardingEnterDetailsView(viewModel: viewModel)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                case .features:
                    OnboardingFeaturesView()
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                case .done:
                    Color.clear.onAppear { finish(with: viewModel.producedFeed) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.22), value: viewModel.step)
        }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom) {
            if viewModel.step != .done {
                arrowFooter
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                AppHaptics.selection()
                withAnimation(.easeInOut(duration: 0.22)) {
                    viewModel.back()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .fontWeight(.light)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)
            .accessibilityHidden(!canGoBack)

            Spacer()

            Button("Überspringen") {
                finish(with: nil)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var arrowFooter: some View {
        VStack(spacing: 14) {
            if let validationMessage = viewModel.urlValidationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 18) {
                Button {
                    AppHaptics.selection()
                    withAnimation(.easeInOut(duration: 0.22)) {
                        viewModel.back()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canGoBack ? theme.uiAccentColor : Color.secondary.opacity(0.45))
                .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                .overlay(Circle().stroke(Color(.separator).opacity(0.35), lineWidth: 0.8))
                .disabled(!canGoBack)
                .accessibilityLabel("Zurück")

                Spacer(minLength: 8)

                progressDots

                Spacer(minLength: 8)

                Button {
                    goForward()
                } label: {
                    Image(systemName: viewModel.step == .features ? "checkmark" : "chevron.right")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .frame(width: 54, height: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Circle().fill(theme.uiAccentColor))
                .shadow(color: theme.uiAccentColor.opacity(0.22), radius: 10, y: 4)
                .accessibilityLabel(viewModel.step == .features ? "Onboarding abschließen" : "Weiter")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .padding(.top, 12)
        .background(.ultraThinMaterial)
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(visibleSteps, id: \.self) { step in
                Capsule(style: .continuous)
                    .fill(step == viewModel.step ? theme.uiAccentColor : Color(.tertiarySystemFill))
                    .frame(width: step == viewModel.step ? 18 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.18), value: viewModel.step)
            }
        }
    }

    private func finish(with feed: FeedSource?) {
        guard !didFinish else { return }
        didFinish = true
        if feed == nil {
            AppHaptics.selection()
        } else {
            AppHaptics.success()
        }
        onFinish(feed, feed == nil ? nil : viewModel.selectedColorHex)
    }

    private func goForward() {
        let previousStep = viewModel.step
        withAnimation(.easeInOut(duration: 0.22)) {
            viewModel.next()
        }

        if viewModel.step == .done {
            finish(with: viewModel.producedFeed)
        } else if viewModel.step == previousStep {
            AppHaptics.warning()
        } else {
            AppHaptics.selection()
        }
    }
}

struct OnboardingIntroView: View {
    private let items: [OnboardingIntroItem] = [
        OnboardingIntroItem(
            icon: "square.stack.3d.up.fill",
            title: "Alles an einem Ort",
            subtitle: "Sammle deine Lieblingsquellen und behalte neue Artikel zentral im Blick."
        ),
        OnboardingIntroItem(
            icon: "bolt.fill",
            title: "Schnell erfassen",
            subtitle: "Klare Übersicht, schnelle Navigation und ein ruhiges Lesegefühl ohne Ballast."
        ),
        OnboardingIntroItem(
            icon: "checkmark.seal.fill",
            title: "Volle Kontrolle",
            subtitle: "Markiere gelesen, passe Feeds an und starte mit einem Setup, das zu dir passt."
        )
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Willkommen")
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(1)
                Text("Dein persönlicher Nachrichten-Feed. Klar, fokussiert und angenehm zu lesen.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)
            
            VStack(spacing: 14) {
                ForEach(items) { item in
                    OnboardingIntroRow(item: item)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 20)
    }
}

private struct OnboardingIntroItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
}

private struct OnboardingIntroRow: View {
    let item: OnboardingIntroItem
    @EnvironmentObject private var theme: ThemeSettings
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.uiAccentColor.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: item.icon)
                    .font(.system(size: 16))
                    .fontWeight(.light)
                    .foregroundStyle(theme.uiAccentColor)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

struct OnboardingEnterURLView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Feed hinzufügen")
                        .font(.title2.weight(.semibold))
                    Text("Füge deine RSS-Adresse ein. Einen Namen kannst du optional setzen.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 24)

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Feed-URL")
                            .font(.subheadline.weight(.semibold))
                        TextField("https://example.com/feed.xml", text: $viewModel.feedURL)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focused)
                            .onSubmit { focused = false }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Titel (optional)")
                            .font(.subheadline.weight(.semibold))
                        TextField("z. B. Tech News", text: $viewModel.feedName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                }

                Text("Tipp: Wenn du ohne Feed starten willst, nutze unten links „Überspringen“.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .onAppear { focused = true }
    }
}

struct OnboardingEnterDetailsView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @EnvironmentObject private var theme: ThemeSettings

    private let symbolCandidates = [
        "newspaper", "globe", "bolt.horizontal", "bubble.left.and.bubble.right", "bookmark", "star", "antenna.radiowaves.left.and.right"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Preview circle
                ZStack {
                    Circle()
                        .fill(viewModel.selectedColor.gradient)
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
                    if let img = viewModel.selectedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                    } else if let symbol = viewModel.selectedSystemImageName {
                        Image(systemName: symbol)
                            .font(.system(size: 34))
                            .fontWeight(.light)
                            .foregroundStyle(.white)
                    }
                }
                .padding(.top, 12)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Name des Feeds")
                        .font(.headline)
                    TextField("z. B. MacRumors", text: $viewModel.feedName)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Farbe")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)

                        ForEach(FeedColorOption.defaultPalette) { option in
                            let isSelected = isPaletteOptionSelected(option)

                            ZStack {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if isSelected {
                                            Circle().stroke(theme.uiAccentColor, lineWidth: 3)
                                        }
                                    }

                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                        .fontWeight(.light)
                                        .foregroundStyle(.black.opacity(0.7))
                                }
                            }
                            .contentShape(Circle())
                            .onTapGesture {
                                AppHaptics.selection()
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    viewModel.selectedColor = option.color
                                }
                            }
                            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Icon")
                        .font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                        ForEach(symbolCandidates, id: \.self) { name in
                            Button {
                                AppHaptics.selection()
                                viewModel.selectedSystemImageName = name
                                viewModel.selectedImage = nil
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                    Image(systemName: name)
                                        .font(.system(size: 18))
                                        .fontWeight(.light)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .frame(height: 44)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .onAppear {
            guard FeedColorOption.defaultPalette.contains(where: isPaletteOptionSelected) == false else { return }
            if let first = FeedColorOption.defaultPalette.first {
                viewModel.selectedColor = first.color
            }
        }
    }

    private func isPaletteOptionSelected(_ option: FeedColorOption) -> Bool {
        let selectedHex = viewModel.selectedColor.toHex()?.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        let optionHex = option.hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        return selectedHex == optionHex
    }
}

struct OnboardingFeaturesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Tipps & Funktionen")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                Label { Text("Leere Zustände: Wenn noch nichts da ist, einfach nach unten ziehen um zu aktualisieren.") } icon: { Image(systemName: "tray").fontWeight(.light) }
                Label { Text("Gelesen markieren: Wische rechts/links, um Artikel als gelesen/ungelesen zu setzen.") } icon: { Image(systemName: "checkmark.circle").fontWeight(.light) }
                Label { Text("Suche: Finde Artikel und Feeds schnell über die Suche im Tab.") } icon: { Image(systemName: "magnifyingglass").fontWeight(.light) }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
            .padding(.horizontal)
            Spacer()
        }
    }
}
