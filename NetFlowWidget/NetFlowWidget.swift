import WidgetKit
import SwiftUI
import AppIntents
import Darwin

private let netFlowWidgetKind = "NetFlowUsageWidget"
private let configuredWidgetKind = "NetFlowConfiguredUsageWidget"

struct NetFlowWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "NetFlow 套餐设置"
    static var description = IntentDescription("小组件独立保存套餐设置和流量记录。重置日支持 1–28 日。")

    @Parameter(title: "套餐总量（GB）", default: 30.0)
    var planCapacityGB: Double

    @Parameter(title: "每月重置日", default: 1)
    var resetDay: Int

    @Parameter(title: "不限量套餐", default: false)
    var unlimited: Bool
}

private struct RawCounters {
    var wifiReceived: UInt64
    var wifiSent: UInt64
    var cellularReceived: UInt64
    var cellularSent: UInt64

    static let zero = RawCounters(
        wifiReceived: 0,
        wifiSent: 0,
        cellularReceived: 0,
        cellularSent: 0
    )
}

private struct TrafficDelta {
    var wifiReceived: UInt64
    var wifiSent: UInt64
    var cellularReceived: UInt64
    var cellularSent: UInt64

    var wifiTotal: UInt64 { wifiReceived &+ wifiSent }
    var cellularTotal: UInt64 { cellularReceived &+ cellularSent }
    var total: UInt64 { wifiTotal &+ cellularTotal }

    static let zero = TrafficDelta(
        wifiReceived: 0,
        wifiSent: 0,
        cellularReceived: 0,
        cellularSent: 0
    )
}

private struct DailyBucket: Codable {
    var total: UInt64 = 0
    var cellular: UInt64 = 0
    var wifi: UInt64 = 0

    mutating func add(total: UInt64, cellular: UInt64, wifi: UInt64) {
        self.total = saturatingAdd(self.total, total)
        self.cellular = saturatingAdd(self.cellular, cellular)
        self.wifi = saturatingAdd(self.wifi, wifi)
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}

private enum RawCounterReader {
    static func read() -> RawCounters? {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else {
            return nil
        }
        defer { freeifaddrs(first) }

        var result = RawCounters.zero
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let interface = cursor {
            let item = interface.pointee
            let name = String(cString: item.ifa_name)

            if item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let rawData = item.ifa_data {
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee

                if name == "en0" {
                    result.wifiReceived &+= UInt64(data.ifi_ibytes)
                    result.wifiSent &+= UInt64(data.ifi_obytes)
                } else if name.hasPrefix("pdp_ip") {
                    result.cellularReceived &+= UInt64(data.ifi_ibytes)
                    result.cellularSent &+= UInt64(data.ifi_obytes)
                }
            }

            cursor = item.ifa_next
        }

        return result
    }
}

private struct UsageSnapshot {
    var todayTotal: UInt64 = 0
    var todayCellular: UInt64 = 0
    var todayWiFi: UInt64 = 0
    var monthTotal: UInt64 = 0
    var monthCellular: UInt64 = 0
    var monthWiFi: UInt64 = 0
    var allTimeTotal: UInt64 = 0

    var planCapacity: UInt64 = 0
    var planUsed: UInt64 = 0
    var planRemaining: UInt64 = 0
    var planUnlimited = false
    var resetDay = 1
    var planConfigured = true

    var down: Double = 0
    var up: Double = 0
    var updatedAt = Date()
    var isPreview = false
}

private enum WidgetTrafficStore {
    private enum Key {
        static let rawWiFiReceived = "self.raw.wifi.received"
        static let rawWiFiSent = "self.raw.wifi.sent"
        static let rawCellularReceived = "self.raw.cellular.received"
        static let rawCellularSent = "self.raw.cellular.sent"
        static let rawTimestamp = "self.raw.timestamp"
        static let rawAvailable = "self.raw.available"
        static let hasMeasurement = "self.hasMeasurement"
        static let allTimeTotal = "self.alltime.total"
        static let rateDown = "self.rate.down"
        static let rateUp = "self.rate.up"
        static let updatedAt = "self.updatedAt"
        static let dailyBuckets = "self.dailyBuckets.v2"
    }

