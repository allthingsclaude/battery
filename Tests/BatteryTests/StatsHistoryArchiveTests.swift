import XCTest
@testable import Battery

/// Battery's archive is the only durable record of local daily activity, and
/// these cover the rule that makes it one: a rescan may add to the record and
/// may never take from it.
///
/// Neither source underneath keeps history. Claude Code's `stats-cache.json` is
/// a rolling 30-day window, and the session transcripts the gaps are rebuilt
/// from are deleted after `cleanupPeriodDays` (30 by default). Rebuilding the
/// archive from a scan of what survives — which is what it used to do, once a
/// day — dropped every day whose transcript had just been cleaned up, opening a
/// hole roughly a month back that snapped the streak down to it.
final class StatsHistoryArchiveTests: XCTestCase {

    private func day(
        _ date: String,
        messages: Int = 10,
        sessions: Int = 1,
        tools: Int = 5
    ) -> StatsCache.DailyActivity {
        StatsCache.DailyActivity(
            date: date,
            messageCount: messages,
            sessionCount: sessions,
            toolCallCount: tools
        )
    }

    private func dates(_ activities: [StatsCache.DailyActivity]) -> [String] {
        activities.map(\.date)
    }

    // MARK: - Never unlearn a day

    /// The regression, at its smallest: two days age out of the transcript
    /// directory between one reconcile and the next.
    func testRescanThatLostTranscriptsKeepsArchivedDays() {
        let archived = ["2026-07-14", "2026-07-15", "2026-07-16", "2026-07-17"].map { day($0) }
        let rescanned = ["2026-07-16", "2026-07-17"].map { day($0) }

        let merged = StatsCacheService.mergeDailyActivity(archived, rescanned, earliestKept: "2026-01-01")

        XCTAssertEqual(dates(merged), ["2026-07-14", "2026-07-15", "2026-07-16", "2026-07-17"])
    }

    /// A scan that proves nothing at all — an empty `projects/` directory, a
    /// permissions failure — must leave the record alone rather than clear it.
    func testEmptyRescanLeavesTheArchiveIntact() {
        let archived = ["2026-07-14", "2026-07-15"].map { day($0) }

        let merged = StatsCacheService.mergeDailyActivity(archived, [], earliestKept: "2026-01-01")

        XCTAssertEqual(dates(merged), ["2026-07-14", "2026-07-15"])
    }

    /// The other half of the contract: days the archive has not seen are taken up.
    func testNewlyProvableDaysAreAdded() {
        let archived = [day("2026-07-14")]
        let scanned = [day("2026-07-15"), day("2026-07-16")]

        let merged = StatsCacheService.mergeDailyActivity(archived, scanned, earliestKept: "2026-01-01")

        XCTAssertEqual(dates(merged), ["2026-07-14", "2026-07-15", "2026-07-16"])
    }

    /// A run of days stays unbroken across a rescan that can only still see the
    /// recent end of it — which is what keeps the streak whole.
    func testAnUnbrokenRunSurvivesTranscriptCleanup() {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let start = calendar.startOfDay(for: Date())

        let allDays = (1...40).reversed().map { offset -> StatsCache.DailyActivity in
            day(formatter.string(from: calendar.date(byAdding: .day, value: -offset, to: start)!))
        }
        // Only the ten most recent still have a transcript on disk.
        let stillProvable = Array(allDays.suffix(10))

        let merged = StatsCacheService.mergeDailyActivity(allDays, stillProvable, earliestKept: "2000-01-01")

        XCTAssertEqual(merged.count, 40)
        XCTAssertEqual(dates(merged), dates(allDays), "the run must stay contiguous, with no hole to break a streak on")
    }

    // MARK: - Conflicts

    /// A session resumed the next morning adds messages to the day before, so a
    /// later reading of the same day can legitimately be higher.
    func testConflictTakesTheHigherCounts() {
        let archived = [day("2026-07-14", messages: 10, sessions: 1, tools: 5)]
        let scanned = [day("2026-07-14", messages: 25, sessions: 3, tools: 40)]

        let merged = StatsCacheService.mergeDailyActivity(archived, scanned, earliestKept: "2026-01-01")

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].messageCount, 25)
        XCTAssertEqual(merged[0].sessionCount, 3)
        XCTAssertEqual(merged[0].toolCallCount, 40)
    }

    /// A rescan reading a half-deleted transcript can only undercount, and the
    /// record must not follow it down — a day dimming in the heat map for no
    /// reason is the same defect as one disappearing from it.
    func testConflictIgnoresALowerRecount() {
        let archived = [day("2026-07-14", messages: 120, sessions: 6, tools: 300)]
        let scanned = [day("2026-07-14", messages: 4, sessions: 1, tools: 2)]

        let merged = StatsCacheService.mergeDailyActivity(archived, scanned, earliestKept: "2026-01-01")

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].messageCount, 120)
        XCTAssertEqual(merged[0].sessionCount, 6)
        XCTAssertEqual(merged[0].toolCallCount, 300)
    }

    // MARK: - Retention window

    func testDaysOlderThanTheRetentionWindowAreDropped() {
        let archived = ["2025-01-01", "2026-07-14", "2026-07-15"].map { day($0) }

        let merged = StatsCacheService.mergeDailyActivity(archived, [], earliestKept: "2026-07-01")

        XCTAssertEqual(dates(merged), ["2026-07-14", "2026-07-15"])
    }

    /// The window bound is only computable from a parseable date; failing to
    /// derive one keeps every day rather than emptying the record.
    func testAnUnresolvableWindowKeepsEverything() {
        let archived = ["2019-03-02", "2026-07-14"].map { day($0) }

        let merged = StatsCacheService.mergeDailyActivity(archived, [], earliestKept: "")

        XCTAssertEqual(dates(merged), ["2019-03-02", "2026-07-14"])
    }

    // MARK: - Shape

    func testResultIsSortedByDate() {
        let archived = ["2026-07-17", "2026-07-14"].map { day($0) }
        let scanned = ["2026-07-16", "2026-07-15"].map { day($0) }

        let merged = StatsCacheService.mergeDailyActivity(archived, scanned, earliestKept: "2026-01-01")

        XCTAssertEqual(dates(merged), ["2026-07-14", "2026-07-15", "2026-07-16", "2026-07-17"])
    }

    /// Merging a record into itself has to be a no-op, or every reload would
    /// rewrite the file and retrigger the watchers observing it.
    func testMergingAnArchiveWithItselfChangesNothing() {
        let archived = ["2026-07-14", "2026-07-15"].map { day($0) }

        let merged = StatsCacheService.mergeDailyActivity(archived, archived, earliestKept: "2026-01-01")

        XCTAssertEqual(merged, archived)
    }
}
