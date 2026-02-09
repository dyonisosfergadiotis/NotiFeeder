// Widget entry point for unread articles (wrapper around legacy provider/view)
import WidgetKit
import SwiftUI

struct UnreadArticlesWidget: Widget {
    let kind: String = "UnreadArticlesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            UnreadArticlesWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Ungelesene Artikel")
        .description("Zeigt die neuesten ungelesenen Artikel aus deinen Feeds.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