    private static let defaults = UserDefaults.standard
    private static let calendar = Calendar.current
    private static let sampleLock = NSLock()

    static func forceRefresh() async {
        sampleCurrent(now: Date())

        do {
            try await Task.sleep(nanoseconds: 800_000_000)
        } catch {
            return
        }

        sampleCurrent(now: Date())
    }

    private static func sampleCurrent(now: Date) {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        if let current = RawCounterReader.read() {
            consume(current: current, now: now)
        }
    }

    private static func consume(current: RawCounters, now: Date) {
        let currentTimestamp = now.timeIntervalSince1970

        if defaults.bool(forKey: Key.rawAvailable) {
            let previous = RawCounters(
                wifiReceived: storedBytes(Key.rawWiFiReceived),
                wifiSent: storedBytes(Key.rawWiFiSent),
                cellularReceived: storedBytes(Key.rawCellularReceived),
                cellularSent: storedBytes(Key.rawCellularSent)
            )
            let previousTimestamp = defaults.double(forKey: Key.rawTimestamp)

            if previousTimestamp > 0, previousTimestamp < currentTimestamp,
               countersAreValid(current: current, previous: previous) {
                let delta = TrafficDelta(
                    wifiReceived: current.wifiReceived - previous.wifiReceived,
                    wifiSent: current.wifiSent - previous.wifiSent,
                    cellularReceived: current.cellularReceived - previous.cellularReceived,
                    cellularSent: current.cellularSent - previous.cellularSent
                )
                record(delta: delta, from: Date(timeIntervalSince1970: previousTimestamp), to: now)
                defaults.set(true, forKey: Key.hasMeasurement)

                let elapsed = currentTimestamp - previousTimestamp
                if elapsed >= 0.2 && elapsed <= 10 {
                    defaults.set(
                        Double(delta.wifiReceived &+ delta.cellularReceived) / elapsed,
                        forKey: Key.rateDown
                    )
                    defaults.set(
                        Double(delta.wifiSent &+ delta.cellularSent) / elapsed,
                        forKey: Key.rateUp
                    )
                } else {
                    defaults.set(0, forKey: Key.rateDown)
                    defaults.set(0, forKey: Key.rateUp)
                }
            } else {
                defaults.set(0, forKey: Key.rateDown)
                defaults.set(0, forKey: Key.rateUp)
            }
        }

        defaults.set(NSNumber(value: current.wifiReceived), forKey: Key.rawWiFiReceived)
        defaults.set(NSNumber(value: current.wifiSent), forKey: Key.rawWiFiSent)
        defaults.set(NSNumber(value: current.cellularReceived), forKey: Key.rawCellularReceived)
        defaults.set(NSNumber(value: current.cellularSent), forKey: Key.rawCellularSent)
        defaults.set(currentTimestamp, forKey: Key.rawTimestamp)
        defaults.set(true, forKey: Key.rawAvailable)
        defaults.set(currentTimestamp, forKey: Key.updatedAt)
    }

    static func sampleAndLoad(
        configuration: NetFlowWidgetConfigurationIntent,
        now: Date = Date()
    ) -> UsageSnapshot {
        sampleAndLoad(planCapacityGB: configuration.planCapacityGB,
                      resetDay: configuration.resetDay,
                      unlimited: configuration.unlimited,
                      now: now)
    }

    static func sampleAndLoad(
        planCapacityGB: Double,
        resetDay: Int,
        unlimited: Bool,
        now: Date = Date()
    ) -> UsageSnapshot {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        if let current = RawCounterReader.read() {
            consume(current: current, now: now)
        }
        return load(planCapacityGB: planCapacityGB, resetDay: resetDay,
                    unlimited: unlimited, now: now)
    }

