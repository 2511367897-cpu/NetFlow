import Foundation

protocol NetworkSnapshotReading {
    func read() -> NetworkSnapshot
}

extension NetworkInterfaceReader: NetworkSnapshotReading {}

final class UsageTracker {
    private let reader: any NetworkSnapshotReading
    private var previous: NetworkSnapshot?

    init(reader: any NetworkSnapshotReading = NetworkInterfaceReader()) {
        self.reader = reader
    }

    struct SampleResult {
        var snapshot: NetworkSnapshot
        var delta: NetworkDelta
        var rate: NetworkRate
        var didRead = true
        var warning: String? = nil
    }

    private struct CounterDiff {
        var bytes: NetworkCounter
        var stableForRate: Bool
    }

    func sample(previous external: NetworkSnapshot) -> SampleResult {
        var current = reader.read()
        let baseline = previous ?? (external.timestamp == .distantPast ? nil : external)
        guard current.readSucceeded != false else {
            // A failed read is not a zero counter or a new baseline.
            return SampleResult(snapshot: baseline ?? .zero, delta: .zero, rate: .zero, didRead: false, warning: "系统计数暂时不可读，保留上次基线")
        }
        guard let old = baseline else {
            previous = current
            return SampleResult(snapshot: current, delta: .zero, rate: .zero)
        }

        let rebooted = current.bootTime != nil && old.bootTime != nil
            && abs(current.bootTime! - old.bootTime!) > 1
        guard InterfaceCounters.canAdvanceBaseline(currentBits: current.counterBits,
                                                   previousBits: old.counterBits, rebooted: rebooted) else {
            return SampleResult(snapshot: old, delta: .zero, rate: .zero, didRead: false, warning: "64 位计数暂不可用，等待恢复后补记")
        }
        defer { previous = current }
        let changedWidth = current.counterBits != nil && current.counterBits != old.counterBits
        if changedWidth && !rebooted {
            // Do not subtract a 32-bit fallback from a 64-bit lifetime counter.
            return SampleResult(snapshot: current, delta: .zero, rate: .zero, warning: "计数位宽发生切换，本段无法可靠还原")
        }
        let rememberedWiFi = rebooted ? [:] : (old.rememberedWiFiInterfaces ?? old.wifiInterfaces ?? [:])
        let rememberedCellular = rebooted ? [:] : (old.rememberedCellularInterfaces ?? old.cellularInterfaces ?? [:])
        current.rememberedWiFiInterfaces = rememberedWiFi.merging(current.wifiInterfaces ?? [:]) { _, new in new }
        current.rememberedCellularInterfaces = rememberedCellular.merging(current.cellularInterfaces ?? [:]) { _, new in new }
        let elapsed = current.timestamp.timeIntervalSince(old.timestamp)
        let seconds = max(elapsed, 0.001)

        let wifiDiff = diff(
            currentInterfaces: current.wifiInterfaces,
            previousInterfaces: old.wifiInterfaces == nil ? nil : rememberedWiFi,
            currentAggregate: current.wifi,
            previousAggregate: rebooted ? .zero : old.wifi, bits: current.counterBits ?? 64, elapsed: elapsed
        )
        let cellularDiff = diff(
            currentInterfaces: current.cellularInterfaces,
            previousInterfaces: old.cellularInterfaces == nil ? nil : rememberedCellular,
            currentAggregate: current.cellular,
            previousAggregate: rebooted ? .zero : old.cellular, bits: current.counterBits ?? 64, elapsed: elapsed
        )

        let d = NetworkDelta(
            wifiReceived: wifiDiff.bytes.received,
            wifiSent: wifiDiff.bytes.sent,
            cellularReceived: cellularDiff.bytes.received,
            cellularSent: cellularDiff.bytes.sent,
            isValid: true
        )

        let r: NetworkRate
        if elapsed >= 0.2,
           elapsed <= 10,
           !rebooted,
           current.wifiInterfaces?.keys.sorted() == old.wifiInterfaces?.keys.sorted(),
           current.cellularInterfaces?.keys.sorted() == old.cellularInterfaces?.keys.sorted(),
           wifiDiff.stableForRate,
           cellularDiff.stableForRate {
            r = NetworkRate(
                wifiDown: Double(d.wifiReceived) / seconds,
                wifiUp: Double(d.wifiSent) / seconds,
                cellularDown: Double(d.cellularReceived) / seconds,
                cellularUp: Double(d.cellularSent) / seconds
            )
        } else {
            // Long gaps, clock changes, newly-created interfaces and counter
            // resets are valid for usage accounting, but not for live speed.
            r = .zero
        }

        let warning: String?
        if rebooted {
            warning = "检测到手机重启，重启前未采样的尾段无法恢复"
        } else if current.counterBits == 32 && (elapsed > 2 || elapsed <= 0) {
            warning = "32 位计数采样间隔过长，可能遗漏整圈流量（每圈 4.29 GB）"
        } else if !wifiDiff.stableForRate || !cellularDiff.stableForRate
                    || current.wifiInterfaces?.keys.sorted() != old.wifiInterfaces?.keys.sorted()
                    || current.cellularInterfaces?.keys.sorted() != old.cellularInterfaces?.keys.sorted() {
            warning = "接口或计数发生变化，请留意统计空档"
        } else if elapsed > 60 {
            warning = "采样存在空档；跨日用量按时长分摊，日清单为估算"
        } else { warning = nil }
        return SampleResult(snapshot: current, delta: d, rate: r, warning: warning)
    }

