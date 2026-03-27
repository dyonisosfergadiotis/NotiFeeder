//
//  NetworkState.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 15.12.25.
//


import Foundation
import Combine
import SwiftUI
import OSLog

@MainActor
final class NetworkState: ObservableObject {
    @Published var isOffline = false
}

nonisolated enum FeedFetchError: Error, Equatable, Sendable {
    case invalidURL
    case offline
    case timeout
    case parseError
    case empty
    case network
}

nonisolated struct FeedFetchStatus: Equatable, Sendable {
    let entries: [FeedEntry]
    let error: FeedFetchError?
    let attempts: Int

    static func success(_ entries: [FeedEntry], attempts: Int) -> FeedFetchStatus {
        FeedFetchStatus(entries: entries, error: nil, attempts: attempts)
    }

    static func failure(_ error: FeedFetchError, attempts: Int) -> FeedFetchStatus {
        FeedFetchStatus(entries: [], error: error, attempts: attempts)
    }
}

actor FeedNetworkClient {
    private let session: URLSession
    private let maxRetries: Int
    private let timeout: TimeInterval

    init(session: URLSession = .shared, maxRetries: Int = 2, timeout: TimeInterval = 12) {
        self.session = session
        self.maxRetries = max(0, maxRetries)
        self.timeout = timeout
    }

    func fetch(feed: FeedSource) async -> FeedFetchStatus {
        let feedID = feed.id

        guard let url = URL(string: feed.url) else {
            AppLogger.network.error("Invalid feed URL for feed id \(feedID, privacy: .public)")
            return .failure(.invalidURL, attempts: 1)
        }

        var attempt = 0
        var lastError: FeedFetchError = .network

        while attempt <= maxRetries {
            attempt += 1
            let result = await fetchOnce(url: url)
            switch result {
            case .success(let entries):
                if attempt > 1 {
                    AppLogger.network.info("Feed recovered after retry. feed=\(feedID, privacy: .public) attempts=\(attempt)")
                }
                return .success(entries, attempts: attempt)
            case .failure(let error):
                lastError = error
                AppLogger.network.warning("Feed fetch failed. feed=\(feedID, privacy: .public) attempt=\(attempt) error=\(String(describing: error), privacy: .public)")
                if !shouldRetry(for: error, attempt: attempt) {
                    return .failure(error, attempts: attempt)
                }
                let backoffNanos = UInt64(250_000_000 * attempt)
                try? await Task.sleep(nanoseconds: backoffNanos)
            }
        }

        return .failure(lastError, attempts: maxRetries + 1)
    }

    private func fetchOnce(url: URL) async -> Result<[FeedEntry], FeedFetchError> {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                AppLogger.network.warning("Non-success status code \(http.statusCode) for URL \(url.absoluteString, privacy: .public)")
                return .failure(.network)
            }
            switch parseFeedData(data) {
            case .success(let entries):
                return .success(entries)
            case .failure(let parserError):
                switch parserError {
                case .emptyItems:
                    return .failure(.empty)
                default:
                    return .failure(.parseError)
                }
            }
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return .failure(.offline)
            case .timedOut, .cannotConnectToHost:
                return .failure(.timeout)
            default:
                return .failure(.network)
            }
        } catch {
            return .failure(.network)
        }
    }

    private func shouldRetry(for error: FeedFetchError, attempt: Int) -> Bool {
        guard attempt <= maxRetries else { return false }
        switch error {
        case .timeout, .network:
            return true
        case .offline, .invalidURL, .parseError, .empty:
            return false
        }
    }

    nonisolated private func parseFeedData(_ data: Data) -> Result<[FeedEntry], RSSParserError> {
        let parser = RSSParser()
        return parser.parseResult(data: data)
    }
}
