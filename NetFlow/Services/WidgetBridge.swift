import Foundation
import WidgetKit

enum NetFlowWidgetBridge {
    static let appGroupID = "group.com.duyhoang.netflow"
    static let widgetKind = "NetFlowUsageWidget"

    private enum Key {
        static let todayTotal = "widget.today.total"
        static let todayCellular = "widget.today.cellular"
        static let todayWiFi = "widget.today.wifi"
        static let monthTotal = "widget.month.total"
        static let monthCellular = "widget.month.cellular"
        static let monthWiFi = "widget.month.wifi"
        static let planRemaining = "widget.plan.remaining"
        static let planUnlimited = "widget.plan.unlimited"
        static let rateDown = "widget.rate.down"
        static let rateUp = "widget.rate.up"
        static let updatedAt = "widget.updatedAt"

        static let rawWiFiReceived = "widget.raw.wifi.received"
        static let rawWiFiSent = "widget.raw.wifi.sent"
        static let rawCellularReceived = "widget.raw.cellular.received"
        static let rawCellularSent = "widget.raw.cellular.sent"
        static let rawTimestamp = "widget.raw.timestamp"
        static let rawAvailable = "widget.raw.available"

        static let dayKey = "widget.day.key"
        static let monthKey = "widget.month.key"
        static let lastReloadRequest = "widget.lastReloadRequest"
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func publish(
        records: [DailyUsageRecord],
        plan: DataPlan,
        rate: NetworkRate,
        snapshot: NetworkSnapshot,
        now: Date = Date()
    ) {
        guard let defaults else { return }

        let calendar = Calendar.current
        let today = records.first { calendar.isDateInToday($0.date) }
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? calendar.startOfDay(for: now)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now

        let monthRecords = records.filter { $0.date >= monthStart && $0.date < monthEnd }
        let monthTotal = monthRecords.reduce(UInt64(0)) { $0 &+ $1.totalBytes }
        let monthCellular = monthRecords.reduce(UInt64(0)) { $0 &+ $1.cellularTotalBytes }
        let monthWiFi = monthRecords.reduce(UInt64(0)) { $0 &+ $1.wifiTotalBytes }

        defaults.set(Double(today?.totalBytes ?? 0), forKey: Key.todayTotal)
        defaults.set(Double(today?.cellularTotalBytes ?? 0), forKey: Key.todayCellular)
        defaults.set(Double(today?.wifiTotalBytes ?? 0), forKey: Key.todayWiFi)
        defaults.set(Double(monthTotal), forKey: Key.monthTotal)
        defaults.set(Double(monthCellular), forKey: Key.monthCellular)
        defaults.set(Double(monthWiFi), forKey: Key.monthWiFi)

        if plan.isUnlimited {
            defaults.set(0, forKey: Key.planRemaining)
            defaults.set(true, forKey: Key.planUnlimited)
        } else {
            defaults.set(Double(plan.remainingBytes(records: records, at: now)), forKey: Key.planRemaining)
            defaults.set(false, forKey: Key.planUnlimited)
        }

        defaults.set(rate.cellularDown + rate.wifiDown, forKey: Key.rateDown)
        defaults.set(rate.cellularUp + rate.wifiUp, forKey: Key.rateUp)
        defaults.set(now.timeIntervalSince1970, forKey: Key.updatedAt)
        defaults.set(Self.dayKey(for: now), forKey: Key.dayKey)
        defaults.set(Self.monthKey(for: now), forKey: Key.monthKey)

        if snapshot.timestamp != .distantPast {
            defaults.set(Double(snapshot.wifi.received), forKey: Key.rawWiFiReceived)
            defaults.set(Double(snapshot.wifi.sent), forKey: Key.rawWiFiSent)
            defaults.set(Double(snapshot.cellular.received), forKey: Key.rawCellularReceived)
            defaults.set(Double(snapshot.cellular.sent), forKey: Key.rawCellularSent)
            defaults.set(snapshot.timestamp.timeIntervalSince1970, forKey: Key.rawTimestamp)
            defaults.set(true, forKey: Key.rawAvailable)
        }

        let lastReload = defaults.double(forKey: Key.lastReloadRequest)
        if now.timeIntervalSince1970 - lastReload >= 15 {
            defaults.set(now.timeIntervalSince1970, forKey: Key.lastReloadRequest)
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private static func monthKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)"
    }
}

enum NetworkSnapshotCache {
    private static let key = "NetFlow.lastNetworkSnapshot"

    static func load() -> NetworkSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder.netFlow.decode(NetworkSnapshot.self, from: data)
    }

    static func save(_ snapshot: NetworkSnapshot) {
        guard snapshot.timestamp != .distantPast,
              let data = try? JSONEncoder.pretty.encode(snapshot) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
