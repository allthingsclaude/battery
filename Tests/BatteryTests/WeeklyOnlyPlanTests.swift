import XCTest
@testable import Battery

/// Verified Ultra accounts have no five-hour window: the usage API answers with
/// `"five_hour": null`, and the weekly window is the only one that can stop
/// work. These cover how that reaches parsing, projection and history.
final class WeeklyOnlyPlanTests: XCTestCase {

    private let calendar = Calendar.current

    // MARK: - Decoding

    func testNullFiveHourMeansNoSessionLimit() throws {
        let json = """
        {
            "five_hour": null,
            "seven_day": { "utilization": 37.0, "resets_at": "2026-11-07T02:00:00.399937+00:00" },
            "limits": [
                { "kind": "weekly_all", "group": "weekly", "percent": 37,
                  "resets_at": "2026-11-07T02:00:00.399937+00:00", "scope": null },
                { "kind": "weekly_scoped", "group": "weekly", "percent": 12,
                  "resets_at": "2026-11-07T02:00:00.399937+00:00",
                  "scope": { "model": { "id": null, "display_name": "Fable" } } }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertNil(response.sessionBucket)
        XCTAssertFalse(response.hasSessionLimit)
        XCTAssertEqual(response.sevenDay.utilization, 37)
        XCTAssertEqual(response.fableUtilization, 12)
    }

    func testMissingFiveHourKeyMeansNoSessionLimit() throws {
        let json = """
        { "seven_day": { "utilization": 5.0, "resets_at": "2026-11-07T02:00:00Z" } }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertFalse(response.hasSessionLimit)
    }

    /// A `session` entry in `limits` is a session window even if the top-level
    /// field is missing — don't hide a limit the account does have.
    func testSessionEntryInLimitsStillCountsAsASessionWindow() throws {
        let json = """
        {
            "five_hour": null,
            "seven_day": { "utilization": 5.0, "resets_at": "2026-11-07T02:00:00Z" },
            "limits": [
                { "kind": "session", "group": "session", "percent": 18,
                  "resets_at": "2026-11-03T18:50:00Z", "scope": null }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertTrue(response.hasSessionLimit)
        XCTAssertEqual(response.sessionBucket?.utilization, 18)
        XCTAssertNotNil(response.sessionBucket?.resetsAtDate)
    }

    func testPresentFiveHourIsASessionWindow() throws {
        let json = """
        {
            "five_hour": { "utilization": 0.0, "resets_at": null },
            "seven_day": { "utilization": 5.0, "resets_at": "2026-11-07T02:00:00Z" }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        XCTAssertTrue(response.hasSessionLimit, "An idle session window is still a session limit")
    }

    // MARK: - Burn rate

    private func weeklyOnlySnapshot(minutesAgo: Double, weekly: Double, weeklyResetsAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            timestamp: Date().addingTimeInterval(-minutesAgo * 60),
            sessionUtilization: 0,
            sessionResetsAt: Date(timeIntervalSince1970: 0),
            weeklyUtilization: weekly,
            weeklyResetsAt: weeklyResetsAt,
            hasSessionLimit: false
        )
    }

    func testWeeklyWindowRegressesOverWeeklyUtilization() {
        let resetsAt = Date().addingTimeInterval(3 * 86400)
        // +1 point per hour over the last three hours.
        let snapshots = [
            weeklyOnlySnapshot(minutesAgo: 180, weekly: 40, weeklyResetsAt: resetsAt),
            weeklyOnlySnapshot(minutesAgo: 120, weekly: 41, weeklyResetsAt: resetsAt),
            weeklyOnlySnapshot(minutesAgo: 60, weekly: 42, weeklyResetsAt: resetsAt),
            weeklyOnlySnapshot(minutesAgo: 0, weekly: 43, weeklyResetsAt: resetsAt),
        ]

        let projection = BurnRateCalculator.calculate(
            snapshots: snapshots,
            currentUtilization: 43,
            resetsAt: resetsAt,
            window: .weekly
        )

        XCTAssertTrue(projection.hasEnoughData)
        XCTAssertEqual(projection.currentRate, 1.0, accuracy: 0.01)
        // 57 points left at 1/hr lands before the reset 72h out.
        let hoursToLimit = projection.projectedLimitTime.map { $0.timeIntervalSinceNow / 3600 }
        XCTAssertEqual(hoursToLimit ?? 0, 57, accuracy: 0.1)
        XCTAssertEqual(projection.projectedAtReset, 100)
    }

    /// Weekly-only rows carry placeholder session columns. A session-window
    /// regression must not read them as a real (flat) session.
    func testSessionWindowIgnoresWeeklyOnlyRows() {
        let placeholder = Date(timeIntervalSince1970: 0)
        let snapshots = (0..<5).map {
            weeklyOnlySnapshot(minutesAgo: Double($0) * 10, weekly: 40, weeklyResetsAt: Date().addingTimeInterval(86400))
        }

        let projection = BurnRateCalculator.calculate(
            snapshots: snapshots,
            currentUtilization: 0,
            resetsAt: placeholder,
            window: .session
        )

        XCTAssertFalse(projection.hasEnoughData)
    }

    // MARK: - History

