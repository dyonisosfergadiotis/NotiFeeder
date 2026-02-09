// Bundle for all unread article widgets
import WidgetKit
import SwiftUI

struct UnreadArticlesWidgetsBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        LegacyUnreadArticlesWidget()
    }
}
