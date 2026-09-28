import WidgetKit
import SwiftUI
import AppIntents
import Darwin

private let netFlowGroupID = "group.com.duyhoang.netflow"
private let netFlowWidgetKind = "NetFlowUsageWidget"

private enum SharedKey {
    static let todayTotal = "widget.today.total"
    static let todayCellular = "widget.today.cellular"
    static let todayWiFi = "widget.today.wifi"
    static let monthTotal = "widget.month.total"
    static let monthCellular = "widget.month.cellular"
    static let monthWiFi = "widget.month.wifi"
    static let allTimeTotal = "widget.alltime.total"
    static let planCapacity = "widget.plan.capacity"
    static let planUsed = "widget.plan.used"
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
    static let resetToken = "widget.reset.token"
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

private enum RawCounterReader {
    static func read() -> RawCounters {
        var interfaceList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceList) == 0, let first = interfaceList else {
            return .zero
        }
        defer { freeifaddrs(first) }

        var result = RawCounters.zero
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let interface = cursor {
            let item = interface.pointee
            let name = String(cString: item.ifa_name)

            if let rawData = item.ifa_data {
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
    var hasSharedContainer = false
    var hasAppSync = false
    var isPreview = false
    var down: Double = 0
    var up: Double = 0
    var updatedAt = Date()
}

private enum SharedTrafficStore {
    // 小组件把自己的计数保存在扩展自身的 UserDefaults 中。
    // 即使重签时 App Group 权限被裁掉，Widget 仍然可以独立工作。
    private static var defaults: UserDefaults { .standard }

    private static var hasSharedContainer: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: netFlowGroupID
        ) != nil
    }

    private static var appGroupDefaults: UserDefaults? {
        guard hasSharedContainer else { return nil }
        return UserDefaults(suiteName: netFlowGroupID)
    }

    private static let lastAppSyncKey = "widget.local.lastAppSync"

    static func sample(now: Date = Date()) -> UsageSnapshot {
        let defaults = defaults
        syncFromAppIfNewer(into: defaults)
        resetPeriodIfNeeded(defaults: defaults, now: now)

        let current = RawCounterReader.read()
        let currentTimestamp = now.timeIntervalSince1970

        if defaults.bool(forKey: SharedKey.rawAvailable) {
            let previous = RawCounters(
                wifiReceived: bytes(defaults.double(forKey: SharedKey.rawWiFiReceived)),
                wifiSent: bytes(defaults.double(forKey: SharedKey.rawWiFiSent)),
                cellularReceived: bytes(defaults.double(forKey: SharedKey.rawCellularReceived)),
                cellularSent: bytes(defaults.double(forKey: SharedKey.rawCellularSent))
            )
            let previousTimestamp = defaults.double(forKey: SharedKey.rawTimestamp)

            if countersAreValid(current: current, previous: previous) {
                let wifiReceived = current.wifiReceived - previous.wifiReceived
                let wifiSent = current.wifiSent - previous.wifiSent
                let cellularReceived = current.cellularReceived - previous.cellularReceived
                let cellularSent = current.cellularSent - previous.cellularSent

                let wifiDelta = wifiReceived &+ wifiSent
                let cellularDelta = cellularReceived &+ cellularSent
                let totalDelta = wifiDelta &+ cellularDelta

                add(totalDelta, to: SharedKey.todayTotal, defaults: defaults)
                add(wifiDelta, to: SharedKey.todayWiFi, defaults: defaults)
                add(cellularDelta, to: SharedKey.todayCellular, defaults: defaults)
                add(totalDelta, to: SharedKey.monthTotal, defaults: defaults)
                add(wifiDelta, to: SharedKey.monthWiFi, defaults: defaults)
                add(cellularDelta, to: SharedKey.monthCellular, defaults: defaults)
                add(totalDelta, to: SharedKey.allTimeTotal, defaults: defaults)
                add(cellularDelta, to: SharedKey.planUsed, defaults: defaults)

                if !defaults.bool(forKey: SharedKey.planUnlimited) {
                    let remaining = bytes(defaults.double(forKey: SharedKey.planRemaining))
                    defaults.set(
                        Double(remaining > cellularDelta ? remaining - cellularDelta : 0),
                        forKey: SharedKey.planRemaining
                    )
                }

                let elapsed = currentTimestamp - previousTimestamp
                if elapsed > 0.20 && elapsed <= 10 {
                    defaults.set(
                        Double(wifiReceived &+ cellularReceived) / elapsed,
                        forKey: SharedKey.rateDown
                    )
                    defaults.set(
                        Double(wifiSent &+ cellularSent) / elapsed,
                        forKey: SharedKey.rateUp
                    )
                }
            }
        }

        defaults.set(Double(current.wifiReceived), forKey: SharedKey.rawWiFiReceived)
        defaults.set(Double(current.wifiSent), forKey: SharedKey.rawWiFiSent)
        defaults.set(Double(current.cellularReceived), forKey: SharedKey.rawCellularReceived)
        defaults.set(Double(current.cellularSent), forKey: SharedKey.rawCellularSent)
        defaults.set(currentTimestamp, forKey: SharedKey.rawTimestamp)
        defaults.set(true, forKey: SharedKey.rawAvailable)
        defaults.set(currentTimestamp, forKey: SharedKey.updatedAt)

        return load(defaults: defaults)
    }

