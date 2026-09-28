import WidgetKit
import SwiftUI

private let widgetKind = "NetFlowSharedWidget"
private let appGroupIdentifier = "group.com.duyhoang.netflow"
private let sharedDataFileName = "netflow-data.json"

private struct SharedPlan: Decodable {
    var cycleType: String
    var capacityBytes: UInt64
    var monthlyResetDay: Int
    var carriedBytes: UInt64
    var manualUsedBytes: UInt64
    var activeCycleStart: Date
    var activeCycleEnd: Date

    var isUnlimited: Bool { cycleType == "unlimited" }

    var effectiveCapacityBytes: UInt64 {
        guard !isUnlimited else { return UInt64.max }
        let (value, overflow) = capacityBytes.addingReportingOverflow(carriedBytes)
        return overflow ? UInt64.max : value
    }
}

private struct SharedRecord: Decodable {
    var date: Date
    var wifiReceived: UInt64
    var wifiSent: UInt64
    var cellularReceived: UInt64
    var cellularSent: UInt64
    var lastUpdated: Date

    var wifiTotal: UInt64 { wifiReceived &+ wifiSent }
    var cellularTotal: UInt64 { cellularReceived &+ cellularSent }
    var total: UInt64 { wifiTotal &+ cellularTotal }
}

private struct SharedPayload: Decodable {
    var plan: SharedPlan
    var records: [SharedRecord]
}

private struct WidgetSnapshot {
    var todayTotal: UInt64 = 0
    var monthTotal: UInt64 = 0
    var allTimeTotal: UInt64 = 0
    var planUsed: UInt64 = 0
    var planCapacity: UInt64 = 0
    var planRemaining: UInt64 = 0
    var planUnlimited = false
    var resetDay = 1
    var updatedAt = Date()
    var isAvailable = false
}

private enum SharedDataStore {
    static func load(now: Date = Date()) -> WidgetSnapshot {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            )
        else {
            return WidgetSnapshot()
        }

        let url = container.appendingPathComponent(sharedDataFileName)
        guard let data = try? Data(contentsOf: url) else {
            return WidgetSnapshot()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(SharedPayload.self, from: data) else {
            return WidgetSnapshot()
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: now)
        ) ?? startOfToday
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now

        let todayTotal = payload.records
            .filter { $0.date >= startOfToday && $0.date < startOfTomorrow }
            .reduce(UInt64(0)) { $0 &+ $1.total }

        let monthTotal = payload.records
            .filter { $0.date >= monthStart && $0.date < nextMonth }
            .reduce(UInt64(0)) { $0 &+ $1.total }

        let allTimeTotal = payload.records.reduce(UInt64(0)) { $0 &+ $1.total }

        let planUsedMeasured = payload.records
            .filter { $0.date >= payload.plan.activeCycleStart && $0.date < payload.plan.activeCycleEnd }
            .reduce(UInt64(0)) { $0 &+ $1.cellularTotal }

        let planUsed = planUsedMeasured &+ payload.plan.manualUsedBytes
        let capacity = payload.plan.isUnlimited ? UInt64(0) : payload.plan.effectiveCapacityBytes
        let remaining = payload.plan.isUnlimited ? UInt64(0) : (capacity > planUsed ? capacity - planUsed : 0)
        let updatedAt = payload.records.map(\.lastUpdated).max() ?? now

        return WidgetSnapshot(
            todayTotal: todayTotal,
            monthTotal: monthTotal,
            allTimeTotal: allTimeTotal,
            planUsed: planUsed,
            planCapacity: capacity,
            planRemaining: remaining,
            planUnlimited: payload.plan.isUnlimited,
            resetDay: min(max(payload.plan.monthlyResetDay, 1), 31),
            updatedAt: updatedAt,
            isAvailable: true
        )
    }
}

private struct NetFlowEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> NetFlowEntry {
        NetFlowEntry(
            date: .now,
            snapshot: WidgetSnapshot(
                todayTotal: 1_280_000_000,
                monthTotal: 18_600_000_000,
                allTimeTotal: 81_400_000_000,
                planUsed: 12_900_000_000,
                planCapacity: 30_000_000_000,
                planRemaining: 17_100_000_000,
                planUnlimited: false,
                resetDay: 1,
                updatedAt: .now,
                isAvailable: true
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NetFlowEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NetFlowEntry(date: .now, snapshot: SharedDataStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NetFlowEntry>) -> Void) {
        let now = Date()
        let entry = NetFlowEntry(date: now, snapshot: SharedDataStore.load(now: now))
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(5 * 60))))
    }
}

private enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private struct NetFlowWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NetFlowEntry

    private var progress: Double {
        guard entry.snapshot.isAvailable,
              !entry.snapshot.planUnlimited,
              entry.snapshot.planCapacity > 0 else { return 0 }
        return min(max(Double(entry.snapshot.planUsed) / Double(entry.snapshot.planCapacity), 0), 1)
    }

    private var percent: Int {
        Int((progress * 100).rounded())
    }

    var body: some View {
        Group {
            if !entry.snapshot.isAvailable {
                unavailableView
            } else {
                switch family {
                case .systemMedium:
                    mediumView
                case .accessoryRectangular:
                    accessoryRectangular
                case .accessoryInline:
                    accessoryInline
                default:
                    smallView
                }
            }
        }
        .widgetURL(URL(string: "netflow://open"))
    }

    private var unavailableView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("NetFlow", systemImage: "waveform.path.ecg")
                .font(.headline)
            Text("请先打开 App")
                .font(.caption.weight(.semibold))
            Text("若仍无数据，签名时需保留 App Groups 权限")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding()
        .widgetBackground()
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("NetFlow", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.bold))
                Spacer()
                Text(Format.time(entry.snapshot.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            metric("今日", entry.snapshot.todayTotal)
            metric("本月", entry.snapshot.monthTotal)
            metric("累计", entry.snapshot.allTimeTotal)

            if entry.snapshot.planUnlimited {
                Text("套餐 · 不限量")
                    .font(.caption2.weight(.semibold))
            } else {
                ProgressView(value: progress)
                HStack {
                    Text("套餐已用 " + Format.bytes(entry.snapshot.planUsed))
                    Spacer()
                    Text("\(percent)%")
                        .fontWeight(.bold)
                }
                .font(.system(size: 9))
            }
        }
        .padding()
        .widgetBackground()
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("NetFlow 流量", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.bold))
                Spacer()
                Text("更新 " + Format.time(entry.snapshot.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                compactMetric("今日", entry.snapshot.todayTotal)
                compactMetric("本月", entry.snapshot.monthTotal)
                compactMetric("累计", entry.snapshot.allTimeTotal)
            }

            Divider()

            if entry.snapshot.planUnlimited {
                HStack {
                    Text("套餐")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("不限量").fontWeight(.bold)
                }
                .font(.caption)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("套餐已用")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(Format.bytes(entry.snapshot.planUsed) + " / " + Format.bytes(entry.snapshot.planCapacity))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("剩余 " + Format.bytes(entry.snapshot.planRemaining) + " · 每月 \(entry.snapshot.resetDay) 日重置")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(percent)%")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                ProgressView(value: progress)
            }
        }
        .padding()
        .widgetBackground()
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("今日 " + Format.bytes(entry.snapshot.todayTotal) + " · 本月 " + Format.bytes(entry.snapshot.monthTotal))
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if entry.snapshot.planUnlimited {
                Text("累计 " + Format.bytes(entry.snapshot.allTimeTotal) + " · 不限量")
                    .font(.caption2)
            } else {
                Text("套餐 " + String(percent) + "% · 剩余 " + Format.bytes(entry.snapshot.planRemaining))
                    .font(.caption2)
            }
        }
    }

    private var accessoryInline: some View {
        if entry.snapshot.planUnlimited {
            Text("NetFlow · 今日 " + Format.bytes(entry.snapshot.todayTotal) + " · 不限量")
        } else {
            Text("NetFlow · 今日 " + Format.bytes(entry.snapshot.todayTotal) + " · 套餐 " + String(percent) + "%")
        }
    }

    private func metric(_ title: String, _ value: UInt64) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer()
            Text(Format.bytes(value))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func compactMetric(_ title: String, _ value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(Format.bytes(value))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

@main
struct NetFlowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: Provider()) { entry in
            NetFlowWidgetView(entry: entry)
        }
        .configurationDisplayName("NetFlow")
        .description("与 NetFlow App 共用同一套流量与套餐数据。点按小组件可打开 App 修改套餐。")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