    private static func load(
        planCapacityGB: Double,
        resetDay requestedResetDay: Int,
        unlimited: Bool,
        now: Date = Date()
    ) -> UsageSnapshot {
        let buckets = loadBuckets()
        let todayKey = key(for: now)
        let today = buckets[todayKey] ?? DailyBucket()

        let monthInterval = currentMonthInterval(now)
        let monthBuckets = buckets.compactMap { key, bucket -> DailyBucket? in
            guard let date = date(from: key), monthInterval.contains(date) else { return nil }
            return bucket
        }

        let monthTotal = monthBuckets.reduce(UInt64(0)) { saturatingAdd($0, $1.total) }
        let monthCellular = monthBuckets.reduce(UInt64(0)) { saturatingAdd($0, $1.cellular) }
        let monthWiFi = monthBuckets.reduce(UInt64(0)) { saturatingAdd($0, $1.wifi) }

        let resetDay = min(max(requestedResetDay, 1), 28)
        let cycleStart = currentCycleStart(now: now, resetDay: resetDay)
        let planUsed = buckets.compactMap { key, bucket -> UInt64? in
            guard let date = date(from: key), date >= cycleStart && date <= now else { return nil }
            return bucket.cellular
        }.reduce(UInt64(0), saturatingAdd)

        let safeGB = planCapacityGB.isFinite
            ? min(max(planCapacityGB, 0), 100_000)
            : 0
        let capacity = unlimited ? UInt64(0) : UInt64(safeGB * 1_000_000_000)
        let remaining = unlimited ? 0 : (capacity > planUsed ? capacity - planUsed : 0)

        let timestamp = defaults.double(forKey: Key.updatedAt)

        return UsageSnapshot(
            todayTotal: today.total,
            todayCellular: today.cellular,
            todayWiFi: today.wifi,
            monthTotal: monthTotal,
            monthCellular: monthCellular,
            monthWiFi: monthWiFi,
            allTimeTotal: max(storedBytes(Key.allTimeTotal), monthTotal),
            planCapacity: capacity,
            planUsed: planUsed,
            planRemaining: remaining,
            planUnlimited: unlimited,
            resetDay: resetDay,
            down: defaults.double(forKey: Key.rateDown),
            up: defaults.double(forKey: Key.rateUp),
            updatedAt: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : now,
            isPreview: !defaults.bool(forKey: Key.hasMeasurement)
        )
    }

    private static func record(delta: TrafficDelta, from start: Date, to end: Date) {
        guard delta.total > 0 else { return }

        let safeStart = start == .distantPast || start >= end ? end : start
        var buckets = loadBuckets()
        var cursor = safeStart
        var remaining = delta

        while cursor < end {
            let dayStart = calendar.startOfDay(for: cursor)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? end
            let segmentEnd = min(end, nextDay)
            let isLast = segmentEnd >= end

            let segment: TrafficDelta
            if isLast {
                segment = remaining
            } else {
                let remainingDuration = max(end.timeIntervalSince(cursor), 0.001)
                let fraction = min(max(segmentEnd.timeIntervalSince(cursor) / remainingDuration, 0), 1)

                func portion(_ value: UInt64) -> UInt64 {
                    let scaled = (Double(value) * fraction).rounded()
                    return scaled >= Double(UInt64.max) ? value : UInt64(max(scaled, 0))
                }

                segment = TrafficDelta(
                    wifiReceived: portion(remaining.wifiReceived),
                    wifiSent: portion(remaining.wifiSent),
                    cellularReceived: portion(remaining.cellularReceived),
                    cellularSent: portion(remaining.cellularSent)
                )
                remaining = TrafficDelta(
                    wifiReceived: remaining.wifiReceived - segment.wifiReceived,
                    wifiSent: remaining.wifiSent - segment.wifiSent,
                    cellularReceived: remaining.cellularReceived - segment.cellularReceived,
                    cellularSent: remaining.cellularSent - segment.cellularSent
                )
            }

            let bucketKey = key(for: cursor)
            var bucket = buckets[bucketKey] ?? DailyBucket()
            bucket.add(total: segment.total, cellular: segment.cellularTotal, wifi: segment.wifiTotal)
            buckets[bucketKey] = bucket
            cursor = segmentEnd
        }

        let oldAllTime = storedBytes(Key.allTimeTotal)
        defaults.set(NSNumber(value: saturatingAdd(oldAllTime, delta.total)), forKey: Key.allTimeTotal)

        prune(&buckets, keepingDays: 400, now: end)
        saveBuckets(buckets)
    }