    static func forceRefresh() async {
        _ = sample()

        do {
            try await Task.sleep(nanoseconds: 800_000_000)
        } catch {
            return
        }

        _ = sample()
    }

    static func load() -> UsageSnapshot {
        let defaults = defaults
        syncFromAppIfNewer(into: defaults)
        return load(defaults: defaults)
    }

    private static func syncFromAppIfNewer(into local: UserDefaults) {
        guard let shared = appGroupDefaults else { return }

        let sharedResetToken = shared.double(forKey: SharedKey.resetToken)
        let localResetToken = local.double(forKey: SharedKey.resetToken)

        if sharedResetToken > localResetToken {
            clearLocalUsageState(local)
            local.set(sharedResetToken, forKey: SharedKey.resetToken)
            local.set(0, forKey: lastAppSyncKey)
        }

        let sharedTimestamp = shared.double(forKey: SharedKey.updatedAt)
        guard sharedTimestamp > 0 else { return }

        let lastSync = local.double(forKey: lastAppSyncKey)
        guard sharedTimestamp > lastSync else { return }

        let incomingDay = shared.string(forKey: SharedKey.dayKey)
        let incomingMonth = shared.string(forKey: SharedKey.monthKey)
        let sameDay = incomingDay != nil && incomingDay == local.string(forKey: SharedKey.dayKey)
        let sameMonth = incomingMonth != nil && incomingMonth == local.string(forKey: SharedKey.monthKey)

        let todayKeys = [
            SharedKey.todayTotal,
            SharedKey.todayCellular,
            SharedKey.todayWiFi
        ]
        for key in todayKeys {
            let incoming = shared.double(forKey: key)
            local.set(sameDay ? max(local.double(forKey: key), incoming) : incoming, forKey: key)
        }

        let monthKeys = [
            SharedKey.monthTotal,
            SharedKey.monthCellular,
            SharedKey.monthWiFi
        ]
        for key in monthKeys {
            let incoming = shared.double(forKey: key)
            local.set(sameMonth ? max(local.double(forKey: key), incoming) : incoming, forKey: key)
        }

        local.set(
            max(
                local.double(forKey: SharedKey.allTimeTotal),
                shared.double(forKey: SharedKey.allTimeTotal)
            ),
            forKey: SharedKey.allTimeTotal
        )

        let authoritativeKeys = [
            SharedKey.planCapacity,
            SharedKey.planUsed,
            SharedKey.planRemaining,
            SharedKey.rateDown,
            SharedKey.rateUp,
            SharedKey.updatedAt,
            SharedKey.rawWiFiReceived,
            SharedKey.rawWiFiSent,
            SharedKey.rawCellularReceived,
            SharedKey.rawCellularSent,
            SharedKey.rawTimestamp
        ]
        for key in authoritativeKeys {
            local.set(shared.double(forKey: key), forKey: key)
        }

        local.set(shared.bool(forKey: SharedKey.planUnlimited), forKey: SharedKey.planUnlimited)
        local.set(shared.bool(forKey: SharedKey.rawAvailable), forKey: SharedKey.rawAvailable)

        if let incomingDay {
            local.set(incomingDay, forKey: SharedKey.dayKey)
        }
        if let incomingMonth {
            local.set(incomingMonth, forKey: SharedKey.monthKey)
        }

        local.set(sharedTimestamp, forKey: lastAppSyncKey)
    }

