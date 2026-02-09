//
//  AppIntent.swift
//  NotiFeeder Widget
//
//  Created by Dyonisos Fergadiotis on 02.02.26.
//

import WidgetKit
import AppIntents

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Configuration" }
    static var description: IntentDescription { "This is an example widget." }

    // An example configurable parameter.
    @Parameter(title: "Favorite Emoji")
    var favoriteEmoji: String?
}
