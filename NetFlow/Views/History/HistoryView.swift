import SwiftUI
import Charts

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var days = 30

    private var records: [DailyUsageRecord] {
        Array(store.dailyRecords.prefix(days)).reversed()
    }

    private var totalInRange: UInt64 {
        records.reduce(0) { $0 + $1.totalBytes }
    }

    private var cellularInRange: UInt64 {
        records.reduce(0) { $0 + $1.cellularTotalBytes }
    }

    private var wifiInRange: UInt64 {
        records.reduce(0) { $0 + $1.wifiTotalBytes }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppChrome.spacing) {
                Picker("范围", selection: $days) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("365 天").tag(365)
                }
                .pickerStyle(.segmented)
                .netFlowCard(cornerRadius: 16)

                summary

                Chart {
                    ForEach(records) { r in
                        BarMark(
                            x: .value("日期", r.date, unit: .day),
                            y: .value("蜂窝数据", r.cellularTotalBytes)
                        )
                        .foregroundStyle(by: .value("类型", "蜂窝"))

                        BarMark(
                            x: .value("日期", r.date, unit: .day),
                            y: .value("Wi‑Fi", r.wifiTotalBytes)
                        )
                        .foregroundStyle(by: .value("类型", "Wi‑Fi"))
                    }
                }
                .chartLegend(position: .bottom)
                .frame(height: 230)
                .netFlowCard(cornerRadius: 18)

                VStack(alignment: .leading, spacing: 10) {
                    Text("每日详情")
                        .netFlowSectionTitle()

                    ForEach(store.dailyRecords.prefix(days)) { r in
                        dayCard(r)
                    }
                }
            }
            .padding(AppChrome.pagePadding)
        }
        .netFlowPageBackground()
        .navigationTitle("流量历史")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("总流量")
                    .font(.headline)
                Spacer()
                Text(ByteFormat.string(totalInRange))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }

            Divider()

            HStack(spacing: 12) {
                summaryMetric("蜂窝", ByteFormat.string(cellularInRange), "antenna.radiowaves.left.and.right")
                summaryMetric("Wi‑Fi", ByteFormat.string(wifiInRange), "wifi")
            }
        }
        .netFlowCard(cornerRadius: 18)
    }

    private func dayCard(_ r: DailyUsageRecord) -> some View {
        let down = r.wifiReceived + r.cellularReceived
        let up = r.wifiSent + r.cellularSent

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(r.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.headline)
                Spacer()
                Text(ByteFormat.string(r.totalBytes))
                    .font(.headline)
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                tinyMetric("下载", ByteFormat.string(down), "arrow.down")
                tinyMetric("上传", ByteFormat.string(up), "arrow.up")
            }

            Divider()

            HStack {
                Label("蜂窝", systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(r.cellularTotalBytes))
                    .fontWeight(.semibold)
            }
            .font(.caption)

            HStack {
                Label("Wi‑Fi", systemImage: "wifi")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteFormat.string(r.wifiTotalBytes))
                    .fontWeight(.semibold)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .netFlowCard(cornerRadius: 16)
    }

    private func summaryMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tinyMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