    private static func clearLocalUsageState(_ defaults: UserDefaults) {
        let keys = [
            SharedKey.todayTotal,
            SharedKey.todayCellular,
            SharedKey.todayWiFi,
            SharedKey.monthTotal,
            SharedKey.monthCellular,
            SharedKey.monthWiFi,
            SharedKey.allTimeTotal,
            SharedKey.planCapacity,
            SharedKey.planUsed,
            SharedKey.planRemaining,
            SharedKey.rateDown,
            SharedKey.rateUp,
            SharedKey.updatedAt,
            SharedKey.rawWiFiReceived,
            SharedKey.rawWiFiSent,
            SharedKey.rawCellularReceived,
            SharedKey.rawCellularSent,
            SharedKey.rawTimestamp,
            SharedKey.rawAvailable,
            SharedKey.dayKey,
            SharedKey.monthKey
        ]

        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load(defaults: UserDefaults) -> UsageSnapshot {
        let timestamp = defaults.double(forKey: SharedKey.updatedAt)
        let todayTotal = bytes(defaults.double(forKey: SharedKey.todayTotal))
        let monthTotal = bytes(defaults.double(forKey: SharedKey.monthTotal))
        let storedAllTime = bytes(defaults.double(forKey: SharedKey.allTimeTotal))
        let correctedAllTime = max(storedAllTime, monthTotal, todayTotal)

        if correctedAllTime != storedAllTime {
            defaults.set(Double(correctedAllTime), forKey: SharedKey.allTimeTotal)
        }

        return UsageSnapshot(
            todayTotal: todayTotal,
            todayCellular: bytes(defaults.double(forKey: SharedKey.todayCellular)),
            todayWiFi: bytes(defaults.double(forKey: SharedKey.todayWiFi)),
            monthTotal: monthTotal,
            monthCellular: bytes(defaults.double(forKey: SharedKey.monthCellular)),
            monthWiFi: bytes(defaults.double(forKey: SharedKey.monthWiFi)),
            allTimeTotal: correctedAllTime,
            planCapacity: bytes(defaults.double(forKey: SharedKey.planCapacity)),
            planUsed: bytes(defaults.double(forKey: SharedKey.planUsed)),
            planRemaining: bytes(defaults.double(forKey: SharedKey.planRemaining)),
            planUnlimited: defaults.bool(forKey: SharedKey.planUnlimited),
            hasSharedContainer: hasSharedContainer,
            hasAppSync: defaults.double(forKey: lastAppSyncKey) > 0,
            isPreview: false,
            down: defaults.double(forKey: SharedKey.rateDown),
            up: defaults.double(forKey: SharedKey.rateUp),
            updatedAt: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : Date()
        )
    }

    private static func resetPeriodIfNeeded(defaults: UserDefaults, now: Date) {
        let day = dayKey(now)
        if defaults.string(forKey: SharedKey.dayKey) != day {
            defaults.set(day, forKey: SharedKey.dayKey)
            defaults.set(0, forKey: SharedKey.todayTotal)
            defaults.set(0, forKey: SharedKey.todayCellular)
            defaults.set(0, forKey: SharedKey.todayWiFi)
        }

        let month = monthKey(now)
        if defaults.string(forKey: SharedKey.monthKey) != month {
            defaults.set(month, forKey: SharedKey.monthKey)
            defaults.set(0, forKey: SharedKey.monthTotal)
            defaults.set(0, forKey: SharedKey.monthCellular)
            defaults.set(0, forKey: SharedKey.monthWiFi)
        }
    }

    private static func countersAreValid(current: RawCounters, previous: RawCounters) -> Bool {
        current.wifiReceived >= previous.wifiReceived &&
        current.wifiSent >= previous.wifiSent &&
        current.cellularReceived >= previous.cellularReceived &&
        current.cellularSent >= previous.cellularSent
    }

    private static func add(_ delta: UInt64, to key: String, defaults: UserDefaults) {
        let old = bytes(defaults.double(forKey: key))
        let (newValue, overflow) = old.addingReportingOverflow(delta)
        defaults.set(Double(overflow ? UInt64.max : newValue), forKey: key)
    }

    private static func bytes(_ value: Double) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private static func monthKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)"
    }
}

@available(iOS 17.0, *)
struct RefreshNetFlowIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新流量"
    static var description = IntentDescription("立即重新读取当前设备的网络流量计数。")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await SharedTrafficStore.forceRefresh()
        WidgetCenter.shared.reloadTimelines(ofKind: netFlowWidgetKind)
        return .result()
    }
}

private struct NetFlowEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

