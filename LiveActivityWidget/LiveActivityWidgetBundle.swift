//
//  LiveActivityWidgetBundle.swift
//  LiveActivityWidget
//
//  Created by 永井涼 on 2025/05/17.
//

import WidgetKit
import SwiftUI

@main
struct LiveActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        LiveActivityWidget()
        LiveActivityWidgetLiveActivity()
    }
}
