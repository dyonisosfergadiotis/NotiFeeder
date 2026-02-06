// Bundle for all unread article widgets
import WidgetKit
import SwiftUI

@main
struct UnreadArticlesWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        UnreadArticlesWidget()
    }
}
