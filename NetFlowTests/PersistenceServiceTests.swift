import XCTest
@testable import NetFlow

final class PersistenceServiceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func sampleRecord() -> DailyUsageRecord {
        DailyUsageRecord(
            date: date(2026, 1, 10),
            delta: NetworkDelta(
                wifiReceived: 10,
                wifiSent: 20,
                cellularReceived: 30,
                cellularSent: 40,
                isValid: true
            ),
            firstUpdated: date(2026, 1, 10),
            lastUpdated: date(2026, 1, 10)
        )
    }

    func testBackupRoundTripPreservesPayload() throws {
        var plan = DataPlan()
        plan.capacityBytes = 5_000
        plan.cycleType = .custom
        plan.customDays = 14
        let settings = AppSettings(appLanguage: .english, theme: .dark, refreshSeconds: 5)
        let record = sampleRecord()
        let alert = UsageAlertEvent(
            date: date(2026, 1, 10),
            threshold: AlertThreshold(kind: .percentUsed, value: 80),
            remainingBytes: 1_000
        )

        let service = PersistenceService()
        let url = try service.makeBackup(
            settings: settings,
            plan: plan,
            records: [record],
            alerts: [alert]
        )
        let restored = try service.loadBackup(from: url)

        XCTAssertEqual(restored.settings, settings)
        XCTAssertEqual(restored.plan, plan)
        XCTAssertEqual(restored.records, [record])
        XCTAssertEqual(restored.alerts, [alert])
    }

    func testCSVContainsStableByteColumnsAndSortedRecords() throws {
        let first = sampleRecord()
        var second = sampleRecord()
        second.date = date(2026, 1, 11)
        let interval = DateInterval(start: date(2026, 1, 10), end: date(2026, 1, 12))

        let url = try PersistenceService().makeCSV(records: [second, first], interval: interval)
        let csv = try String(contentsOf: url, encoding: .utf8)
        let lines = csv.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(
            lines[0],
            "date,wifi_received_bytes,wifi_sent_bytes,wifi_total_bytes,cellular_received_bytes,cellular_sent_bytes,cellular_total_bytes,total_bytes,estimated"
        )
        XCTAssertTrue(lines[1].hasPrefix("2026-01-10,10,20,30,30,40,70,100,false"))
        XCTAssertTrue(lines[2].hasPrefix("2026-01-11,10,20,30,30,40,70,100,false"))
    }
    func testLegacyJSONWithoutNewFieldsStillDecodes() throws {
        let payload = PersistencePayload(settings: AppSettings(), plan: DataPlan(), records: [sampleRecord()], alerts: [],
            networkSnapshot: NetworkSnapshot(wifi: .zero, cellular: .zero, timestamp: Date()))
        let data = try JSONEncoder.pretty.encode(payload)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var plan = try XCTUnwrap(json["plan"] as? [String: Any])
        for key in ["usageCorrectionBytes", "lastCalibrationDate", "lastCalibrationTargetBytes", "calibrationMeasuredBytes"] {
            plan.removeValue(forKey: key)
        }
        json["plan"] = plan
        var records = try XCTUnwrap(json["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "isEstimated")
        json["records"] = records
        let decoded = try JSONDecoder.netFlow.decode(PersistencePayload.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.records[0].cellularTotalBytes, 70)
        XCTAssertFalse(decoded.records[0].isEstimated)
        XCTAssertNil(decoded.plan.usageCorrectionBytes)
    }

    func testBackupPreservesCalibrationButDoesNotReplayDeviceBaseline() throws {
        var plan = DataPlan()
        plan.usageCorrectionBytes = -1_000_000_000
        plan.lastCalibrationTargetBytes = 7_000_000_000
        plan.calibrationMeasuredBytes = 8_000_000_000
        plan.lastCalibrationDate = date(2026, 1, 10)
        let service = PersistenceService()
        let url = try service.makeBackup(settings: AppSettings(), plan: plan, records: [sampleRecord()], alerts: [])
        let payload = try service.loadBackup(from: url)
        XCTAssertEqual(payload.plan, plan)
        XCTAssertNil(payload.networkSnapshot)
    }

}
