//
//  FeedSource.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 15.12.25.
//


import Foundation
import SwiftUI
import Combine

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable, Hashable {
        case intro
        case enterURL
        case enterDetails
        case features
        case done
    }

    @Published var step: Step = .intro

    // Inputs
    @Published var feedURL: String = ""
    @Published var feedName: String = ""
    @Published var attemptedURLAdvance: Bool = false

    // Icon / color selection
    @Published var selectedColor: Color = FeedColorOption.defaultPalette.first?.color ?? .blue
    @Published var selectedSystemImageName: String? = "dot.radiowaves.left.and.right"
    @Published var selectedImage: UIImage? = nil

    // Output
    var producedFeed: FeedSource? {
        guard
            let normalized = normalizedFeedURLString(),
            let url = URL(string: normalized)
        else { return nil }
        let title = feedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.host ?? "Feed" : feedName
        return FeedSource(title: title, url: url.absoluteString)
    }

    var selectedColorHex: String? {
        selectedColor.toHex()
    }

    var urlValidationMessage: String? {
        guard attemptedURLAdvance, !canProceedFromURL() else { return nil }
        return "Gib eine gültige Feed-URL ein, um weiterzugehen."
    }

    func canProceedFromURL() -> Bool {
        normalizedFeedURLString() != nil
    }

    func canProceedFromDetails() -> Bool {
        normalizedFeedURLString() != nil
    }

    func next() {
        switch step {
        case .intro:
            step = .enterURL
        case .enterURL:
            guard canProceedFromURL() else {
                attemptedURLAdvance = true
                return
            }
            attemptedURLAdvance = false
            step = .enterDetails
        case .enterDetails:
            guard canProceedFromDetails() else {
                attemptedURLAdvance = true
                step = .enterURL
                return
            }
            attemptedURLAdvance = false
            step = .features
        case .features:
            step = .done
        case .done:
            return
        }
    }

    func back() {
        guard let idx = Step.allCases.firstIndex(of: step), idx - 1 >= 0 else { return }
        step = Step.allCases[idx - 1]
    }

    private func normalizedFeedURLString() -> String? {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if
            let direct = URL(string: trimmed),
            let scheme = direct.scheme,
            !scheme.isEmpty,
            direct.host != nil
        {
            return direct.absoluteString
        }

        if
            let httpsPrefixed = URL(string: "https://\(trimmed)"),
            httpsPrefixed.host != nil
        {
            return httpsPrefixed.absoluteString
        }

        return nil
    }
}
