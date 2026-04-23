import AppIntents
import WidgetKit

struct WatchComplicationConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "NotiFeeder"
    static var description = IntentDescription("Zeigt den neuesten Artikel als rechteckige Watch-Complication.")
}
