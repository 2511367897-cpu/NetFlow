import SwiftUI
import WidgetKit

private struct LedgerEntry: TimelineEntry {
    var date: Date
    var snapshot: LedgerSnapshot?
    var error: String?
}

private struct LedgerProvider: TimelineProvider {
    func placeholder(in context: Context) -> LedgerEntry {
        LedgerEntry(date: Date(), snapshot: nil, error: "等待首次统计")
    }

    func getSnapshot(in context: Context, completion: @escaping (LedgerEntry) -> Void) {
        completion(load(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LedgerEntry>) -> Void) {
        let now = Date()
        let entry = load(at: now)
        // Cached entries explicitly become stale, even if iOS delays the next
        // extension launch. Never show yesterday's bytes as today's bytes.
        var entries = [entry]
        if let snapshot = entry.snapshot {
            let staleAt = snapshot.sampledAt.addingTimeInterval(121)
            if staleAt > now { entries.append(LedgerEntry(date: staleAt, snapshot: snapshot, error: nil)) }
        }
        if let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime) {
            entries.append(LedgerEntry(date: midnight, snapshot: entry.snapshot, error: entry.error))
        }
        completion(Timeline(entries: entries.sorted { $0.date < $1.date },
                            policy: .after(now.addingTimeInterval(15 * 60))))
    }

    private func load(at date: Date) -> LedgerEntry {
        do {
            let snapshot = try SharedLedgerStore().read()
            return LedgerEntry(date: date, snapshot: snapshot,
                               error: snapshot == nil ? "打开流量账本完成首次采样" : nil)
        } catch {
            return LedgerEntry(date: date, snapshot: nil, error: error.localizedDescription)
        }
    }
}

private struct LedgerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: LedgerEntry

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "待更新" }
        return String(format: "%.2f GB", Double(value) / 1_000_000_000)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("流量账本", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline).foregroundStyle(.indigo)
                Spacer(minLength: 0)
                if let snapshot = entry.snapshot {
                    Image(systemName: snapshot.isStale(at: entry.date) ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(snapshot.isStale(at: entry.date) ? .orange : .green)
                }
            }
            if let snapshot = entry.snapshot {
                HStack(alignment: .top) {
                    metric("今日蜂窝", bytes(snapshot.todayCellular(at: entry.date)))
                    if family != .systemSmall {
                        Spacer()
                        metric("本月蜂窝", bytes(snapshot.monthCellular(at: entry.date)))
                        Spacer()
                        metric("本期套餐", bytes(snapshot.planUsed))
                    }
                }
                if family == .systemSmall {
                    Text("本月 \(bytes(snapshot.monthCellular(at: entry.date)))").font(.caption)
                } else {
                    Text("今日 Wi-Fi \(bytes(Calendar.current.isDate(snapshot.dayStart, inSameDayAs: entry.date) ? snapshot.todayWiFi : nil)) · 本月 Wi-Fi \(bytes(snapshot.monthCellular(at: entry.date) == nil ? nil : snapshot.monthWiFi))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(snapshot.isStale(at: entry.date) ? "数据待更新" :
                         (snapshot.continuousRunning ? "连续记录中" : "后台未运行"))
                        .foregroundStyle(snapshot.isStale(at: entry.date) ? .orange : .secondary)
                    Spacer(minLength: 0)
                    Text(snapshot.sampledAt, style: .time).foregroundStyle(.secondary)
                }
                .font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
                if snapshot.warning != nil && family != .systemSmall {
                    Text("历史存在采样空档，详见 App").font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text(entry.error ?? "尚无账本").font(.caption).foregroundStyle(.secondary)
                Text("点此打开 App").font(.caption).foregroundStyle(.indigo)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(URL(string: "flowledger://open"))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: family == .systemSmall ? 20 : 17, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.7).lineLimit(1)
        }
    }
}

@main
struct FlowLedgerWidget: Widget {
    let kind = "FlowLedgerSharedWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LedgerProvider()) { entry in
            LedgerWidgetView(entry: entry)
        }
        .configurationDisplayName("流量账本")
        .description("与主 App 共用账本，显示今日、本月蜂窝流量和采样时间。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
