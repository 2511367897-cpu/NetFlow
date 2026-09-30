import SwiftUI
import Charts

struct OverviewView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var context: NetworkContextService
    @State private var isRefreshing = false

    init(context: NetworkContextService) {
        self.context = context
    }

    private var today: DailyUsageRecord? {
        store.dailyRecords.first { Calendar.current.isDateInToday($0.date) }
    }

    private var todayTotal: UInt64 { today?.totalBytes ?? 0 }
    private var todayDownload: UInt64 {
        saturatingAdd(today?.wifiReceived ?? 0, today?.cellularReceived ?? 0)
    }
    private var todayUpload: UInt64 {
        saturatingAdd(today?.wifiSent ?? 0, today?.cellularSent ?? 0)
    }

    private var monthRecords: [DailyUsageRecord] {
        store.dailyRecords.filter { ($0.date >= monthInterval.start && $0.date < monthInterval.end) }
    }

    private var rawMonthTotal: UInt64 {
        monthRecords.reduce(UInt64(0)) { saturatingAdd($0, $1.totalBytes) }
    }

    private var rawMonthCellular: UInt64 {
        monthRecords.reduce(UInt64(0)) { saturatingAdd($0, $1.cellularTotalBytes) }
    }

    private var monthWiFi: UInt64 {
        monthRecords.reduce(UInt64(0)) { saturatingAdd($0, $1.wifiTotalBytes) }
    }

    private var usesMonthlyPlanCalibration: Bool {
        guard store.plan.cycleType == .monthly else { return false }
        let planInterval = store.plan.cycleInterval(containing: Date())
        return abs(planInterval.start.timeIntervalSince(monthInterval.start)) < 1
            && abs(planInterval.end.timeIntervalSince(monthInterval.end)) < 1
    }

    private var monthCellular: UInt64 {
        usesMonthlyPlanCalibration ? planUsed : rawMonthCellular
    }

    private var monthTotal: UInt64 {
        guard usesMonthlyPlanCalibration else { return rawMonthTotal }
        return saturatingAdd(monthWiFi, monthCellular)
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

    private var recentRecords: [DailyUsageRecord] {
        Array(store.dailyRecords.prefix(7)).reversed()
    }

    private var dataAge: TimeInterval? {
        guard let updated = today?.lastUpdated else { return nil }
        return Date().timeIntervalSince(updated)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: AppChrome.spacing) {
                topBar
                planHero
                statsGrid
                liveSpeedCard
                weeklyChart
                networkCard
            }
            .padding(.horizontal, AppChrome.pagePadding)
            .padding(.bottom, 24)
        }
        .netFlowPageBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await refreshEverything()
        }
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("流量")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("今天 · \(Date().formatted(date: .abbreviated, time: .omitted))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await refreshEverything() }
            } label: {
                Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新")
        }
        .padding(.top, 8)
    }

    private var planHero: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text(store.plan.isUnlimited ? "本周期已使用" : "本周期剩余")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))

                Text(
                    store.plan.isUnlimited
                    ? ByteFormat.string(planUsed)
                    : ByteFormat.string(planRemaining)
                )
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.62)

                Text(store.plan.isUnlimited
                     ? "不限量套餐"
                     : "已用 \(ByteFormat.string(planUsed)) / \(ByteFormat.string(store.plan.effectiveCapacityBytes))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let calibratedAt = store.plan.lastCalibrationDate {
                    Label(
                        "已按运营商数据校准 · \(calibratedAt.formatted(date: .omitted, time: .shortened))",
                        systemImage: "scope"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.top, 2)
                } else if let age = dataAge {
                    Label(
                        age > 300 ? "数据可能滞后，点右上角刷新" : "数据已同步",
                        systemImage: age > 300 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(age > 300 ? 0.95 : 0.72))
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 4)

            if !store.plan.isUnlimited {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.18), lineWidth: 9)

                    Circle()
                        .trim(from: 0, to: planProgress)
                        .stroke(
                            .white,
                            style: StrokeStyle(lineWidth: 9, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 0) {
                        Text("\(Int((planProgress * 100).rounded()))%")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("已用")
                            .font(.caption2)
                            .opacity(0.75)
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: 90, height: 90)
            } else {
                Image(systemName: "infinity.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppChrome.heroGradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color.indigo.opacity(0.22), radius: 16, x: 0, y: 8)
    }

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            metricTile(
                title: "今日",
                value: ByteFormat.string(todayTotal),
                subtitle: "↓ \(ByteFormat.string(todayDownload))  ↑ \(ByteFormat.string(todayUpload))",
                icon: "sun.max.fill",
                tint: AppChrome.download
            )

            metricTile(
                title: "本月",
                value: ByteFormat.string(monthTotal),
                subtitle: "\(Calendar.current.component(.month, from: Date())) 月累计",
                icon: "calendar",
                tint: AppChrome.accent
            )

            metricTile(
                title: "蜂窝数据",
                value: ByteFormat.string(monthCellular),
                subtitle: "本月",
                icon: "antenna.radiowaves.left.and.right",
                tint: AppChrome.cellular
            )

            metricTile(
                title: "Wi‑Fi",
                value: ByteFormat.string(monthWiFi),
                subtitle: "本月",
                icon: "wifi",
                tint: AppChrome.wifi
            )
        }
    }

    private var liveSpeedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("实时网速", systemImage: "waveform.path.ecg")
                    .font(.headline)

                Spacer()

                HStack(spacing: 5) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    Text(connectionName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                speedMetric(
                    title: "下载",
                    value: ByteFormat.rate(store.currentRate.cellularDown + store.currentRate.wifiDown),
                    icon: "arrow.down",
                    tint: AppChrome.download
                )

                Divider().frame(height: 62)

                speedMetric(
                    title: "上传",
                    value: ByteFormat.rate(store.currentRate.cellularUp + store.currentRate.wifiUp),
                    icon: "arrow.up",
                    tint: AppChrome.upload
                )
            }
        }
        .netFlowCard(cornerRadius: 22)
    }

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近 7 天")
                    .font(.headline)

                Spacer()

                Text(ByteFormat.string(recentRecords.reduce(0) { $0 &+ $1.totalBytes }))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if recentRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("暂无流量记录")
                        .font(.headline)
                    Text("使用一段时间后这里会显示每日趋势")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 170)
            } else {
                Chart(recentRecords) { record in
                    AreaMark(
                        x: .value("日期", record.date, unit: .day),
                        y: .value("流量", record.totalBytes)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.indigo.opacity(0.32),
                                Color.indigo.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("日期", record.date, unit: .day),
                        y: .value("流量", record.totalBytes)
                    )
                    .foregroundStyle(Color.indigo)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                    PointMark(
                        x: .value("日期", record.date, unit: .day),
                        y: .value("流量", record.totalBytes)
                    )
                    .foregroundStyle(Color.indigo)
                    .symbolSize(22)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel {
                            if let bytes = value.as(UInt64.self) {
                                Text(ByteFormat.string(bytes))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .frame(height: 190)
            }
        }
        .netFlowCard(cornerRadius: 22)
    }

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("网络状态")
                .font(.headline)

            statusRow(
                icon: context.connection.isWiFiActive ? "wifi" : "antenna.radiowaves.left.and.right",
                title: "当前连接",
                value: connectionName,
                tint: isConnected ? .green : .secondary
            )

            Divider()

            statusRow(
                icon: "globe",
                title: "公网 IP",
                value: context.connection.publicIP ?? "—",
                tint: .blue
            )

            Divider()

            statusRow(
                icon: context.connection.isVPNActive ? "lock.shield.fill" : "lock.shield",
                title: "VPN",
                value: context.connection.isVPNActive ? "已连接" : "未连接",
                tint: context.connection.isVPNActive ? .green : .secondary
            )
        }
        .netFlowCard(cornerRadius: 22)
    }

    private func metricTile(
        title: String,
        value: String,
        subtitle: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.64)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .netFlowCard(cornerRadius: 20)
    }

    private func speedMetric(
        title: String,
        value: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(
        icon: String,
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .textSelection(.enabled)
        }
    }

    private var isConnected: Bool {
        context.connection.isWiFiActive || context.connection.isCellularActive
    }

    private var connectionName: String {
        if context.connection.isWiFiActive {
            return "Wi‑Fi"
        }
        if context.connection.isCellularActive {
            return "蜂窝网络"
        }
        return "未连接"
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
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
