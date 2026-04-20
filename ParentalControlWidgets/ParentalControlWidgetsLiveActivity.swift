import ActivityKit
import WidgetKit
import SwiftUI

struct FocusSessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endDate: Date
        var totalSeconds: Int
    }

    var title: String
}

struct ParentalControlWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusSessionActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("live.focus.title")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    countdownText(until: context.state.endDate)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.green)
                }

                Text(L10n.totalTimeText(totalSeconds: context.state.totalSeconds))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))

                Text("live.focus.remaining")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.82))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "timer")
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdownText(until: context.state.endDate)
                        .font(.headline)
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("live.focus.title")
                        .font(.subheadline.weight(.semibold))
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(.green)
            } compactTrailing: {
                countdownText(until: context.state.endDate)
                    .font(.caption2)
                    .foregroundStyle(.green)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }
}

private extension ParentalControlWidgetsLiveActivity {
    @ViewBuilder
    func countdownText(until endDate: Date) -> some View {
        if endDate <= .now {
            Text("00:00")
                .monospacedDigit()
        } else {
            Text(timerInterval: .now...endDate, countsDown: true)
                .monospacedDigit()
        }
    }
}

private enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func totalTimeText(totalSeconds: Int) -> String {
        let minutes = max(0, totalSeconds / 60)
        return String(format: tr("live.focus.total"), minutes)
    }
}

#Preview("Notification", as: .content, using: FocusSessionActivityAttributes(title: "Focus Session")) {
   ParentalControlWidgetsLiveActivity()
} contentStates: {
    FocusSessionActivityAttributes.ContentState(
        endDate: Date().addingTimeInterval(24 * 60),
        totalSeconds: 25 * 60
    )
}
