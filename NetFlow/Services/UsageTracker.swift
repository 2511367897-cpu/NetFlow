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
    }

    private struct CounterDiff {
        var bytes: NetworkCounter
        var stableForRate: Bool
    }

    func sample(previous external: NetworkSnapshot) -> SampleResult {
        let current = reader.read()
        let baseline = previous ?? (external.timestamp == .distantPast ? nil : external)
        defer { previous = current }

        guard let old = baseline else {
            return SampleResult(snapshot: current, delta: .zero, rate: .zero)
        }

        let elapsed = current.timestamp.timeIntervalSince(old.timestamp)
        let seconds = max(elapsed, 0.001)

        let wifiDiff = diff(
            currentInterfaces: current.wifiInterfaces,
            previousInterfaces: old.wifiInterfaces,
            currentAggregate: current.wifi,
            previousAggregate: old.wifi
        )
        let cellularDiff = diff(
            currentInterfaces: current.cellularInterfaces,
            previousInterfaces: old.cellularInterfaces,
            currentAggregate: current.cellular,
            previousAggregate: old.cellular
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

        return SampleResult(snapshot: current, delta: d, rate: r)
    }

    func resetBaseline() {
        previous = nil
    }

    private func diff(
        currentInterfaces: [String: NetworkCounter]?,
        previousInterfaces: [String: NetworkCounter]?,
        currentAggregate: NetworkCounter,
        previousAggregate: NetworkCounter
    ) -> CounterDiff {
        if let currentInterfaces,
           let previousInterfaces {
            return diffInterfaces(current: currentInterfaces, previous: previousInterfaces)
        }

        // Migration fallback for snapshots stored by older builds. A regression
        // no longer invalidates the entire sample: treat that individual counter
        // as having reset and keep the bytes observed after the reset.
        return diffCounter(current: currentAggregate, previous: previousAggregate)
    }

    private func diffInterfaces(
        current: [String: NetworkCounter],
        previous: [String: NetworkCounter]
    ) -> CounterDiff {
        var total = NetworkCounter.zero
        var stableForRate = true

        for (name, currentCounter) in current {
            if let previousCounter = previous[name] {
                let part = diffCounter(current: currentCounter, previous: previousCounter)
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
        if previous.keys.contains(where: { current[$0] == nil }) {
            stableForRate = false
        }

        return CounterDiff(bytes: total, stableForRate: stableForRate)
    }

    private func diffCounter(current: NetworkCounter, previous: NetworkCounter) -> CounterDiff {
        let receivedStable = current.received >= previous.received
        let sentStable = current.sent >= previous.sent

        let received = receivedStable
            ? current.received - previous.received
            : current.received
        let sent = sentStable
            ? current.sent - previous.sent
            : current.sent

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
