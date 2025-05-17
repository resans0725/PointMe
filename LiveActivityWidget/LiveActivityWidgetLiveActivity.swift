//
//  LiveActivityWidgetLiveActivity.swift
//  LiveActivityWidget
//
//  Created by 永井涼 on 2025/05/17.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct LiveActivityWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
            var destinationName: String
            var distance: Double
            var angle: Double
        }

        var name: String // 例: "ナビゲーション"
}

struct LiveActivityWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivityWidgetAttributes.self) { context in
            // 🔒 Lock Screen / Notification UI
            VStack(spacing: 8) {
                Image(systemName: "arrow.up")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .rotationEffect(.degrees(context.state.angle))
                    .foregroundColor(.blue)
                Text(context.state.destinationName)
                    .font(.headline)
                Text("\(Int(context.state.distance)) m")
                    .font(.subheadline)
            }
            .padding()
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "arrow.up")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(context.state.angle))
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.destinationName)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.distance)) m")
                }
            } compactLeading: {
                Image(systemName: "arrow.up")
                    .rotationEffect(.degrees(context.state.angle))
            } compactTrailing: {
                Text("\(Int(context.state.distance))m")
            } minimal: {
                Image(systemName: "arrow.up")
                    .rotationEffect(.degrees(context.state.angle))
            }
        }
    }
}

extension LiveActivityWidgetAttributes {
    static var preview: LiveActivityWidgetAttributes {
        LiveActivityWidgetAttributes(name: "新宿駅")
    }
}

extension LiveActivityWidgetAttributes.ContentState {
    static var example: LiveActivityWidgetAttributes.ContentState {
        LiveActivityWidgetAttributes.ContentState(destinationName: "渋谷駅", distance: 320, angle: 45)
    }
}

#Preview("Notification", as: .content, using: LiveActivityWidgetAttributes.preview) {
   LiveActivityWidgetLiveActivity()
} contentStates: {
    LiveActivityWidgetAttributes.ContentState.example
}