    private static func loadBuckets() -> [String: DailyBucket] {
        guard let data = defaults.data(forKey: Key.dailyBuckets),
              let decoded = try? JSONDecoder().decode([String: DailyBucket].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func saveBuckets(_ buckets: [String: DailyBucket]) {
        guard let data = try? JSONEncoder().encode(buckets) else { return }
        defaults.set(data, forKey: Key.dailyBuckets)
    }

    private static func prune(_ buckets: inout [String: DailyBucket], keepingDays: Int, now: Date) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepingDays, to: calendar.startOfDay(for: now)) else {
            return
        }
        buckets = buckets.filter { key, _ in
            guard let date = date(from: key) else { return false }
            return date >= cutoff
        }
    }

    private static func currentMonthInterval(_ now: Date) -> DateInterval {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        return DateInterval(start: start, end: end)
    }

    private static func currentCycleStart(now: Date, resetDay: Int) -> Date {
        let components = calendar.dateComponents([.year, .month], from: now)
        let year = components.year ?? 2001
        let month = components.month ?? 1

        func start(year: Int, month: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: resetDay)) ?? now
        }

        let thisMonth = start(year: year, month: month)
        if now >= thisMonth {
            return thisMonth
        }

        let previousMonthAnchor = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? now
        let previous = calendar.dateComponents([.year, .month], from: previousMonthAnchor)
        return start(year: previous.year ?? year, month: previous.month ?? month)
    }

    private static func key(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func countersAreValid(current: RawCounters, previous: RawCounters) -> Bool {
        current.wifiReceived >= previous.wifiReceived &&
        current.wifiSent >= previous.wifiSent &&
        current.cellularReceived >= previous.cellularReceived &&
        current.cellularSent >= previous.cellularSent
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private static func storedBytes(_ key: String) -> UInt64 {
        defaults.object(forKey: key).flatMap { $0 as? NSNumber }?.uint64Value ?? 0
    }
}

struct RefreshNetFlowIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新流量"
    static var description = IntentDescription("立即重新读取当前设备的网络流量计数。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await WidgetTrafficStore.forceRefresh()
        WidgetCenter.shared.reloadTimelines(ofKind: netFlowWidgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: configuredWidgetKind)
        return .result()
    }
}

private struct NetFlowEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

private struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> NetFlowEntry {
        NetFlowEntry(
            date: .now,
            snapshot: UsageSnapshot(
                todayTotal: 0,
                todayCellular: 0,
                todayWiFi: 0,
                monthTotal: 0,
                monthCellular: 0,
                monthWiFi: 0,
                allTimeTotal: 0,
                planCapacity: 30_000_000_000,
                planUsed: 0,
                planRemaining: 30_000_000_000,
                planUnlimited: false,
                resetDay: 1,
                down: 0,
                up: 0,
                updatedAt: .now,
                isPreview: true
            )
        )
    }

    func snapshot(
        for configuration: NetFlowWidgetConfigurationIntent,
        in context: Context
    ) async -> NetFlowEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        return NetFlowEntry(
            date: .now,
            snapshot: WidgetTrafficStore.sampleAndLoad(configuration: configuration)
        )
    }

    func timeline(
        for configuration: NetFlowWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<NetFlowEntry> {
        let now = Date()
        let snapshot = WidgetTrafficStore.sampleAndLoad(configuration: configuration, now: now)
        let entry = NetFlowEntry(date: now, snapshot: snapshot)
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(5 * 60)))
    }
}

// The 4.2.8 widget used StaticConfiguration with netFlowWidgetKind. Keeping
// that kind static lets iOS restore existing instances without an intent.
private struct LegacyProvider: TimelineProvider {
    func placeholder(in context: Context) -> NetFlowEntry {
        let original = Provider().placeholder(in: context)
        var snapshot = original.snapshot
        snapshot.planConfigured = false
        return NetFlowEntry(date: original.date, snapshot: snapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (NetFlowEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NetFlowEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [entry(now: now)],
                            policy: .after(now.addingTimeInterval(5 * 60))))
    }

