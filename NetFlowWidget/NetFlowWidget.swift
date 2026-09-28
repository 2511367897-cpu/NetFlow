import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit
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
    var planRemaining: UInt64 = 0
    var planUnlimited = false
    var down: Double = 0
    var up: Double = 0
    var updatedAt = Date()
}

private enum SharedTrafficStore {
    // 小组件把自己的计数保存在扩展自身的 UserDefaults 中。
    // 即使重签时 App Group 权限被裁掉，Widget 仍然可以独立工作。
    private static var defaults: UserDefaults { .standard }

    private static var appGroupDefaults: UserDefaults? {
        UserDefaults(suiteName: netFlowGroupID)
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

        let sharedTimestamp = shared.double(forKey: SharedKey.updatedAt)
        guard sharedTimestamp > 0 else { return }

        let lastSync = local.double(forKey: lastAppSyncKey)
        guard sharedTimestamp > lastSync else { return }

        let doubleKeys = [
            SharedKey.todayTotal,
            SharedKey.todayCellular,
            SharedKey.todayWiFi,
            SharedKey.monthTotal,
            SharedKey.monthCellular,
            SharedKey.monthWiFi,
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

        for key in doubleKeys {
            local.set(shared.double(forKey: key), forKey: key)
        }

        local.set(shared.bool(forKey: SharedKey.planUnlimited), forKey: SharedKey.planUnlimited)
        local.set(shared.bool(forKey: SharedKey.rawAvailable), forKey: SharedKey.rawAvailable)

        if let day = shared.string(forKey: SharedKey.dayKey) {
            local.set(day, forKey: SharedKey.dayKey)
        }
        if let month = shared.string(forKey: SharedKey.monthKey) {
            local.set(month, forKey: SharedKey.monthKey)
        }

        local.set(sharedTimestamp, forKey: lastAppSyncKey)
    }

    private static func load(defaults: UserDefaults) -> UsageSnapshot {
        let timestamp = defaults.double(forKey: SharedKey.updatedAt)

        return UsageSnapshot(
            todayTotal: bytes(defaults.double(forKey: SharedKey.todayTotal)),
            todayCellular: bytes(defaults.double(forKey: SharedKey.todayCellular)),
            todayWiFi: bytes(defaults.double(forKey: SharedKey.todayWiFi)),
            monthTotal: bytes(defaults.double(forKey: SharedKey.monthTotal)),
            monthCellular: bytes(defaults.double(forKey: SharedKey.monthCellular)),
            monthWiFi: bytes(defaults.double(forKey: SharedKey.monthWiFi)),
            planRemaining: bytes(defaults.double(forKey: SharedKey.planRemaining)),
            planUnlimited: defaults.bool(forKey: SharedKey.planUnlimited),
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
                todayTotal: 1_860_000_000,
                todayCellular: 1_120_000_000,
                todayWiFi: 740_000_000,
                monthTotal: 18_600_000_000,
                monthCellular: 11_400_000_000,
                monthWiFi: 7_200_000_000,
                planRemaining: 18_600_000_000,
                planUnlimited: false,
                down: 2_400_000,
                up: 320_000,
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

            Spacer(minLength: 1)

            Text("今日")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(Format.bytes(entry.snapshot.todayTotal))
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.58)
                .lineLimit(1)

            HStack(spacing: 8) {
                Label(Format.bytes(entry.snapshot.todayCellular), systemImage: "antenna.radiowaves.left.and.right")
                Label(Format.bytes(entry.snapshot.todayWiFi), systemImage: "wifi")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.62)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("本月")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(Format.bytes(entry.snapshot.monthTotal))
                        .font(.caption.weight(.bold))
                }

                Spacer()

                Text(Format.time(entry.snapshot.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .widgetBackground()
    }

    private var medium: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("今日流量", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.indigo)
                    Spacer()
                }

                Text(Format.bytes(entry.snapshot.todayTotal))
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                metricRow(
                    "蜂窝",
                    Format.bytes(entry.snapshot.todayCellular),
                    "antenna.radiowaves.left.and.right",
                    .orange
                )
                metricRow(
                    "Wi‑Fi",
                    Format.bytes(entry.snapshot.todayWiFi),
                    "wifi",
                    .cyan
                )
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("本月")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    refreshButton
                }

                Text(Format.bytes(entry.snapshot.monthTotal))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                HStack(spacing: 8) {
                    Label(Format.rate(entry.snapshot.down), systemImage: "arrow.down")
                        .foregroundStyle(.blue)
                    Label(Format.rate(entry.snapshot.up), systemImage: "arrow.up")
                        .foregroundStyle(.green)
                }
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)

                Text(
                    entry.snapshot.planUnlimited
                    ? "套餐：不限量"
                    : "剩余 " + Format.bytes(entry.snapshot.planRemaining)
                )
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 0)

                Text("更新 " + Format.time(entry.snapshot.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .widgetBackground()
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("今日 " + Format.bytes(entry.snapshot.todayTotal))
                .font(.headline)
                .lineLimit(1)

            Text(
                "蜂窝 " + Format.bytes(entry.snapshot.todayCellular)
                + " · Wi‑Fi " + Format.bytes(entry.snapshot.todayWiFi)
            )
            .font(.caption2)
            .lineLimit(1)
        }
    }

    private var accessoryInline: some View {
        Text("今日流量 " + Format.bytes(entry.snapshot.todayTotal))
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


@available(iOSApplicationExtension 16.2, *)
struct NetFlowLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NetFlowActivityAttributes.self) { context in
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("今日流量", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(Format.bytes(context.state.todayTotal))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    HStack(spacing: 10) {
                        Label(
                            Format.rate(context.state.downloadBytesPerSecond),
                            systemImage: "arrow.down"
                        )
                        .foregroundStyle(.blue)

                        Label(
                            Format.rate(context.state.uploadBytesPerSecond),
                            systemImage: "arrow.up"
                        )
                        .foregroundStyle(.green)
                    }
                    .font(.caption2.weight(.semibold))
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("本月")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(Format.bytes(context.state.monthTotal))
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Text(
                        context.state.planUnlimited
                        ? "不限量"
                        : "剩余 " + Format.bytes(context.state.planRemaining)
                    )
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    Text(Format.time(context.state.updatedAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(URL(string: "netflow://open"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("今日", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.indigo)

                        Text(Format.bytes(context.state.todayTotal))
                            .font(.headline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("本月")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(Format.bytes(context.state.monthTotal))
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 12) {
                        Label(
                            Format.rate(context.state.downloadBytesPerSecond),
                            systemImage: "arrow.down"
                        )
                        .foregroundStyle(.blue)

                        Label(
                            Format.rate(context.state.uploadBytesPerSecond),
                            systemImage: "arrow.up"
                        )
                        .foregroundStyle(.green)
                    }
                    .font(.caption.weight(.semibold))
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Label(
                            Format.bytes(context.state.todayCellular),
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        .foregroundStyle(.orange)

                        Spacer()

                        Label(
                            Format.bytes(context.state.todayWiFi),
                            systemImage: "wifi"
                        )
                        .foregroundStyle(.cyan)
                    }
                    .font(.caption2.weight(.medium))
                }
            } compactLeading: {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.indigo)
            } compactTrailing: {
                Text(Format.bytes(context.state.todayTotal))
                    .font(.caption2.weight(.bold))
                    .minimumScaleFactor(0.6)
            } minimal: {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.indigo)
            }
            .widgetURL(URL(string: "netflow://open"))
            .keylineTint(.indigo)
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

        if #available(iOSApplicationExtension 16.2, *) {
            NetFlowLiveActivity()
        }
    }
}
