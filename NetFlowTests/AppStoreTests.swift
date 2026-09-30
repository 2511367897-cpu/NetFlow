import XCTest
@testable import NetFlow

@MainActor
final class AppStoreTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testMergeSplitsTrafficAcrossLocalMidnightAndPreservesTotal() {
        let store = AppStore()
        store.dailyRecords = []

        store.merge(
            delta: NetworkDelta(
                wifiReceived: 100,
                wifiSent: 20,
                cellularReceived: 300,
                cellularSent: 80,
                isValid: true
            ),
            from: date(2026, 1, 10, 23),
            to: date(2026, 1, 11, 1)
        )

        XCTAssertEqual(store.dailyRecords.count, 2)
        XCTAssertEqual(store.dailyRecords.reduce(UInt64(0)) { $0 &+ $1.totalBytes }, 500)
        XCTAssertEqual(store.dailyRecords.first(where: { $0.date == date(2026, 1, 10) })?.totalBytes, 250)
        XCTAssertEqual(store.dailyRecords.first(where: { $0.date == date(2026, 1, 11) })?.totalBytes, 250)
    }

    func testMergeSplitsMultiDayGapProportionallyAndPreservesTotal() {
        let store = AppStore()
        store.dailyRecords = []

        store.merge(
            delta: NetworkDelta(
                wifiReceived: 480,
                wifiSent: 0,
                cellularReceived: 0,
                cellularSent: 0,
                isValid: true
            ),
            from: date(2026, 1, 10, 12),
            to: date(2026, 1, 12, 12)
        )

        XCTAssertEqual(store.dailyRecords.reduce(UInt64(0)) { $0 &+ $1.totalBytes }, 480)
        XCTAssertEqual(store.dailyRecords.first(where: { $0.date == date(2026, 1, 10) })?.totalBytes, 120)
        XCTAssertEqual(store.dailyRecords.first(where: { $0.date == date(2026, 1, 11) })?.totalBytes, 240)
        XCTAssertEqual(store.dailyRecords.first(where: { $0.date == date(2026, 1, 12) })?.totalBytes, 120)
        XCTAssertTrue(store.dailyRecords.allSatisfy(\.isEstimated))
    }

    func testPlanUsageIgnoresManualUsageForAClosedCycle() {
        let store = AppStore()
        store.plan.cycleType = .daily
        store.plan.capacityBytes = 1_000
        store.plan.activeCycleStart = date(2026, 1, 11)
        store.plan.activeCycleEnd = date(2026, 1, 12)
        store.plan.manualUsedBytes = 300

        XCTAssertEqual(store.planUsage(at: date(2026, 1, 10, 12)), 0)
        XCTAssertEqual(store.planUsage(at: date(2026, 1, 11, 12)), 300)
    }
    private final class Reader: NetworkSnapshotReading {
        var values: [NetworkSnapshot]
        init(_ values: [NetworkSnapshot]) { self.values = values }
        func read() -> NetworkSnapshot { values.removeFirst() }
    }

    private func isolatedStore(raw: UInt64 = 100_000_000, nextDelta: UInt64 = 0) -> (AppStore, PersistenceService, Date) {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let baseline = NetworkSnapshot(wifi: .zero, cellular: NetworkCounter(received: 1_000, sent: 0), timestamp: now)
        let next = NetworkSnapshot(wifi: .zero, cellular: NetworkCounter(received: 1_000 + nextDelta, sent: 0), timestamp: now.addingTimeInterval(1))
        let reader = Reader([baseline, next, next])
        let persistence = PersistenceService(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("netflow-data.json"))
        let store = AppStore(persistence: persistence, tracker: UsageTracker(reader: reader), notificationsEnabled: false)
        store.dailyRecords = []
        store.alerts = []
        store.liveSnapshot = .zero
        store.plan = DataPlan()
        let interval = store.plan.cycleInterval(containing: now)
        store.plan.activeCycleStart = interval.start
        store.plan.activeCycleEnd = interval.end
        store.merge(delta: NetworkDelta(wifiReceived: 900_000_000, wifiSent: 0,
                    cellularReceived: raw, cellularSent: 0, isValid: true), from: now, to: now)
        return (store, persistence, now)
    }

    func testPositiveCalibrationContinuesAccumulatingAndLeavesHistoryRaw() async {
        let (store, _, now) = isolatedStore(nextDelta: 500_000_000)
        let history = store.dailyRecords
        store.plan.manualUsedBytes = 200_000_000
        store.calibratePlanUsage(to: 7_100_000_000, at: now)
        XCTAssertEqual(store.planUsage(at: now), 7_100_000_000)
        XCTAssertEqual(store.plan.manualUsedBytes, 0)
        XCTAssertEqual(store.dailyRecords, history)
        await store.refresh()
        XCTAssertEqual(store.planUsage(at: now), 7_600_000_000)
        await store.refresh()
        XCTAssertEqual(store.planUsage(at: now), 7_600_000_000)
        XCTAssertEqual(store.dailyRecords.first?.cellularTotalBytes, 600_000_000)
    }

    func testCalibrationConsumesPendingTrafficBeforeOffsetAndCanRepeat() async {
        let (store, _, now) = isolatedStore(nextDelta: 500_000_000)
        await store.refresh()
        store.calibratePlanUsage(to: 7_100_000_000, at: now)
        XCTAssertEqual(store.planUsage(at: now), 7_100_000_000)
        store.calibratePlanUsage(to: 7_000_000_000, at: now)
        XCTAssertEqual(store.planUsage(at: now), 7_000_000_000)
        XCTAssertEqual(store.dailyRecords.first?.cellularTotalBytes, 600_000_000)
    }

    func testNegativeCalibrationPersistsWithBaselineAcrossAppRestart() {
        let (store, persistence, now) = isolatedStore(raw: 8_000_000_000)
        store.calibratePlanUsage(to: 7_000_000_000, at: now)
        XCTAssertEqual(store.plan.usageCorrectionBytes, -1_000_000_000)
        let restarted = AppStore(persistence: persistence, notificationsEnabled: false)
        XCTAssertEqual(restarted.planUsage(at: now), 7_000_000_000)
        XCTAssertEqual(restarted.liveSnapshot, store.liveSnapshot)
        XCTAssertEqual(restarted.dailyRecords, store.dailyRecords)
    }

    func testRemainingForecastExceededAndAlertsUseCalibration() throws {
        let (store, _, now) = isolatedStore()
        store.plan.capacityBytes = 8_000_000_000
        store.plan.alertThresholds = [AlertThreshold(kind: .percentUsed, value: 80),
            AlertThreshold(kind: .percentUsed, value: 90), AlertThreshold(kind: .percentUsed, value: 95),
            AlertThreshold(kind: .remainingBytes, value: 1_000_000_000)]
        store.calibratePlanUsage(to: 7_100_000_000, at: now)
        XCTAssertEqual(store.plan.remainingBytes(records: store.dailyRecords, at: now), 900_000_000)
        XCTAssertEqual(try XCTUnwrap(store.plan.forecast(records: store.dailyRecords, at: now)).usedBytes, 7_100_000_000)
        XCTAssertFalse(store.isPlanExceeded(at: now))
        XCTAssertEqual(store.alerts.count, 2)
        store.checkAlerts()
        XCTAssertEqual(store.alerts.count, 2)
        store.calibratePlanUsage(to: 9_000_000_000, at: now)
        XCTAssertTrue(store.isPlanExceeded(at: now))
        XCTAssertEqual(store.plan.remainingBytes(records: store.dailyRecords, at: now), 0)
    }

    func testNewCycleClearsCalibrationAndManualAmount() {
        let (store, _, now) = isolatedStore()
        store.calibratePlanUsage(to: 7_100_000_000, at: now)
        let nextCycle = store.plan.activeCycleEnd
        XCTAssertTrue(store.normalizePlanCycle(now: nextCycle))
        XCTAssertNil(store.plan.usageCorrectionBytes)
        XCTAssertNil(store.plan.lastCalibrationDate)
        XCTAssertNil(store.plan.calibrationMeasuredBytes)
        XCTAssertEqual(store.planUsage(at: nextCycle), 0)
    }

    func testClearCalibrationAndResetAll() {
        let (store, _, now) = isolatedStore()
        store.calibratePlanUsage(to: 7_100_000_000, at: now)
        store.clearUsageCalibration()
        XCTAssertEqual(store.planUsage(at: now), 100_000_000)
        store.calibratePlanUsage(to: 7_100_000_000, at: now)
        store.resetAll()
        XCTAssertEqual(store.planUsage(at: now), 0)
        XCTAssertNil(store.plan.lastCalibrationDate)
        XCTAssertNil(store.plan.calibrationMeasuredBytes)
        XCTAssertTrue(store.dailyRecords.isEmpty)
    }

    func testCycleBoundaryIsHalfOpenAndRolloverUsesCorrectedRemainder() {
        let (store, _, now) = isolatedStore()
        store.plan.capacityBytes = 8_000_000_000
        store.plan.rolloverEnabled = true
        store.calibratePlanUsage(to: 7_100_000_000, at: now)
        let boundary = store.plan.activeCycleEnd
        store.merge(delta: NetworkDelta(wifiReceived: 0, wifiSent: 0, cellularReceived: 200_000_000,
                                        cellularSent: 0, isValid: true), from: boundary, to: boundary)
        XCTAssertEqual(store.planUsage(at: now), 7_100_000_000)
        _ = store.normalizePlanCycle(now: boundary)
        XCTAssertEqual(store.plan.carriedBytes, 900_000_000)
        XCTAssertEqual(store.planUsage(at: boundary), 200_000_000)
    }

    func testClockRollbackStillStoresRawUsageOnCurrentDay() {
        let (store, _, now) = isolatedStore()
        store.dailyRecords = []
        store.merge(delta: NetworkDelta(wifiReceived: 0, wifiSent: 0, cellularReceived: 500,
                                        cellularSent: 0, isValid: true), from: now, to: now.addingTimeInterval(-10))
        XCTAssertEqual(store.dailyRecords.first?.cellularTotalBytes, 500)
    }

    func testFailedReadRejectsCalibrationInsteadOfDoubleCountingLater() {
        let persistence = PersistenceService(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("netflow-data.json"))
        let failure = NetworkSnapshot(wifi: .zero, cellular: .zero, timestamp: Date(), readSucceeded: false)
        let store = AppStore(persistence: persistence, tracker: UsageTracker(reader: Reader([failure])), notificationsEnabled: false)
        store.liveSnapshot = .zero
        XCTAssertFalse(store.calibratePlanUsage(to: 7_100_000_000))
        XCTAssertNil(store.plan.lastCalibrationTargetBytes)
    }

    func testNarrowFallbackPreservesPersistedBaselineAndRecoversUsageAfterRestart() async {
        let persistence = PersistenceService(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("netflow-data.json"))
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        func snapshot(_ bytes: UInt64, at timestamp: Date, bits: Int) -> NetworkSnapshot {
            let counter = NetworkCounter(received: bytes, sent: 0)
            return NetworkSnapshot(wifi: .zero, cellular: counter, timestamp: timestamp,
                                   wifiInterfaces: [:], cellularInterfaces: ["pdp_ip0": counter],
                                   counterBits: bits, bootTime: 1)
        }
        let wide = snapshot(4_000_000_000, at: now.addingTimeInterval(-120), bits: 64)
        XCTAssertTrue(persistence.save(settings: AppSettings(), plan: DataPlan(), records: [],
                                       alerts: [], networkSnapshot: wide))
        let fallback = snapshot(205_032_704, at: now.addingTimeInterval(-60), bits: 32)
        let store = AppStore(persistence: persistence, tracker: UsageTracker(reader: Reader([fallback])),
                             notificationsEnabled: false)
        await store.refresh()
        store.save()
        XCTAssertEqual(persistence.load().networkSnapshot, wide)
        XCTAssertTrue(store.dailyRecords.isEmpty)

        let recovered = snapshot(11_100_000_000, at: now, bits: 64)
        let restarted = AppStore(persistence: persistence, tracker: UsageTracker(reader: Reader([recovered, recovered])),
                                 notificationsEnabled: false)
        await restarted.refresh()
        restarted.save()
        XCTAssertEqual(persistence.load().records.reduce(UInt64(0)) { $0 + $1.cellularTotalBytes }, 7_100_000_000)
        await restarted.refresh()
        XCTAssertEqual(restarted.dailyRecords.reduce(UInt64(0)) { $0 + $1.cellularTotalBytes }, 7_100_000_000)
    }

}
