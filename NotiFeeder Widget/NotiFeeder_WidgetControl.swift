//
//  NotiFeeder_WidgetControl.swift
//  NotiFeeder Widget
//
//  Created by Dyonisos Fergadiotis on 02.02.26.
//

import AppIntents
import SwiftUI
import WidgetKit

struct NotiFeeder_WidgetControl: ControlWidget {
    static let kind: String = "de.DyonisosFergadiotis.NotiFeeder.NotiFeeder Widget"

    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: Self.kind,
            provider: Provider()
        ) { value in
            ControlWidgetToggle(
                "Start Timer",
                isOn: value.isRunning,
                action: StartTimerIntent(value.name)
            ) { isRunning in
                Label {
                    Text(isRunning ? "On" : "Off")
                } icon: {
                    Image(systemName: "timer")
                        .fontWeight(.light)
                }
            }
        }
        .displayName("Timer")
        .description("A an example control that runs a timer.")
    }
}

extension NotiFeeder_WidgetControl {
    struct Value {
        var isRunning: Bool
        var name: String
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: TimerConfiguration) -> Value {
            NotiFeeder_WidgetControl.Value(isRunning: false, name: configuration.timerName)
        }

        func currentValue(configuration: TimerConfiguration) async throws -> Value {
            let isRunning = true // Check if the timer is running
            return NotiFeeder_WidgetControl.Value(isRunning: isRunning, name: configuration.timerName)
        }
    }
}

struct TimerConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Timer Name Configuration"

    @Parameter(title: "Timer Name", default: "Timer")
    var timerName: String
}

struct StartTimerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Start a timer"

    @Parameter(title: "Timer Name")
    var name: String

    @Parameter(title: "Timer is running")
    var value: Bool

    init() {}

    init(_ name: String) {
        self.name = name
    }

    func perform() async throws -> some IntentResult {
        // Start the timer…
        return .result()
    }
}
