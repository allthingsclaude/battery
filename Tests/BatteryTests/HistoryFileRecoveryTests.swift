import XCTest
@testable import Battery

/// `history.jsonl` is the only record in a Claude Code directory that outlives
/// `cleanupPeriodDays`, which makes it the last thing able to place a day whose
/// transcript has been deleted. Its shape belongs to another program and is
/// undocumented, so it is pinned here rather than trusted.
final class HistoryFileRecoveryTests: XCTestCase {

    private let zone = "Europe/Belgrade"

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    /// Milliseconds since the epoch for a wall-clock moment in a named zone,
    /// which is what Claude Code writes.
    private func millis(_ moment: String, in identifier: String) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: identifier)!
        return Int(formatter.date(from: moment)!.timeIntervalSince1970 * 1000)
    }

    private func line(_ moment: String, session: String, display: String = "hello") -> String {
        """
        {"display":"\(display)","pastedContents":{},"timestamp":\(millis(moment, in: zone)),\
        "project":"/tmp/p","sessionId":"\(session)"}
        """
    }

    private func activity(_ lines: [String], zone: String? = nil) -> [StatsCache.DailyActivity] {
        StatsCacheService.dailyActivityFromHistory(
            Data(lines.joined(separator: "\n").utf8),
            calendar: calendar(zone ?? self.zone)
        )
    }

    // MARK: - Shape

    func testGroupsPromptsByLocalDay() {
        let days = activity([
            line("2026-07-10 09:00", session: "a"),
            line("2026-07-10 17:30", session: "a"),
            line("2026-07-11 11:00", session: "b"),
        ])

        XCTAssertEqual(days.map(\.date), ["2026-07-10", "2026-07-11"])
        XCTAssertEqual(days[0].messageCount, 2)
        XCTAssertEqual(days[1].messageCount, 1)
    }

    /// Distinct session ids are the one figure here that means the same thing it
    /// means in every other source.
    func testSessionCountIsDistinctSessionsThatDay() {
        let days = activity([
            line("2026-07-10 09:00", session: "a"),
            line("2026-07-10 10:00", session: "a"),
            line("2026-07-10 14:00", session: "b"),
            line("2026-07-10 21:00", session: "c"),
        ])

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].sessionCount, 3)
        XCTAssertEqual(days[0].messageCount, 4)
    }

    /// Nothing here says how many tools ran, and guessing would put a number in
    /// the heat map that no source stands behind.
    func testToolCallCountIsZero() {
        XCTAssertEqual(activity([line("2026-07-10 09:00", session: "a")])[0].toolCallCount, 0)
    }

    // MARK: - Days, not instants

    /// A prompt just after local midnight belongs to the day the user was awake
    /// for, not to the UTC day.
    func testDayBoundaryFollowsTheGivenCalendarsZone() {
        // 00:30 in Belgrade is 22:30 UTC the day before.
        let lines = [line("2026-07-11 00:30", session: "a")]

        XCTAssertEqual(activity(lines).map(\.date), ["2026-07-11"])
        XCTAssertEqual(activity(lines, zone: "UTC").map(\.date), ["2026-07-10"])
    }

    // MARK: - Hostile input

    /// The reason lines are decoded rather than scanned for `"timestamp":`.
    /// Pasting JSON into a prompt is ordinary, and a substring match would read
    /// the quoted figure as a day of its own.
    func testATimestampQuotedInsideAPromptIsNotReadAsADay() {
        let days = activity([
            line("2026-07-10 09:00", session: "a", display: #"look at {\"timestamp\":1590000000000}"#),
        ])

        XCTAssertEqual(days.map(\.date), ["2026-07-10"])
    }

    func testMalformedAndEmptyLinesAreSkipped() {
        let days = activity([
            line("2026-07-10 09:00", session: "a"),
            "",
            "{ not json",
            #"{"display":"no timestamp","sessionId":"z"}"#,
            line("2026-07-11 09:00", session: "b"),
        ])

        XCTAssertEqual(days.map(\.date), ["2026-07-10", "2026-07-11"])
    }

    /// A prompt sent outside any session still proves the day was used.
    func testEntryWithoutASessionIdStillCountsTheDay() {
        let days = activity([#"{"display":"x","timestamp":\#(millis("2026-07-10 09:00", in: zone))}"#])

        XCTAssertEqual(days.map(\.date), ["2026-07-10"])
        XCTAssertEqual(days[0].messageCount, 1)
        XCTAssertEqual(days[0].sessionCount, 0)
    }

    func testEmptyFileYieldsNothing() {
        XCTAssertTrue(activity([]).isEmpty)
    }

    // MARK: - Feeding the archive

    /// What the recovery is for: prompt history proves a day, and a later source
    /// that can still see it raises the counts rather than being held back by
    /// the prompt-scale floor.
    func testRecoveredDayIsAFloorABetterSourceCanRaise() {
        let recovered = activity([
            line("2026-07-10 09:00", session: "a"),
            line("2026-07-10 10:00", session: "a"),
        ])
        let richer = [StatsCache.DailyActivity(
            date: "2026-07-10", messageCount: 240, sessionCount: 2, toolCallCount: 88
        )]

        let merged = StatsCacheService.mergeDailyActivity(recovered, richer, earliestKept: "2026-01-01")

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].messageCount, 240)
        XCTAssertEqual(merged[0].sessionCount, 2)
        XCTAssertEqual(merged[0].toolCallCount, 88)
    }
}