private struct Provider: TimelineProvider {
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
                planCapacity: 0,
                planUsed: 0,
                planRemaining: 0,
                planUnlimited: false,
                hasSharedContainer: false,
                hasAppSync: false,
                isPreview: true,
                down: 0,
                up: 0,
                updatedAt: .now
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NetFlowEntry) -> Void) {
        let snapshot = context.isPreview ? placeholder(in: context).snapshot : SharedTrafficStore.sample()
        completion(NetFlowEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NetFlowEntry>) -> Void) {
        let now = Date()
        let snapshot = SharedTrafficStore.sample(now: now)
        let entry = NetFlowEntry(date: now, snapshot: snapshot)

        // 5 分钟是 WidgetKit 建议的最小时间线粒度之一。
        // 系统仍会根据预算决定真正的自动刷新时间。
        let next = now.addingTimeInterval(5 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
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
              entry.snapshot.planCapacity > 0 else {
            return 0
        }

        return min(
            max(
                Double(entry.snapshot.planUsed) /
                Double(entry.snapshot.planCapacity),
                0
            ),
            1
        )
    }

    private var planPercent: Int {
        Int((planProgress * 100).rounded())
    }

    private func trafficText(_ bytes: UInt64) -> String {
        entry.snapshot.isPreview ? "—" : Format.bytes(bytes)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Divider()

            if entry.snapshot.isPreview {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("添加后显示真实流量")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("今日 · 本月 · 累计 · 套餐比例")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            } else if entry.snapshot.planUnlimited {
                HStack {
                    Label("套餐", systemImage: "simcard.2.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("不限量")
                        .font(.system(size: 10, weight: .bold))
                }
            } else if entry.snapshot.planCapacity > 0 {
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
                    Text(
                        Format.bytes(entry.snapshot.planUsed)
                        + " / "
                        + Format.bytes(entry.snapshot.planCapacity)
                    )
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                    Spacer()

                    Text(Format.time(entry.snapshot.updatedAt))
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(
                            entry.snapshot.hasAppSync
                            ? "套餐未设置"
                            : (entry.snapshot.hasSharedContainer ? "套餐待同步" : "独立统计模式")
                        )
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        Text(
                            entry.snapshot.hasAppSync
                            ? "请在 App 内设置套餐"
                            : (entry.snapshot.hasSharedContainer ? "打开 NetFlow 一次即可" : "重签需保留 App Group")
                        )
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    }
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
                        Text("添加后显示真实流量")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("今日 · 本月 · 累计 · 套餐用量与比例")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
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
            } else if entry.snapshot.planCapacity > 0 {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("套餐使用")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)

                        Text(
                            Format.bytes(entry.snapshot.planUsed)
                            + " / "
                            + Format.bytes(entry.snapshot.planCapacity)
                        )
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
                        "蜂窝 "
                        + Format.bytes(entry.snapshot.monthCellular)
                        + " · Wi‑Fi "
                        + Format.bytes(entry.snapshot.monthWiFi)
                    )
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            entry.snapshot.hasAppSync
                            ? "套餐未设置"
                            : (entry.snapshot.hasSharedContainer ? "套餐待同步" : "共享权限未生效")
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Text(
                            entry.snapshot.hasAppSync
                            ? "请在 App 内设置套餐"
                            : (entry.snapshot.hasSharedContainer ? "打开 NetFlow 一次后自动同步" : "今日 / 本月 / 累计仍可正常统计")
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    speedPair
                }
            }
        }
        .padding()
        .widgetBackground()
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                "今日 " + trafficText(entry.snapshot.todayTotal)
                + " · 本月 " + trafficText(entry.snapshot.monthTotal)
            )
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            if entry.snapshot.planUnlimited {
                Text("累计 " + trafficText(entry.snapshot.allTimeTotal) + " · 套餐不限量")
                    .font(.caption2)
                    .lineLimit(1)
            } else if entry.snapshot.planCapacity > 0 {
                Text(
                    "套餐 " + String(planPercent) + "%"
                    + " · 剩余 " + Format.bytes(entry.snapshot.planRemaining)
                )
                .font(.caption2)
                .lineLimit(1)
            } else {
                Text("累计 " + trafficText(entry.snapshot.allTimeTotal))
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }

    private var accessoryInline: some View {
        if entry.snapshot.planUnlimited {
            Text("今日 " + trafficText(entry.snapshot.todayTotal) + " · 不限量")
        } else if entry.snapshot.planCapacity > 0 {
            Text(
                "今日 " + trafficText(entry.snapshot.todayTotal)
                + " · 套餐 " + String(planPercent) + "%"
            )
        } else {
            Text("今日 " + trafficText(entry.snapshot.todayTotal))
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

    private func mediumMetric(
        _ title: String,
        _ value: UInt64,
        _ icon: String,
        _ color: Color
    ) -> some View {
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

    @ViewBuilder
    private var refreshButton: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            Button(intent: RefreshNetFlowIntent()) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.indigo)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("立即刷新流量")
        } else {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func metricRow(
        _ title: String,
        _ value: String,
        _ icon: String,
        _ color: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
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
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            NetFlowWidgetView(entry: entry)
        }
        .configurationDisplayName("NetFlow 流量")
        .description("查看今日、本月流量和最近网速；iOS 17 及以上可直接点小组件刷新。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

@main
struct NetFlowWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetFlowUsageWidget()
    }
}