    private func makeService() async throws -> (DatabaseService, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("battery-weekly-\(UUID().uuidString)", isDirectory: true)
        let service = DatabaseService()
        try await service.initialize(directory: dir)
        return (service, dir)
    }

    private func weeklyRow(at timestamp: Date, weekly: Double, resetsAt: Date, account: UUID) -> UsageSnapshot {
        UsageSnapshot(
            timestamp: timestamp,
            sessionUtilization: 0,
            sessionResetsAt: Date(timeIntervalSince1970: 0),
            weeklyUtilization: weekly,
            weeklyResetsAt: resetsAt,
            planTier: "ultra",
            accountId: account,
            hasSessionLimit: false
        )
    }

    func testFlagRoundTripsThroughTheDatabase() async throws {
        let (service, dir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = UUID()
        try await service.saveSnapshot(weeklyRow(at: Date(), weekly: 12, resetsAt: Date().addingTimeInterval(86400), account: account))

        let rows = try await service.getLatestSnapshots(count: 1, accountId: account)
        XCTAssertEqual(rows.first?.hasSessionLimit, false)
    }

    /// Weekly-only rows are written on every poll, idle or not, so a day only
    /// counts when the weekly figure rose — and its value is the rise.
    func testWeeklyOnlyDayCountsTheRiseAndIdleDaysDropOut() async throws {
        let (service, dir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = UUID()
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let resetsAt = today.addingTimeInterval(3 * 86400)
        func at(_ day: Date, hour: Int) -> Date { calendar.date(byAdding: .hour, value: hour, to: day)! }

        // Yesterday: idle all day at 30%.
        try await service.saveSnapshot(weeklyRow(at: at(yesterday, hour: 9), weekly: 30, resetsAt: resetsAt, account: account))
        try await service.saveSnapshot(weeklyRow(at: at(yesterday, hour: 18), weekly: 30, resetsAt: resetsAt, account: account))
        // Today: 30% -> 41%.
        try await service.saveSnapshot(weeklyRow(at: at(today, hour: 1), weekly: 30, resetsAt: resetsAt, account: account))
        try await service.saveSnapshot(weeklyRow(at: at(today, hour: 2), weekly: 41, resetsAt: resetsAt, account: account))

        let peaks = try await service.dailyPeakUtilization(
            from: calendar.date(byAdding: .day, value: -3, to: today)!,
            to: at(today, hour: 3),
            accountId: account
        )

        XCTAssertNil(peaks[yesterday], "An idle day is not active")
        XCTAssertEqual(peaks[today], 11)
    }

    /// A weekly reset mid-day must not read as a negative (or huge) rise: each
    /// window's rise is measured on its own and the day sums them.
    func testWeeklyResetMidDaySumsBothWindows() async throws {
        let (service, dir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = UUID()
        let today = calendar.startOfDay(for: Date())
        func at(_ hour: Int) -> Date { calendar.date(byAdding: .hour, value: hour, to: today)! }
        let oldWindow = at(3)
        let newWindow = oldWindow.addingTimeInterval(7 * 86400)

        try await service.saveSnapshot(weeklyRow(at: at(1), weekly: 90, resetsAt: oldWindow, account: account))
        try await service.saveSnapshot(weeklyRow(at: at(2), weekly: 95, resetsAt: oldWindow, account: account))
        try await service.saveSnapshot(weeklyRow(at: at(4), weekly: 1, resetsAt: newWindow, account: account))
        try await service.saveSnapshot(weeklyRow(at: at(5), weekly: 4, resetsAt: newWindow, account: account))

        let peaks = try await service.dailyPeakUtilization(
            from: calendar.date(byAdding: .day, value: -1, to: today)!,
            to: at(6),
            accountId: account
        )

        XCTAssertEqual(peaks[today], 8, "5 points in the old window + 3 in the new")
    }

    /// Rows written before the column existed read back as session-window rows,
    /// which keeps their presence-means-active meaning.
    func testSessionRowsKeepPresenceSemantics() async throws {
        let (service, dir) = try await makeService()
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = UUID()
        let noon = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date()))!
        try await service.saveSnapshot(UsageSnapshot(
            timestamp: noon,
            sessionUtilization: 0,
            sessionResetsAt: noon.addingTimeInterval(3600),
            weeklyUtilization: 10,
            weeklyResetsAt: noon.addingTimeInterval(86400),
            accountId: account
        ))

        let peaks = try await service.dailyPeakUtilization(
            from: calendar.date(byAdding: .day, value: -1, to: noon)!,
            to: noon.addingTimeInterval(60),
            accountId: account
        )

        XCTAssertEqual(peaks[calendar.startOfDay(for: noon)], 0, "A session window with 0% is still an active day")
    }

    // MARK: - Formatting

    func testLongDurationRollsOverIntoDays() {
        XCTAssertEqual(TimeFormatting.longDuration(4 * 86400 + 2 * 3600 + 59 * 60), "4d 2h")
        XCTAssertEqual(TimeFormatting.longDuration(86400), "1d")
        XCTAssertEqual(TimeFormatting.longDuration(23 * 3600 + 59 * 60), "23h 59m")
        XCTAssertEqual(TimeFormatting.longDuration(45 * 60), "45m")
        XCTAssertEqual(TimeFormatting.longDuration(0), "0s")
    }
}
