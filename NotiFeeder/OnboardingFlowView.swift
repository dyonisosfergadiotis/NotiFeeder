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
    var onFinish: (FeedSource?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch viewModel.step {
                case .intro:
                    OnboardingIntroView(startAction: { viewModel.next() })
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
                    Color.clear.onAppear { onFinish(viewModel.producedFeed) }
                }
            }
            .animation(.easeInOut(duration: 0.22), value: viewModel.step)

            HStack {
                if viewModel.step != .intro && viewModel.step != .done {
                    Button("Zurück") { viewModel.back() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                nextButton
            }
            .padding()
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var nextButton: some View {
        switch viewModel.step {
        case .intro:
            Button("Starten") { viewModel.next() }
                .buttonStyle(.borderedProminent)
                .tint(theme.uiAccentColor)
        case .enterURL:
            Button("Weiter") {
                viewModel.next()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.uiAccentColor)
            .disabled(!viewModel.canProceedFromURL())
        case .enterDetails:
            Button("Weiter") { viewModel.next() }
                .buttonStyle(.borderedProminent)
                .tint(theme.uiAccentColor)
                .disabled(!viewModel.canProceedFromDetails())
        case .features:
            Button("Fertig") { viewModel.next() }
                .buttonStyle(.borderedProminent)
                .tint(theme.uiAccentColor)
        case .done:
            EmptyView()
        }
    }
}

struct OnboardingIntroView: View {
    var startAction: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text("Willkommen bei deinem Feed")
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Sammle und lese Nachrichten an einem Ort – schnell, übersichtlich, angenehm.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 24)

            // Mock cards
            VStack(spacing: 12) {
                ForEach(0..<3) { idx in
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .frame(height: 64)
                        .overlay(
                            HStack {
                                Circle().fill(.blue.opacity(0.2)).frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.15)).frame(height: 10)
                                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)).frame(height: 10)
                                }
                                Spacer()
                            }
                            .padding(.horizontal)
                        )
                        .padding(.horizontal)
                        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                }
            }

            Spacer()

            Button(action: startAction) {
                Text("Los geht’s")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
    }
}

struct OnboardingEnterURLView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Feed-URL eingeben")
                .font(.title2.weight(.semibold))
            Text("Wir prüfen, ob die Adresse erreichbar und erlaubt ist.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            TextField("https://…", text: $viewModel.feedURL)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focused)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .onSubmit { Task { await viewModel.validateURL() } }

            HStack(spacing: 8) {
                if viewModel.isValidating {
                    ProgressView().progressViewStyle(.circular)
                    Text("Prüfe…")
                } else if let valid = viewModel.urlIsValid {
                    Image(systemName: valid ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(valid ? .green : .red)
                    Text(valid ? "URL ist gültig" : (viewModel.validationError ?? "Ungültige URL"))
                        .foregroundStyle(valid ? .green : .red)
                } else {
                    Text("Noch nicht geprüft").foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)

            Button("URL prüfen") { Task { await viewModel.validateURL() } }
                .buttonStyle(.bordered)

            Spacer()
        }
        .onAppear { focused = true }
    }
}

struct OnboardingEnterDetailsView: View {
    @ObservedObject var viewModel: OnboardingViewModel

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
                            .font(.system(size: 34, weight: .semibold))
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
                    ColorPicker("Farbe wählen", selection: $viewModel.selectedColor, supportsOpacity: false)
                        .labelsHidden()
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Icon")
                        .font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                        ForEach(symbolCandidates, id: \.self) { name in
                            Button {
                                viewModel.selectedSystemImageName = name
                                viewModel.selectedImage = nil
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                    Image(systemName: name)
                                        .font(.system(size: 18))
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
    }
}

struct OnboardingFeaturesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Tipps & Funktionen")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 14) {
                Label { Text("Leere Zustände: Wenn noch nichts da ist, einfach nach unten ziehen um zu aktualisieren.") } icon: { Image(systemName: "tray") }
                Label { Text("Gelesen markieren: Wische rechts/links, um Artikel als gelesen/ungelesen zu setzen.") } icon: { Image(systemName: "checkmark.circle") }
                Label { Text("Suche: Finde Artikel und Feeds schnell über die Suche im Tab.") } icon: { Image(systemName: "magnifyingglass") }
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
            .padding(.horizontal)
            Spacer()
        }
    }
}
