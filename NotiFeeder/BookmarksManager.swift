import Foundation
import Combine

final class BookmarksManager: ObservableObject {
    static let shared = BookmarksManager()
    private init() { load() }

    @Published private(set) var bookmarkedIDs: Set<String> = []
    private let defaultsKey = "bookmarkedArticleIDs"

    func isBookmarked(_ id: String) -> Bool {
        bookmarkedIDs.contains(id)
    }

    func toggle(_ id: String) {
        if bookmarkedIDs.contains(id) {
            bookmarkedIDs.remove(id)
        } else {
            bookmarkedIDs.insert(id)
        }
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            bookmarkedIDs = decoded
        } else {
            bookmarkedIDs = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarkedIDs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