    private func entry(now: Date) -> NetFlowEntry {
        var snapshot = WidgetTrafficStore.sampleAndLoad(
            planCapacityGB: 0, resetDay: 1, unlimited: true, now: now
        )
        snapshot.planConfigured = false
        return NetFlowEntry(date: now, snapshot: snapshot)
    }
}

private enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value),
            countStyle: .decimal
        )
    }

    static func rate(_ value: Double) -> String {
        let bits = max(value, 0) * 8
        if bits >= 1_000_000 {
            return String(format: "%.1f Mbps", bits / 1_000_000)
        }
        if bits >= 1_000 {
            return String(format: "%.0f Kbps", bits / 1_000)
        }
        return String(format: "%.0f bps", bits)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private struct NetFlowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NetFlowEntry

    private var planProgress: Double {
        guard !entry.snapshot.planUnlimited,
              entry.snapshot.planCapacity > 0 else { return 0 }
        return min(max(Double(entry.snapshot.planUsed) / Double(entry.snapshot.planCapacity), 0), 1)
    }

    private var planPercent: Int {
        Int((planProgress * 100).rounded())
    }

    private func trafficText(_ value: UInt64) -> String {
        entry.snapshot.isPreview ? "—" : Format.bytes(value)
    }

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                medium
            case .accessoryRectangular:
                accessoryRectangular
            case .accessoryInline:
                accessoryInline
            default:
                small
            }
        }
        .widgetURL(URL(string: "netflow://open"))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("NetFlow", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.indigo)
                Spacer()
                refreshButton
            }

            HStack(spacing: 10) {
                compactMetric("今日", entry.snapshot.todayTotal)
                compactMetric("本月", entry.snapshot.monthTotal)
            }

            HStack {
                Text("累计")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(trafficText(entry.snapshot.allTimeTotal))
                    .font(.system(size: 10, weight: .semibold))
            }

            Divider()

            if entry.snapshot.isPreview {
                Text(entry.snapshot.planConfigured ? "等待下次采样；长按可设置套餐" : "等待下次采样")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if !entry.snapshot.planConfigured {
                Text("套餐设置请添加“NetFlow 套餐”小组件")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else if entry.snapshot.planUnlimited {
                HStack {
                    Text("套餐")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("不限量")
                        .font(.system(size: 10, weight: .bold))
                }
            } else {
                HStack {
                    Text("套餐已用")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(planPercent)%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(planProgress >= 0.9 ? .red : .indigo)
                }

                ProgressView(value: planProgress)
                    .tint(planProgress >= 0.9 ? .red : .indigo)

                HStack {
                    Text(Format.bytes(entry.snapshot.planUsed) + " / " + Format.bytes(entry.snapshot.planCapacity))
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Spacer()
                    Text(Format.time(entry.snapshot.updatedAt))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .widgetBackground()
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("NetFlow 流量", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.indigo)
                Spacer()
                Text("更新 " + Format.time(entry.snapshot.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                refreshButton
            }

            HStack(spacing: 8) {
                mediumMetric("今日", entry.snapshot.todayTotal, "sun.max.fill", .orange)
                mediumMetric("本月", entry.snapshot.monthTotal, "calendar", .indigo)
                mediumMetric("累计", entry.snapshot.allTimeTotal, "sum", .cyan)
            }

            Divider()

            if entry.snapshot.isPreview {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("等待下次采样")
                            .font(.caption.weight(.semibold))
                        Text("长按小组件 → 编辑小组件，可设置套餐总量和重置日")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            } else if !entry.snapshot.planConfigured {
                HStack {
                    Text("今日、本月和累计流量独立统计")
                        .font(.caption2)
                    Spacer()
                    speedPair
                }
            } else if entry.snapshot.planUnlimited {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("套餐")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("不限量")
                            .font(.headline.weight(.bold))
                    }
                    Spacer()
                    speedPair
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("套餐使用 · 每月 \(entry.snapshot.resetDay) 日重置")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(Format.bytes(entry.snapshot.planUsed) + " / " + Format.bytes(entry.snapshot.planCapacity))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("剩余 " + Format.bytes(entry.snapshot.planRemaining))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(planPercent)%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(planProgress >= 0.9 ? .red : .indigo)
                }

                ProgressView(value: planProgress)
                    .tint(planProgress >= 0.9 ? .red : .indigo)

                HStack {
                    speedPair
                    Spacer()
                    Text(
                        "蜂窝 " + Format.bytes(entry.snapshot.monthCellular)
                        + " · Wi-Fi " + Format.bytes(entry.snapshot.monthWiFi)
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                }
            }
        }
        .padding()
        .widgetBackground()
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.snapshot.isPreview {
                Text("NetFlow · 等待采样")
                    .font(.headline)
                Text("添加后开始统计")
                    .font(.caption2)
            } else {
                Text("今日 " + trafficText(entry.snapshot.todayTotal) + " · 本月 " + trafficText(entry.snapshot.monthTotal))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if entry.snapshot.isPreview {
                EmptyView()
            } else if !entry.snapshot.planConfigured {
                Text("累计 " + trafficText(entry.snapshot.allTimeTotal))
                    .font(.caption2)
            } else if entry.snapshot.planUnlimited {
                Text("累计 " + trafficText(entry.snapshot.allTimeTotal) + " · 不限量")
                    .font(.caption2)
            } else {
                Text("套餐 " + String(planPercent) + "% · 剩余 " + Format.bytes(entry.snapshot.planRemaining))
                    .font(.caption2)
            }
        }
    }

    private var accessoryInline: some View {
        if entry.snapshot.isPreview {
            Text("NetFlow · 等待采样")
        } else if !entry.snapshot.planConfigured {
            Text("今日 " + trafficText(entry.snapshot.todayTotal) + " · 本月 " + trafficText(entry.snapshot.monthTotal))
        } else if entry.snapshot.planUnlimited {
            Text("今日 " + trafficText(entry.snapshot.todayTotal) + " · 不限量")
        } else {
            Text("今日 " + trafficText(entry.snapshot.todayTotal) + " · 套餐 " + String(planPercent) + "%")
        }
    }

    private func compactMetric(_ title: String, _ value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(entry.snapshot.isPreview ? "—" : Format.bytes(value))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mediumMetric(_ title: String, _ value: UInt64, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
            Text(entry.snapshot.isPreview ? "—" : Format.bytes(value))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speedPair: some View {
        HStack(spacing: 8) {
            Label(Format.rate(entry.snapshot.down), systemImage: "arrow.down")
                .foregroundStyle(.blue)
            Label(Format.rate(entry.snapshot.up), systemImage: "arrow.up")
                .foregroundStyle(.green)
        }
        .font(.system(size: 9, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }

    private var refreshButton: some View {
        Button(intent: RefreshNetFlowIntent()) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.indigo)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("立即刷新流量")
    }
}

private extension View {
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(for: .widget) {
                LinearGradient(
                    colors: [
                        Color(uiColor: .secondarySystemBackground),
                        Color.indigo.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            self.background(Color(uiColor: .secondarySystemBackground))
        }
    }
}

struct NetFlowUsageWidget: Widget {
    let kind = netFlowWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LegacyProvider()) { entry in
            NetFlowWidgetView(entry: entry)
        }
        .configurationDisplayName("NetFlow 流量")
        .description("兼容旧小组件，独立统计今日、本月和累计流量。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

struct NetFlowConfiguredWidget: Widget {
    let kind = configuredWidgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: NetFlowWidgetConfigurationIntent.self,
            provider: Provider()
        ) { entry in
            NetFlowWidgetView(entry: entry)
        }
        .configurationDisplayName("NetFlow 套餐")
        .description("独立统计流量并设置套餐；约每 5 分钟请求更新，实际由 iOS 调度。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct NetFlowWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetFlowUsageWidget()
        NetFlowConfiguredWidget()
    }
}
