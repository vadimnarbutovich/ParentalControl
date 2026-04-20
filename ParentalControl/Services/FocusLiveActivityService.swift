import Foundation

#if canImport(ActivityKit)
import ActivityKit

struct FocusSessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endDate: Date
        var totalSeconds: Int
    }

    var title: String
}

@MainActor
final class FocusLiveActivityService {
    private var currentActivity: Activity<FocusSessionActivityAttributes>?

    func start(endsAt: Date, totalSeconds: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = FocusSessionActivityAttributes(title: "Focus Session")
        let state = FocusSessionActivityAttributes.ContentState(
            endDate: endsAt,
            totalSeconds: max(0, totalSeconds)
        )

        Task {
            await stop()
            do {
                let content = ActivityContent(state: state, staleDate: endsAt)
                currentActivity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } catch {
                // Silent fail: focus session should still work without Live Activity.
            }
        }
    }

    func stop() async {
        if let currentActivity {
            await currentActivity.end(nil, dismissalPolicy: .immediate)
            self.currentActivity = nil
            return
        }

        for activity in Activity<FocusSessionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

#else

@MainActor
final class FocusLiveActivityService {
    func start(endsAt: Date, totalSeconds: Int) {}
    func stop() async {}
}

#endif
