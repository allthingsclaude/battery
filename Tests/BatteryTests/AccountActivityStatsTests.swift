import XCTest
@testable import Battery

final class AccountActivityStatsTests: XCTestCase {

    private let calendar = Calendar.current

    private func today() -> Date {
        calendar.startOfDay(for: Date())
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today())!
    }

    // MARK: - Streak

    func testStreakCountsConsecutiveDaysBackFromToday() {
        let stats = AccountActivityStats.build(
            dayPeaks: [day(0): 40, day(-1): 12, day(-2): 88, day(-4): 50],
            today: today(),
            calendar: calendar
        )
        XCTAssertEqual(stats.currentStreak, 3)
    }

    /// A day whose window opened but never registered measurable usage still
    /// counts — activity is presence, not a non-zero peak. Battery only records
    /// a snapshot while a five-hour window is open, and the real database has
    /// such days (a 0% peak with 184 snapshots).
    func testZeroPeakDayStillCountsAsActive() {
        let stats = AccountActivityStats.build(
            dayPeaks: [day(0): 0, day(-1): 0, day(-2): 30],
            today: today(),
            calendar: calendar
        )
        XCTAssertEqual(stats.currentStreak, 3)
        XCTAssertEqual(stats.activeDays[day(-1)], 0)
    }

    /// An untouched morning must not read as a broken streak.
    func testStreakRunsFromYesterdayWhenTodayHasNoActivity() {
        let stats = AccountActivityStats.build(
            dayPeaks: [day(-1): 20, day(-2): 20, day(-3): 20],
            today: today(),
            calendar: calendar
        )
        XCTAssertEqual(stats.currentStreak, 3)
    }

    /// A streak is not bounded by the heat map. `refreshAccountStats` used to
    /// hand this only the heat-map window, which capped every streak at
    /// `heatMapDays + 1` — an account used daily for months read 36 and could
    /// only ever move down from there.
    func testStreakIsNotCappedByTheHeatMapWindow() {
        var dayPeaks: [Date: Double] = [:]
        for offset in 0...59 {
            dayPeaks[day(-offset)] = 42
        }

        let stats = AccountActivityStats.build(
            dayPeaks: dayPeaks,
            today: today(),
            calendar: calendar,
            heatMapDays: Constants.heatMapDays
        )

        XCTAssertEqual(stats.currentStreak, 60)
        // The heat map still draws its own five weeks, one row per week.
        XCTAssertEqual(stats.activeDays.count, Constants.heatMapDays + 1)
    }

    func testStreakIsZeroWhenNeitherTodayNorYesterdayIsActive() {
        let stats = AccountActivityStats.build(
            dayPeaks: [day(-2): 90, day(-3): 90],
            today: today(),
            calendar: calendar
        )
        XCTAssertEqual(stats.currentStreak, 0)
    }

    func testNoHistoryYieldsEmptyStats() {
        let stats = AccountActivityStats.build(dayPeaks: [:], today: today(), calendar: calendar)
        XCTAssertEqual(stats.currentStreak, 0)
        XCTAssertTrue(stats.activeDays.isEmpty)
        // The chart keeps its shape so a new account renders flat, not broken.
        XCTAssertEqual(stats.dailyPeaks.count, 8)
        XCTAssertTrue(stats.dailyPeaks.allSatisfy { $0.peak == 0 })
    }

    // MARK: - Heat map

    func testHeatMapDropsDaysOutsideTheWindow() {
        let stats = AccountActivityStats.build(
            dayPeaks: [day(0): 10, day(-34): 20, day(-40): 30],
            today: today(),
            calendar: calendar,
            heatMapDays: 35
        )
        XCTAssertNotNil(stats.activeDays[day(-34)])
        XCTAssertNil(stats.activeDays[day(-40)])
    }

    /// Only days with a record appear, so the map can tell "no activity" apart
    /// from "0% peak".
    func testHeatMapOmitsDaysWithoutRecords() {
        let stats = AccountActivityStats.build(
            dayPeaks: [day(0): 10, day(-2): 20],
            today: today(),
            calendar: calendar
        )
        XCTAssertEqual(stats.activeDays.count, 2)
        XCTAssertNil(stats.activeDays[day(-1)])
    }

    // MARK: - Sparkline

    func testSparklineCoversEightDaysEndingToday() {
        let stats = AccountActivityStats.build(
            dayPeaks: [day(0): 18, day(-3): 61],
            today: today(),
            calendar: calendar
        )
        XCTAssertEqual(stats.dailyPeaks.count, 8)
        XCTAssertEqual(stats.dailyPeaks.first?.date, day(-7))
        XCTAssertEqual(stats.dailyPeaks.last?.date, day(0))
        XCTAssertEqual(stats.dailyPeaks.last?.peak, 18)
        XCTAssertEqual(stats.dailyPeaks.first(where: { $0.date == day(-3) })?.peak, 61)
        // Gaps read as zero rather than vanishing, which would compress the chart.
        XCTAssertEqual(stats.dailyPeaks.first(where: { $0.date == day(-4) })?.peak, 0)
    }
}
