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
    enum Step: Int, CaseIterable {
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

    // Validation / fetching state
    @Published var isValidating: Bool = false
    @Published var urlIsValid: Bool? = nil
    @Published var validationError: String? = nil

    // Icon / color selection
    @Published var selectedColor: Color = .blue
    @Published var selectedSystemImageName: String? = "dot.radiowaves.left.and.right"
    @Published var selectedImage: UIImage? = nil

    // Output
    var producedFeed: FeedSource? {
        guard let url = URL(string: feedURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let title = feedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url.host ?? "Feed" : feedName
        return FeedSource(title: title, url: url.absoluteString)
    }

    func canProceedFromURL() -> Bool {
        return urlIsValid == true
    }

    func canProceedFromDetails() -> Bool {
        return !feedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || URL(string: feedURL) != nil
    }

    func next() {
        guard let idx = Step.allCases.firstIndex(of: step), idx + 1 < Step.allCases.count else { return }
        step = Step.allCases[idx + 1]
    }

    func back() {
        guard let idx = Step.allCases.firstIndex(of: step), idx - 1 >= 0 else { return }
        step = Step.allCases[idx - 1]
    }

    func validateURL() async {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            self.urlIsValid = false
            self.validationError = "Bitte eine gültige URL eingeben."
            return
        }
        isValidating = true
        validationError = nil
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                self.urlIsValid = true
            } else {
                self.urlIsValid = false
                self.validationError = "Die URL konnte nicht bestätigt werden."
            }
        } catch {
            self.urlIsValid = false
            self.validationError = "Keine Verbindung oder ungültige URL."
        }
        isValidating = false
    }
}
