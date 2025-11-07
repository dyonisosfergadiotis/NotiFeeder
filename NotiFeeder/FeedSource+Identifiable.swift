import FoundationModels

extension FeedSource: Identifiable {
    public var id: String { url }
}
