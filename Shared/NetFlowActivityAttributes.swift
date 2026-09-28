import Foundation
import ActivityKit

@available(iOS 16.2, *)
struct NetFlowActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var todayTotal: UInt64
        var todayCellular: UInt64
        var todayWiFi: UInt64
        var monthTotal: UInt64
        var downloadBytesPerSecond: Double
        var uploadBytesPerSecond: Double
        var planRemaining: UInt64
        var planUnlimited: Bool
        var updatedAt: Date
    }

    var title: String
}
