//
//  FeedEntryModel.swift
//  NotiFeeder
//
//  Created by Dyonisos Fergadiotis on 04.11.25.
//

import Foundation
import SwiftData

@Model
final class FeedEntryModel: Identifiable, Hashable {
    var id: UUID
    var title: String
    var shortTitle: String
    var link: String
    var content: String
    var contentRaw: String?
    var author: String?
    var sourceTitle: String?
    var sourceURL: String?
    var pubDateString: String?
    var date: Date
    
    // Flags für Status
    var isBookmarked: Bool = false
    var isRead: Bool = false
    var isNew: Bool = false

    init(
        id: UUID = UUID(),
        title: String,
        shortTitle: String? = nil,
        link: String,
        content: String,
        contentRaw: String? = nil,
        author: String? = nil,
        sourceTitle: String? = nil,
        sourceURL: String? = nil,
        pubDateString: String? = nil,
        date: Date = Date(),
        isBookmarked: Bool = false,
        isRead: Bool = false,
        isNew: Bool = false
    ) {
        self.id = id
        self.title = title
        self.shortTitle = shortTitle ?? title
        self.link = link
        self.content = content
        self.contentRaw = contentRaw
        self.author = author
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.pubDateString = pubDateString
        self.date = date
        self.isBookmarked = isBookmarked
        self.isRead = isRead
        self.isNew = isNew
    }
    static func == (lhs: FeedEntryModel, rhs: FeedEntryModel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
