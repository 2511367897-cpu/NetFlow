import Foundation
import ActivityKit

@available(iOS 16.2, *)
@MainActor
final class NetFlowLiveActivityManager {
    static let shared = NetFlowLiveActivityManager()

    private var lastUpdateAt = Date.distantPast
    private var hasRequestedThisSession = false
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

        let content = makeContent(records: records, plan: plan, rate: rate, now: now)

        if let existing = Activity<NetFlowActivityAttributes>.activities.first {
            await existing.update(content)
            return
        }

        // Only auto-create once during one app process lifetime. If the user
        // dismisses the Live Activity manually, do not immediately recreate it.
        guard !hasRequestedThisSession else { return }

        do {
            _ = try Activity<NetFlowActivityAttributes>.request(
                attributes: NetFlowActivityAttributes(title: "NetFlow"),
                content: content,
                pushType: nil
            )
            hasRequestedThisSession = true
        } catch {
            // A transient ActivityKit failure may recover later in the same session,
            // so only mark the automatic request as consumed after it succeeds.
        }
    }

    func updateExisting(
        records: [DailyUsageRecord],
        plan: DataPlan,
        rate: NetworkRate,
        now: Date = Date()
    ) async {
        guard let existing = Activity<NetFlowActivityAttributes>.activities.first else {
            return
        }

        let content = makeContent(records: records, plan: plan, rate: rate, now: now)
        await existing.update(content)
        lastUpdateAt = now
    }

    func endAll(immediately: Bool = true) async {
        let policy: ActivityUIDismissalPolicy = immediately ? .immediate : .default

        for activity in Activity<NetFlowActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: policy)
        }
    }

    private func makeContent(
        records: [DailyUsageRecord],
        plan: DataPlan,
        rate: NetworkRate,
        now: Date
    ) -> ActivityContent<NetFlowActivityAttributes.ContentState> {
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

        return ActivityContent(
            state: state,
            staleDate: now.addingTimeInterval(30)
        )
    }
}
