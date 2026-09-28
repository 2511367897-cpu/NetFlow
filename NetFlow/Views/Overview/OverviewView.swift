import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var context: NetworkContextService
    @State private var isRefreshing = false

    init(context: NetworkContextService) {
        self.context = context
    }

    private var appLocale: Locale { store.settings.appLanguage.locale }

    private var today: DailyUsageRecord? {
        store.dailyRecords.first { Calendar.current.isDateInToday($0.date) }
    }

    private var todayDownload: UInt64 {
        (today?.wifiReceived ?? 0) + (today?.cellularReceived ?? 0)
    }

    private var todayUpload: UInt64 {
        (today?.wifiSent ?? 0) + (today?.cellularSent ?? 0)
    }

    private var todayTotal: UInt64 {
        today?.totalBytes ?? 0
    }

    private var monthRecords: [DailyUsageRecord] {
        store.dailyRecords.filter { monthInterval.contains($0.date) }
    }

    private var monthDownload: UInt64 {
        monthRecords.reduce(0) { $0 + $1.wifiReceived + $1.cellularReceived }
    }

    private var monthUpload: UInt64 {
        monthRecords.reduce(0) { $0 + $1.wifiSent + $1.cellularSent }
    }

    private var monthCellular: UInt64 {
        monthRecords.reduce(0) { $0 + $1.cellularTotalBytes }
    }

    private var monthWiFi: UInt64 {
        monthRecords.reduce(0) { $0 + $1.wifiTotalBytes }
    }

    private var monthTotal: UInt64 {
        monthRecords.reduce(0) { $0 + $1.totalBytes }
    }

    private var planUsed: UInt64 {
        store.planUsage()
    }

    private var planRemaining: UInt64 {
        guard !store.plan.isUnlimited else { return 0 }
        return store.plan.effectiveCapacityBytes > planUsed
            ? store.plan.effectiveCapacityBytes - planUsed
            : 0
    }

    private var planProgress: Double {
        guard !store.plan.isUnlimited, store.plan.effectiveCapacityBytes > 0 else { return 0 }
        return min(Double(planUsed) / Double(store.plan.effectiveCapacityBytes), 1)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppChrome.spacing) {
                header
                liveSpeed
                todayUsage
                monthUsage
                planCard
                connectionCard
            }
            .padding(AppChrome.pagePadding)
        }
        .netFlowPageBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshEverything()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("流量")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                TimelineView(.periodic(from: .now, by: 1)) { value in
                    Text(value.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()

            Button {
                Task { await refreshEverything() }
            } label: {
                Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.title3.weight(.semibold))
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("refresh"))
        }
        .netFlowCard(cornerRadius: 20)
    }

    private var liveSpeed: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("实时网速", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Text(connectionName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                liveMetric(
                    title: "下载",
                    value: ByteFormat.rate(store.currentRate.cellularDown + store.currentRate.wifiDown),
                    icon: "arrow.down.circle.fill"
                )

                Divider().frame(height: 52)

                liveMetric(
                    title: "上传",
                    value: ByteFormat.rate(store.currentRate.cellularUp + store.currentRate.wifiUp),
                    icon: "arrow.up.circle.fill"
                )
            }
        }
        .netFlowCard(cornerRadius: 20)
    }

    private var todayUsage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("今日流量", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Text(ByteFormat.string(todayTotal))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                valueMetric("下载", ByteFormat.string(todayDownload), "arrow.down")
                valueMetric("上传", ByteFormat.string(todayUpload), "arrow.up")
            }

            Divider()

            usageRow(
                title: "蜂窝数据",
                icon: "antenna.radiowaves.left.and.right",
                value: ByteFormat.string(today?.cellularTotalBytes ?? 0)
            )
            usageRow(
                title: "Wi‑Fi",
                icon: "wifi",
                value: ByteFormat.string(today?.wifiTotalBytes ?? 0)
            )
        }
        .netFlowCard(cornerRadius: 20)
    }

    private var monthUsage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("本月流量", systemImage: "calendar.badge.clock")
                    .font(.headline)
                Spacer()
                Text(ByteFormat.string(monthTotal))
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }

            HStack(spacing: 12) {
                valueMetric("下载", ByteFormat.string(monthDownload), "arrow.down")
                valueMetric("上传", ByteFormat.string(monthUpload), "arrow.up")
            }

            Divider()

            usageRow(
                title: "蜂窝数据",
                icon: "antenna.radiowaves.left.and.right",
                value: ByteFormat.string(monthCellular)
            )
            usageRow(
                title: "Wi‑Fi",
                icon: "wifi",
                value: ByteFormat.string(monthWiFi)
            )
        }
        .netFlowCard(cornerRadius: 20)
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("流量套餐", systemImage: "simcard.2.fill")
                    .font(.headline)
                Spacer()
                Text(store.plan.isUnlimited ? "不限量" : ByteFormat.string(store.plan.effectiveCapacityBytes))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if store.plan.isUnlimited {
                HStack {
                    Text("已使用")
                    Spacer()
                    Text(ByteFormat.string(planUsed)).bold()
                }
            } else {
                ProgressView(value: planProgress)
                    .tint(planProgress >= 0.9 ? .red : .green)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已使用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteFormat.string(planUsed))
                            .font(.headline)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("剩余")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ByteFormat.string(planRemaining))
                            .font(.headline)
                    }
                }
            }
        }
        .netFlowCard(cornerRadius: 20)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("网络状态", systemImage: "network")
                .font(.headline)

            usageRow(
                title: "当前连接",
                icon: context.connection.isWiFiActive ? "wifi" : "antenna.radiowaves.left.and.right",
                value: connectionName
            )

            usageRow(
                title: "公网 IP",
                icon: "globe",
                value: context.connection.publicIP ?? "—"
            )

            usageRow(
                title: "VPN",
                icon: context.connection.isVPNActive ? "lock.shield.fill" : "lock.shield",
                value: context.connection.isVPNActive ? "已连接" : "未连接"
            )
        }
        .netFlowCard(cornerRadius: 20)
    }

    private func liveMetric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueMetric(_ title: String, _ value: String, _ icon: String) -> some View {
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

    private func usageRow(title: String, icon: String, value: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .font(.subheadline)
    }

    private var connectionName: String {
        if context.connection.isWiFiActive {
            if let ssid = context.connection.wifiSSID, !ssid.isEmpty {
                return "Wi‑Fi · \(ssid)"
            }
            return "Wi‑Fi"
        }
        if context.connection.isCellularActive {
            return "蜂窝网络"
        }
        return "未连接"
    }

    private var monthInterval: DateInterval {
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        return DateInterval(start: start, end: end)
    }

    private func refreshEverything() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await store.refresh()
        await store.refreshContext()
    }
}