    func resetBaseline() {
        previous = nil
    }

    private func diff(
        currentInterfaces: [String: NetworkCounter]?,
        previousInterfaces: [String: NetworkCounter]?,
        currentAggregate: NetworkCounter,
        previousAggregate: NetworkCounter, bits: Int, elapsed: TimeInterval
    ) -> CounterDiff {
        if let currentInterfaces,
           let previousInterfaces {
            return diffInterfaces(current: currentInterfaces, previous: previousInterfaces, bits: bits, elapsed: elapsed)
        }

        // Migration fallback for snapshots stored by older builds. A regression
        // no longer invalidates the entire sample: treat that individual counter
        // as having reset and keep the bytes observed after the reset.
        return diffCounter(current: currentAggregate, previous: previousAggregate, bits: bits, elapsed: elapsed)
    }

    private func diffInterfaces(
        current: [String: NetworkCounter],
        previous: [String: NetworkCounter], bits: Int, elapsed: TimeInterval
    ) -> CounterDiff {
        var total = NetworkCounter.zero
        var stableForRate = true

        for (name, currentCounter) in current {
            if let previousCounter = previous[name] {
                let part = diffCounter(current: currentCounter, previous: previousCounter, bits: bits, elapsed: elapsed)
                total = saturatingAdd(total, part.bytes)
                stableForRate = stableForRate && part.stableForRate
            } else {
                // An interface appeared after the last sample. Its current
                // counter represents traffic accumulated since that interface
                // was created, so keep it instead of discarding the sample.
                total = saturatingAdd(total, currentCounter)
                stableForRate = false
            }
        }

        // A vanished interface can make the old aggregate larger than the new
        // aggregate. Per-interface accounting prevents that unrelated churn from
        // erasing deltas on interfaces that are still present.

        return CounterDiff(bytes: total, stableForRate: stableForRate)
    }

    private func diffCounter(current: NetworkCounter, previous: NetworkCounter, bits: Int, elapsed: TimeInterval) -> CounterDiff {
        let receivedStable = current.received >= previous.received
        let sentStable = current.sent >= previous.sent

        let received = InterfaceCounters.difference(current: current.received, previous: previous.received, bits: bits, elapsed: elapsed)
        let sent = InterfaceCounters.difference(current: current.sent, previous: previous.sent, bits: bits, elapsed: elapsed)

        return CounterDiff(
            bytes: NetworkCounter(received: received, sent: sent),
            stableForRate: receivedStable && sentStable
        )
    }

    private func saturatingAdd(_ lhs: NetworkCounter, _ rhs: NetworkCounter) -> NetworkCounter {
        NetworkCounter(
            received: saturatingAdd(lhs.received, rhs.received),
            sent: saturatingAdd(lhs.sent, rhs.sent)
        )
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}
