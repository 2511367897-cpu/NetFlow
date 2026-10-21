import Foundation

/// A committed projection of the app ledger. The extension never samples or adds bytes.
struct LedgerSnapshot: Codable, Equatable {
    var schema = 1
    var sampledAt: Date
    var committedAt: Date
    var dayStart: Date
    var monthStart: Date
    var todayCellular: UInt64
    var todayWiFi: UInt64
    var monthCellular: UInt64
    var monthWiFi: UInt64
    var planUsed: UInt64
    var planCapacity: UInt64
    var continuousRequested: Bool
    var continuousRunning: Bool
    var counterBits: Int?
    var warning: String?

    func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(sampledAt) > 120 || sampledAt > date.addingTimeInterval(5)
    }

    func todayCellular(at date: Date, calendar: Calendar = .current) -> UInt64? {
        calendar.isDate(dayStart, inSameDayAs: date) ? todayCellular : nil
    }

    func monthCellular(at date: Date, calendar: Calendar = .current) -> UInt64? {
        guard let start = calendar.dateInterval(of: .month, for: date)?.start,
              calendar.isDate(start, inSameDayAs: monthStart) else { return nil }
        return monthCellular
    }
}

struct MonitoringEvent: Codable, Equatable {
    var date: Date
    var message: String
}
