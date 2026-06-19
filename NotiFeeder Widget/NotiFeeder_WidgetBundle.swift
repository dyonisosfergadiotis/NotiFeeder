//
//  NotiFeeder_WidgetBundle.swift
//  NotiFeeder Widget
//
//  Created by Dyonisos Fergadiotis on 02.02.26.
//

import WidgetKit
import SwiftUI

@main
struct NotiFeeder_WidgetBundle: WidgetBundle {
    var body: some Widget {
        NotiFeeder_Widget_Small()
        NotiFeeder_Widget_Medium()
        NotiFeeder_Widget_Large()
        NotiFeeder_Widget_LockScreenRectangular()
        NotiFeeder_WidgetControl()
        if #available(iOS 16.2, *) {
            ReadingLiveActivityWidget()
        }
    }
}
