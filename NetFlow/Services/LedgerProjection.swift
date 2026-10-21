import Foundation

extension LedgerSnapshot {
    static func make(records: [DailyUsageRecord], at now: Date, sampledAt: Date,
                     planUsed: UInt64, planCapacity: UInt64,
                     continuousRequested: Bool, continuousRunning: Bool,
                     counterBits: Int?, warning: String?, calendar: Calendar = .current) -> Self {
        let day = calendar.startOfDay(for: now)
        let month = calendar.dateInterval(of: .month, for: now)!
        let today = records.filter { calendar.isDate($0.date, inSameDayAs: now) }
        let monthly = records.filter { $0.date >= month.start && $0.date < month.end }
        func sum(_ items: [DailyUsageRecord], _ key: KeyPath<DailyUsageRecord, UInt64>) -> UInt64 {
            items.reduce(0) { InterfaceCounters.add($0, $1[keyPath: key]) }
        }
        return Self(sampledAt: sampledAt, committedAt: now, dayStart: day, monthStart: month.start,
                    todayCellular: sum(today, \.cellularTotalBytes), todayWiFi: sum(today, \.wifiTotalBytes),
                    monthCellular: sum(monthly, \.cellularTotalBytes), monthWiFi: sum(monthly, \.wifiTotalBytes),
                    planUsed: planUsed, planCapacity: planCapacity,
                    continuousRequested: continuousRequested, continuousRunning: continuousRunning,
                    counterBits: counterBits, warning: warning)
    }
}
