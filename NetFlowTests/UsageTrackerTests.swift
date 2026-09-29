import XCTest
@testable import NetFlow

final class UsageTrackerTests: XCTestCase {
    private final class StubReader: NetworkSnapshotReading {
        var snapshots: [NetworkSnapshot]

        init(_ snapshots: [NetworkSnapshot]) {
            self.snapshots = snapshots
        }

        func read() -> NetworkSnapshot {
            snapshots.removeFirst()
        }
    }

    private func snapshot(_ timestamp: TimeInterval, wifi: UInt64, cellular: UInt64) -> NetworkSnapshot {
        NetworkSnapshot(
            wifi: NetworkCounter(received: wifi, sent: 10),
            cellular: NetworkCounter(received: cellular, sent: 20),
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }

    func testFirstSampleUsesZeroDeltaAndSecondSampleCalculatesRate() {
        let reader = StubReader([
            snapshot(100, wifi: 100, cellular: 300),
            snapshot(110, wifi: 160, cellular: 500)
        ])
        let tracker = UsageTracker(reader: reader)

        let first = tracker.sample(previous: .zero)
        XCTAssertFalse(first.delta.isValid)
        XCTAssertEqual(first.delta.totalBytes, 0)

        let second = tracker.sample(previous: first.snapshot)
        XCTAssertTrue(second.delta.isValid)
        XCTAssertEqual(second.delta.wifiReceived, 60)
        XCTAssertEqual(second.delta.cellularReceived, 200)
        XCTAssertEqual(second.rate.cellularDown, 20, accuracy: 0.001)
    }

    func testLongGapCountsUsageButDoesNotPretendToBeLiveSpeed() {
        let reader = StubReader([
            snapshot(100, wifi: 100, cellular: 300),
            snapshot(200, wifi: 300, cellular: 700)
        ])
        let tracker = UsageTracker(reader: reader)

        let first = tracker.sample(previous: .zero)
        let result = tracker.sample(previous: first.snapshot)

        XCTAssertTrue(result.delta.isValid)
        XCTAssertEqual(result.delta.wifiReceived, 200)
        XCTAssertEqual(result.delta.cellularReceived, 400)
        XCTAssertEqual(result.rate, .zero)
    }

    func testClockRollbackKeepsUsageButSuppressesLiveRate() {
        let reader = StubReader([
            snapshot(100, wifi: 100, cellular: 300),
            snapshot(90, wifi: 160, cellular: 500)
        ])
        let tracker = UsageTracker(reader: reader)

        let first = tracker.sample(previous: .zero)
        let result = tracker.sample(previous: first.snapshot)

        XCTAssertTrue(result.delta.isValid)
        XCTAssertEqual(result.delta.wifiReceived, 60)
        XCTAssertEqual(result.delta.cellularReceived, 200)
        XCTAssertEqual(result.rate, .zero)
    }

    func testCounterResetSalvagesBytesAfterReset() {
        let reader = StubReader([
            snapshot(100, wifi: 100, cellular: 300),
            snapshot(110, wifi: 90, cellular: 350)
        ])
        let tracker = UsageTracker(reader: reader)

        _ = tracker.sample(previous: .zero)
        let result = tracker.sample(previous: snapshot(100, wifi: 100, cellular: 300))

        XCTAssertTrue(result.delta.isValid)
        XCTAssertEqual(result.delta.wifiReceived, 90)
        XCTAssertEqual(result.delta.cellularReceived, 50)
        XCTAssertEqual(result.rate, .zero)
    }

    func testInterfaceChurnDoesNotEraseOtherCellularTraffic() {
        let old = NetworkSnapshot(
            wifi: .zero,
            cellular: NetworkCounter(received: 1_500, sent: 150),
            timestamp: Date(timeIntervalSince1970: 100),
            wifiInterfaces: [:],
            cellularInterfaces: [
                "pdp_ip0": NetworkCounter(received: 1_000, sent: 100),
                "pdp_ip1": NetworkCounter(received: 500, sent: 50)
            ]
        )
        let current = NetworkSnapshot(
            wifi: .zero,
            cellular: NetworkCounter(received: 1_240, sent: 124),
            timestamp: Date(timeIntervalSince1970: 110),
            wifiInterfaces: [:],
            cellularInterfaces: [
                "pdp_ip0": NetworkCounter(received: 1_200, sent: 120),
                "pdp_ip2": NetworkCounter(received: 40, sent: 4)
            ]
        )
        let tracker = UsageTracker(reader: StubReader([current]))

        let result = tracker.sample(previous: old)

        XCTAssertTrue(result.delta.isValid)
        XCTAssertEqual(result.delta.cellularReceived, 240)
        XCTAssertEqual(result.delta.cellularSent, 24)
        XCTAssertEqual(result.rate, .zero)
    }
}
