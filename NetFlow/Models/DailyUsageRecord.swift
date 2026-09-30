import Foundation

struct DailyUsageRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var wifiReceived: UInt64
    var wifiSent: UInt64
    var cellularReceived: UInt64
    var cellularSent: UInt64
    var firstUpdated: Date
    var lastUpdated: Date
    var isEstimated = false

    init(date: Date, delta: NetworkDelta, firstUpdated: Date, lastUpdated: Date) {
        self.date = date
        wifiReceived = delta.wifiReceived
        wifiSent = delta.wifiSent
        cellularReceived = delta.cellularReceived
        cellularSent = delta.cellularSent
        self.firstUpdated = firstUpdated
        self.lastUpdated = lastUpdated
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, wifiReceived, wifiSent, cellularReceived, cellularSent
        case firstUpdated, lastUpdated, isEstimated
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try values.decode(Date.self, forKey: .date)
        wifiReceived = try values.decode(UInt64.self, forKey: .wifiReceived)
        wifiSent = try values.decode(UInt64.self, forKey: .wifiSent)
        cellularReceived = try values.decode(UInt64.self, forKey: .cellularReceived)
        cellularSent = try values.decode(UInt64.self, forKey: .cellularSent)
        firstUpdated = try values.decodeIfPresent(Date.self, forKey: .firstUpdated) ?? date
        lastUpdated = try values.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? date
        isEstimated = try values.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
    }

    mutating func add(_ delta: NetworkDelta) {
        wifiReceived = InterfaceCounters.add(wifiReceived, delta.wifiReceived)
        wifiSent = InterfaceCounters.add(wifiSent, delta.wifiSent)
        cellularReceived = InterfaceCounters.add(cellularReceived, delta.cellularReceived)
        cellularSent = InterfaceCounters.add(cellularSent, delta.cellularSent)
    }

    var wifiTotalBytes: UInt64 { InterfaceCounters.add(wifiReceived, wifiSent) }
    var cellularTotalBytes: UInt64 { InterfaceCounters.add(cellularReceived, cellularSent) }
    var totalBytes: UInt64 { InterfaceCounters.add(wifiTotalBytes, cellularTotalBytes) }
}
