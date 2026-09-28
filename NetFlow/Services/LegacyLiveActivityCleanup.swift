import Foundation
import ActivityKit

@available(iOS 16.2, *)
enum LegacyLiveActivityCleanup {
    static func endExistingActivities() async {
        for activity in Activity<NetFlowActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
