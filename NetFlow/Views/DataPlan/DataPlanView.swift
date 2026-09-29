import SwiftUI

enum CapacityDisplayUnit: String, CaseIterable, Identifiable {
    case mb = "MB"
    case gb = "GB"
    case tb = "TB"

    var id: String { rawValue }
    var multiplier: Double {
        switch self {
        case .mb: return 1_000_000
        case .gb: return 1_000_000_000
        case .tb: return 1_000_000_000_000
        }
    }
}

struct DataPlanView: View {
    @EnvironmentObject var store: AppStore
    @State private var capacityValue = 30.0
    @State private var capacityUnit: CapacityDisplayUnit = .gb
    @State private var calibrationValue = 0.0
    @State private var calibrationUnit: CapacityDisplayUnit = .gb
    @State private var editingThreshold: AlertThreshold?
    @FocusState private var capacityFieldFocused: Bool
    @FocusState private var calibrationFieldFocused: Bool

    private var appLocale: Locale { store.settings.appLanguage.locale }

    private let selectableCycles: [PlanCycleType] = [.daily, .monthly, .yearly, .custom, .unlimited]

    var body: some View {
        ScrollView {
            VStack(spacing: AppChrome.spacing) {
                cardSection("plan") {
                    Picker("cycle", selection: $store.plan.cycleType) {
                        ForEach(selectableCycles) { cycle in
                            Text(LocalizedStringKey(cycle.rawValue)).tag(cycle)
                        }
                    }
                    .pickerStyle(.menu)

                    if !store.plan.isUnlimited {
                        HStack {
                            TextField("capacity", value: $capacityValue, format: .number)
                                .keyboardType(.decimalPad)
                                .focused($capacityFieldFocused)
                                .submitLabel(.done)

                            Picker("unit", selection: $capacityUnit) {
                                ForEach(CapacityDisplayUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        Toggle("rollover", isOn: $store.plan.rolloverEnabled)

                        if store.plan.cycleType == .monthly {
                            Stepper(value: $store.plan.monthlyResetDay, in: 1...31) {
                                Text("\(AppLocalization.string("reset_day", locale: appLocale)) \(store.plan.monthlyResetDay)")
                            }
                        }

                        if store.plan.cycleType == .yearly {
                            Stepper(value: $store.plan.yearlyResetMonth, in: 1...12) {
                                Text("\(AppLocalization.string("reset_month", locale: appLocale)) \(store.plan.yearlyResetMonth)")
                            }
                            Stepper(value: $store.plan.yearlyResetDay, in: 1...31) {
                                Text("\(AppLocalization.string("reset_day", locale: appLocale)) \(store.plan.yearlyResetDay)")
                            }
                        }

                        if store.plan.cycleType == .custom {
                            Stepper(value: $store.plan.customDays, in: 1...365) {
                                Text("\(AppLocalization.string("custom_days", locale: appLocale)) \(store.plan.customDays)")
                            }
                        }
                    }
                }

                if !store.plan.isUnlimited {
                    cardSection("流量校准") {
                        LabeledContent(
                            "当前套餐已用",
                            value: ByteFormat.string(store.planUsage())
                        )

                        HStack {
                            TextField("运营商已用流量", value: $calibrationValue, format: .number)
                                .keyboardType(.decimalPad)
                                .focused($calibrationFieldFocused)
                                .submitLabel(.done)

                            Picker("单位", selection: $calibrationUnit) {
                                ForEach(CapacityDisplayUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        Button {
                            capacityFieldFocused = false
                            calibrationFieldFocused = false
                            store.calibratePlanUsage(to: calibrationBytes)
                            loadCalibrationEditor()
                        } label: {
                            Label("按运营商数据校准", systemImage: "scope")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        if let calibratedAt = store.plan.lastCalibrationDate {
                            Text("上次校准：\(calibratedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if store.plan.usageCorrectionBytes != nil {
                            Button("清除校准") {
                                store.clearUsageCalibration()
                                loadCalibrationEditor()
                            }
                            .font(.subheadline)
                        }

                        Text("当 NetFlow 与运营商 App 的本周期已用流量差距较大时，把运营商数字填在这里。校准后会以该数值为基准继续累计，不需要每天手动改。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let forecast = store.plan.forecast(records: store.dailyRecords) {
                    cardSection("forecast") {
                        LabeledContent(
                            AppLocalization.string("average_per_day", locale: appLocale),
                            value: ByteFormat.string(forecast.averageDailyBytes)
                        )

                        LabeledContent(
                            AppLocalization.string("projected_cycle_usage", locale: appLocale),
                            value: ByteFormat.string(forecast.projectedBytes)
                        )

                        LabeledContent(
                            AppLocalization.string("cycle_ends", locale: appLocale),
                            value: forecast.cycleEnd.formatted(date: .abbreviated, time: .omitted)
                        )

                        Label(
                            forecast.isProjectedToExceed
                                ? AppLocalization.string("forecast_over_limit", locale: appLocale)
                                : AppLocalization.string("forecast_within_limit", locale: appLocale),
                            systemImage: forecast.isProjectedToExceed
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(forecast.isProjectedToExceed ? Color.orange : Color.green)
                    }
                }

                cardSection("alerts") {
                    if store.plan.alertThresholds.isEmpty {
                        Text("暂无流量提醒")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($store.plan.alertThresholds) { $threshold in
                            HStack(spacing: 10) {
                                Button {
                                    capacityFieldFocused = false
                                    editingThreshold = threshold
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: threshold.kind == .percentUsed
                                              ? "percent"
                                              : "gauge.with.dots.needle.50percent")
                                            .frame(width: 24)
                                            .foregroundStyle(.blue)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(alertTitle(threshold))
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)

                                            Text(threshold.kind == .percentUsed
                                                 ? "达到此使用比例时提醒"
                                                 : "剩余流量低于此数值时提醒")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }

                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Toggle("", isOn: $threshold.enabled)
                                    .labelsHidden()

                                Button(role: .destructive) {
                                    deleteAlert(id: threshold.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.red)
                                        .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除提醒")
                            }
                            .padding(.vertical, 3)

                            if threshold.id != store.plan.alertThresholds.last?.id {
                                Divider()
                            }
                        }
                    }

                    Button {
                        addOrEditAlert(kind: .percentUsed, value: 90)
                    } label: {
                        Label("添加百分比提醒", systemImage: "plus.circle")
                    }

                    Button {
                        addOrEditAlert(kind: .remainingBytes, value: 1_000_000_000)
                    } label: {
                        Label("添加剩余流量提醒", systemImage: "plus.circle")
                    }
                }
            }
            .padding(AppChrome.pagePadding)
        }
        .netFlowPageBackground()
        .navigationTitle(Text(verbatim: AppLocalization.string("data_plan", locale: appLocale)))
        .scrollDismissesKeyboard(.interactively)
        .contentShape(Rectangle())
        .onTapGesture {
            capacityFieldFocused = false
            calibrationFieldFocused = false
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("done") {
                    capacityFieldFocused = false
                    calibrationFieldFocused = false
                }
            }
        }
        .sheet(item: $editingThreshold) { threshold in
            AlertThresholdEditor(
                threshold: threshold,
                onSave: { updated in
                    updateAlert(updated)
                },
                onDelete: {
                    deleteAlert(id: threshold.id)
                }
            )
        }
        .onAppear {
            loadCapacityEditor()
            loadCalibrationEditor()
            deduplicateAlerts()
        }
        .onChange(of: capacityValue) { _ in saveCapacityEditor() }
        .onChange(of: capacityUnit) { _ in saveCapacityEditor() }
        .onChange(of: store.plan) { _ in store.save() }
    }

    private func cardSection<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .netFlowSectionTitle()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .netFlowCard(cornerRadius: 18)
    }

    private func alertTitle(_ threshold: AlertThreshold) -> String {
        switch threshold.kind {
        case .percentUsed:
            return "\(Int(threshold.value.rounded()))%"
        case .remainingBytes:
            return ByteFormat.string(UInt64(max(threshold.value, 0)))
        }
    }

    private func addOrEditAlert(kind: AlertThreshold.Kind, value: Double) {
        capacityFieldFocused = false

        if let existing = store.plan.alertThresholds.first(where: {
            $0.kind == kind && abs($0.value - value) < 0.5
        }) {
            editingThreshold = existing
            return
        }

        let threshold = AlertThreshold(kind: kind, value: value)
        store.plan.alertThresholds.append(threshold)
        store.save()
        editingThreshold = threshold
    }

    private func updateAlert(_ updated: AlertThreshold) {
        guard let index = store.plan.alertThresholds.firstIndex(where: { $0.id == updated.id }) else {
            return
        }

        store.plan.alertThresholds[index] = updated

        // 编辑过阈值后允许它在当前套餐周期内重新触发。
        let idText = updated.id.uuidString
        store.plan.triggeredAlertIDs = Set(
            store.plan.triggeredAlertIDs.filter { !$0.contains(idText) }
        )

        deduplicateAlerts()
        store.save()
        editingThreshold = nil
    }

    private func deleteAlert(id: UUID) {
        store.plan.alertThresholds.removeAll { $0.id == id }

        let idText = id.uuidString
        store.plan.triggeredAlertIDs = Set(
            store.plan.triggeredAlertIDs.filter { !$0.contains(idText) }
        )

        store.save()

        if editingThreshold?.id == id {
            editingThreshold = nil
        }
    }

    private func deduplicateAlerts() {
        var seen = Set<String>()
        let originalCount = store.plan.alertThresholds.count

        store.plan.alertThresholds = store.plan.alertThresholds.filter { threshold in
            let normalizedValue = threshold.value.isFinite
                ? threshold.value.rounded()
                : 0
            let key = "\(threshold.kind.rawValue):\(normalizedValue)"
            return seen.insert(key).inserted
        }

        if store.plan.alertThresholds.count != originalCount {
            store.save()
        }
    }

    private var calibrationBytes: UInt64 {
        let rawBytes = calibrationValue.isFinite
            ? max(calibrationValue, 0) * calibrationUnit.multiplier
            : 0
        let clamped = min(max(rawBytes, 0), Double(UInt64.max))
        return UInt64(clamped)
    }

    private func loadCalibrationEditor() {
        let bytes = store.plan.lastCalibrationTargetBytes ?? store.planUsage()

        if bytes >= UInt64(CapacityDisplayUnit.tb.multiplier) {
            calibrationUnit = .tb
        } else if bytes >= UInt64(CapacityDisplayUnit.gb.multiplier) {
            calibrationUnit = .gb
        } else {
            calibrationUnit = .mb
        }

        calibrationValue = Double(bytes) / calibrationUnit.multiplier
    }

    private func loadCapacityEditor() {
        capacityUnit = CapacityDisplayUnit(rawValue: store.plan.capacityDisplayUnitRaw ?? "GB") ?? .gb
        capacityValue = Double(store.plan.capacityBytes) / capacityUnit.multiplier
    }

    private func saveCapacityEditor() {
        store.plan.capacityDisplayUnitRaw = capacityUnit.rawValue
        let rawBytes = capacityValue.isFinite
            ? max(capacityValue, 0) * capacityUnit.multiplier
            : 0
        let bytes = min(max(rawBytes, 0), Double(UInt64.max))
        store.plan.capacityBytes = UInt64(bytes)
        store.save()
    }
}

private struct AlertThresholdEditor: View {
    let threshold: AlertThreshold
    let onSave: (AlertThreshold) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: Double
    @State private var enabled: Bool
    @State private var remainingUnit: CapacityDisplayUnit

    init(
        threshold: AlertThreshold,
        onSave: @escaping (AlertThreshold) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.threshold = threshold
        self.onSave = onSave
        self.onDelete = onDelete
        _enabled = State(initialValue: threshold.enabled)

        if threshold.kind == .percentUsed {
            _value = State(initialValue: threshold.value)
            _remainingUnit = State(initialValue: .gb)
        } else {
            let bestUnit: CapacityDisplayUnit
            if threshold.value >= CapacityDisplayUnit.gb.multiplier {
                bestUnit = .gb
            } else {
                bestUnit = .mb
            }
            _remainingUnit = State(initialValue: bestUnit)
            _value = State(initialValue: threshold.value / bestUnit.multiplier)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("提醒类型") {
                    LabeledContent(
                        "类型",
                        value: threshold.kind == .percentUsed ? "使用百分比" : "剩余流量"
                    )
                    Toggle("启用提醒", isOn: $enabled)
                }

                Section("提醒阈值") {
                    if threshold.kind == .percentUsed {
                        HStack {
                            TextField("百分比", value: $value, format: .number)
                                .keyboardType(.decimalPad)
                            Text("%")
                                .foregroundStyle(.secondary)
                        }

                        Slider(value: $value, in: 1...100, step: 1)

                        Text("当套餐使用达到 \(Int(value.rounded()))% 时提醒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            TextField("剩余流量", value: $value, format: .number)
                                .keyboardType(.decimalPad)

                            Picker("单位", selection: $remainingUnit) {
                                Text("MB").tag(CapacityDisplayUnit.mb)
                                Text("GB").tag(CapacityDisplayUnit.gb)
                            }
                            .pickerStyle(.menu)
                        }

                        Text("当套餐剩余流量低于 \(formattedRemainingValue) 时提醒")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("删除此提醒", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle("编辑流量提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = threshold
                        updated.enabled = enabled

                        switch threshold.kind {
                        case .percentUsed:
                            updated.value = min(max(value, 1), 100)
                        case .remainingBytes:
                            let rawBytes = value.isFinite
                                ? max(value, 0) * remainingUnit.multiplier
                                : 0
                            updated.value = min(max(rawBytes, 0), Double(UInt64.max))
                        }

                        onSave(updated)
                        dismiss()
                    }
                }
            }
        }
    }

    private var formattedRemainingValue: String {
        let rawBytes = value.isFinite
            ? max(value, 0) * remainingUnit.multiplier
            : 0
        let bytes = min(max(rawBytes, 0), Double(UInt64.max))
        return ByteFormat.string(UInt64(bytes))
    }
}
