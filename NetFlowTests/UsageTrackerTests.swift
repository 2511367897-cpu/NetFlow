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
    private func interfaces(_ time: TimeInterval, _ cellular: [String: UInt64],
                            wifi: [String: UInt64] = [:], bits: Int = 64, boot: TimeInterval = 1) -> NetworkSnapshot {
        let cell = cellular.mapValues { NetworkCounter(received: $0, sent: 0) }
        let wireless = wifi.mapValues { NetworkCounter(received: $0, sent: 0) }
        return NetworkSnapshot(wifi: NetworkCounter(received: wifi.values.reduce(0, InterfaceCounters.add), sent: 0),
                               cellular: NetworkCounter(received: cellular.values.reduce(0, InterfaceCounters.add), sent: 0),
                               timestamp: Date(timeIntervalSince1970: time), wifiInterfaces: wireless,
                               cellularInterfaces: cell, counterBits: bits, bootTime: boot)
    }

    func testNormalPerInterfaceDeltaIs500() {
        let old = interfaces(100, ["pdp_ip0": 1_000])
        let tracker = UsageTracker(reader: StubReader([interfaces(101, ["pdp_ip0": 1_500])]))
        XCTAssertEqual(tracker.sample(previous: old).delta.cellularReceived, 500)
    }

    func testOneInterfaceResetKeepsPostResetAndOtherInterfaceDelta() {
        let old = interfaces(100, ["pdp_ip0": 5_000, "pdp_ip1": 1_000])
        let tracker = UsageTracker(reader: StubReader([interfaces(101, ["pdp_ip0": 300, "pdp_ip1": 1_200])]))
        let sample = tracker.sample(previous: old)
        XCTAssertEqual(sample.delta.cellularReceived, 500)
        XCTAssertEqual(sample.rate, .zero)
    }

    func testWiFiResetKeepsCellularDelta() {
        let old = interfaces(100, ["pdp_ip0": 1_000], wifi: ["en0": 5_000])
        let tracker = UsageTracker(reader: StubReader([interfaces(101, ["pdp_ip0": 1_200], wifi: ["en0": 300])]))
        let sample = tracker.sample(previous: old)
        XCTAssertEqual(sample.delta.wifiReceived, 300)
        XCTAssertEqual(sample.delta.cellularReceived, 200)
    }

    func testNewInterfaceAddsItsCounter() {
        let tracker = UsageTracker(reader: StubReader([interfaces(101, ["pdp_ip0": 40])]))
        XCTAssertEqual(tracker.sample(previous: interfaces(100, [:])).delta.cellularReceived, 40)
    }

    func testDisappearingInterfaceDoesNotLoseSurvivingDelta() {
        let tracker = UsageTracker(reader: StubReader([interfaces(101, ["pdp_ip0": 1_200])]))
        let sample = tracker.sample(previous: interfaces(100, ["pdp_ip0": 1_000, "pdp_ip1": 500]))
        XCTAssertEqual(sample.delta.cellularReceived, 200)
        XCTAssertEqual(sample.rate, .zero)
    }

    func testReturningInterfaceIsNotCountedTwiceEvenAfterAppRestart() throws {
        let old = interfaces(100, ["pdp_ip0": 1_000, "pdp_ip1": 500])
        let tracker = UsageTracker(reader: StubReader([interfaces(101, ["pdp_ip0": 1_200])]))
        let disappeared = tracker.sample(previous: old)
        let persisted = try JSONEncoder.pretty.encode(disappeared.snapshot)
        let restored = try JSONDecoder.netFlow.decode(NetworkSnapshot.self, from: persisted)
        let restarted = UsageTracker(reader: StubReader([interfaces(102, ["pdp_ip0": 1_300, "pdp_ip1": 550])]))
        XCTAssertEqual(restarted.sample(previous: restored).delta.cellularReceived, 150)
    }

    func testFailedReadDoesNotAdvanceBaseline() {
        let failed = NetworkSnapshot(wifi: .zero, cellular: .zero,
                                     timestamp: Date(timeIntervalSince1970: 101), readSucceeded: false)
        let old = interfaces(100, ["pdp_ip0": 1_000])
        let tracker = UsageTracker(reader: StubReader([failed, interfaces(102, ["pdp_ip0": 1_500])]))
        let failure = tracker.sample(previous: old)
        XCTAssertEqual(failure.snapshot, old)
        XCTAssertFalse(failure.delta.isValid)
        XCTAssertEqual(tracker.sample(previous: failure.snapshot).delta.cellularReceived, 500)
    }

    func test64BitCountersRecoverSeveralGigabytesAfterLongBackground() {
        let old = interfaces(100, ["pdp_ip0": 4_000_000_000])
        let tracker = UsageTracker(reader: StubReader([interfaces(86_500, ["pdp_ip0": 11_100_000_000])]))
        let sample = tracker.sample(previous: old)
        XCTAssertEqual(sample.delta.cellularReceived, 7_100_000_000)
        XCTAssertEqual(sample.rate, .zero)
    }

    func test32BitFallbackRecognizesNearBoundaryWrap() {
        let old = interfaces(100, ["pdp_ip0": UInt64(UInt32.max) - 99], bits: 32)
        let tracker = UsageTracker(reader: StubReader([interfaces(101, ["pdp_ip0": 400], bits: 32)]))
        XCTAssertEqual(tracker.sample(previous: old).delta.cellularReceived, 500)
    }

    func testWidthMigrationDoesNotInjectLifetimeTraffic() {
        let old = interfaces(100, ["pdp_ip0": 100], bits: 32)
        let tracker = UsageTracker(reader: StubReader([interfaces(101, ["pdp_ip0": 8_589_934_792])]))
        let sample = tracker.sample(previous: old)
        XCTAssertEqual(sample.delta.totalBytes, 0)
        XCTAssertEqual(sample.rate, .zero)
    }

    func testPhoneRebootCountsNewCountersEvenIfLargerThanOld() {
        let old = interfaces(100, ["pdp_ip0": 100], boot: 1)
        let tracker = UsageTracker(reader: StubReader([interfaces(200, ["pdp_ip0": 500], boot: 150)]))
        let sample = tracker.sample(previous: old)
        XCTAssertEqual(sample.delta.cellularReceived, 500)
        XCTAssertEqual(sample.rate, .zero)
    }

    func testOverflowSaturatesInsteadOfTrappingOrWrapping() {
        let tracker = UsageTracker(reader: StubReader([interfaces(101, ["pdp_ip0": .max, "pdp_ip1": 2])]))
        XCTAssertEqual(tracker.sample(previous: interfaces(100, [:])).delta.cellularReceived, UInt64.max)
        var record = DailyUsageRecord(date: Date(), delta: NetworkDelta(wifiReceived: .max, wifiSent: 1,
            cellularReceived: .max, cellularSent: 1, isValid: true), firstUpdated: Date(), lastUpdated: Date())
        record.add(NetworkDelta(wifiReceived: 1, wifiSent: 0, cellularReceived: 1, cellularSent: 0, isValid: true))
        XCTAssertEqual(record.totalBytes, UInt64.max)
        XCTAssertEqual(record.wifiReceived, UInt64.max)
    }

}
