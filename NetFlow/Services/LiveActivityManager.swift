import Foundation
import ActivityKit

@available(iOS 16.2, *)
@MainActor
final class NetFlowLiveActivityManager {
    static let shared = NetFlowLiveActivityManager()

    private var lastUpdateAt = Date.distantPast
    private let minimumUpdateInterval: TimeInterval = 5

    private init() {}

    func startOrUpdate(
        records: [DailyUsageRecord],
        plan: DataPlan,
        rate: NetworkRate,
        force: Bool = false,
        now: Date = Date()
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if !force, now.timeIntervalSince(lastUpdateAt) < minimumUpdateInterval {
            return
        }
        lastUpdateAt = now

        let calendar = Calendar.current
        let today = records.first { calendar.isDateInToday($0.date) }

        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? calendar.startOfDay(for: now)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now
        let monthRecords = records.filter { $0.date >= monthStart && $0.date < monthEnd }
        let monthTotal = monthRecords.reduce(UInt64(0)) { $0 &+ $1.totalBytes }

        let state = NetFlowActivityAttributes.ContentState(
            todayTotal: today?.totalBytes ?? 0,
            todayCellular: today?.cellularTotalBytes ?? 0,
            todayWiFi: today?.wifiTotalBytes ?? 0,
            monthTotal: monthTotal,
            downloadBytesPerSecond: rate.cellularDown + rate.wifiDown,
            uploadBytesPerSecond: rate.cellularUp + rate.wifiUp,
            planRemaining: plan.isUnlimited ? 0 : plan.remainingBytes(records: records, at: now),
            planUnlimited: plan.isUnlimited,
            updatedAt: now
        )

        let content = ActivityContent(
            state: state,
            staleDate: now.addingTimeInterval(30)
        )

        if let existing = Activity<NetFlowActivityAttributes>.activities.first {
            await existing.update(content)
            return
        }

        do {
            _ = try Activity<NetFlowActivityAttributes>.request(
                attributes: NetFlowActivityAttributes(title: "NetFlow"),
                content: content,
                pushType: nil
            )
        } catch {
            // Live Activity is optional. Failure should never block traffic sampling.
        }
    }

    func endAll(immediately: Bool = true) async {
        let policy: ActivityUIDismissalPolicy = immediately ? .immediate : .default

        for activity in Activity<NetFlowActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: policy)
        }
    }
}
