import XCTest
@testable import NetFlow

final class LedgerSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func snapshot(at now: Date) -> LedgerSnapshot {
        LedgerSnapshot.make(records: [], at: now, sampledAt: now,
                            planUsed: 100, planCapacity: 200,
                            continuousRequested: true, continuousRunning: true,
                            counterBits: 64, warning: nil, calendar: calendar)
    }

    func testSharedSnapshotRoundTripPreservesLargeByteCounts() throws {
        var value = snapshot(at: date(10, 21))
        value.todayCellular = 44_800_000_000
        value.monthCellular = 103_000_000_000
        value.planUsed = 102_870_000_000
        let decoded = try JSONDecoder().decode(LedgerSnapshot.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value, decoded)
    }

    func testOldDayAndMonthAreNotDisplayedAsCurrentUse() {
        let value = snapshot(at: date(10, 31))
        XCTAssertNotNil(value.todayCellular(at: date(10, 31), calendar: calendar))
        XCTAssertNil(value.todayCellular(at: date(11, 1), calendar: calendar))
        XCTAssertNil(value.monthCellular(at: date(11, 1), calendar: calendar))
        XCTAssertNotNil(value.monthCellular(at: date(10, 31, 23), calendar: calendar))
    }

    func testStaleAndFutureDatedSamplesAreExplicit() {
        let now = date(10, 21)
        var value = snapshot(at: now)
        XCTAssertFalse(value.isStale(at: now))
        XCTAssertTrue(value.isStale(at: now.addingTimeInterval(121)))
        value.sampledAt = now.addingTimeInterval(20)
        XCTAssertTrue(value.isStale(at: now))
    }

    func testBackgroundAudioBufferIsValidSilentPCMNotMicrophoneAudio() {
        let data = ContinuousMonitoringService.silenceWAV()
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 44 + 16_000)
        XCTAssertTrue(data.dropFirst(44).allSatisfy { $0 == 0 })
    }
}
