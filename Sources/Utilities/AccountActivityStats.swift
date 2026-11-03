import Foundation

/// Streak, heat map and sparkline derived from one account's recorded daily
/// peaks.
///
/// A day counts as active for an account when it appears in `dayPeaks`.
/// `DatabaseService.dailyPeakUtilization` decides that: for an account with a
/// five-hour window, any snapshot that day (they are only written while a
/// window is open), so the peak itself may legitimately be 0 — a window opened
/// but never registered measurable usage — which is why activity keys on
/// presence rather than on a non-zero value. For a weekly-only account, only a
/// day whose weekly utilization rose.
struct AccountActivityStats {
    var currentStreak: Int = 0
    /// Day → peak session utilization, for the heat map window. Only days with
    /// a record appear, so the map can tell "no activity" from "0% peak".
    var activeDays: [Date: Double] = [:]
    /// Points ending today. Days without a record contribute 0 so the chart
    /// keeps a fixed shape rather than compressing around the gaps.
    var dailyPeaks: [(date: Date, peak: Double)] = []

    /// - Parameters:
    ///   - dayPeaks: start-of-day → peak session utilization for that day.
    ///   - today: start of the current day, in the same calendar as `dayPeaks`.
    ///   - heatMapDays: how far back the heat map window reaches.
    ///   - sparklineDays: how many days precede today in the sparkline.
    static func build(
        dayPeaks: [Date: Double],
        today: Date,
        calendar: Calendar = .current,
        heatMapDays: Int = 35,
        sparklineDays: Int = 7
    ) -> AccountActivityStats {
        var stats = AccountActivityStats()

        // Streak runs back from today, or from yesterday when today has not
        // been used yet — an untouched morning must not read as a broken streak.
        let activeDates = Set(dayPeaks.keys)
        if activeDates.contains(today) {
            stats.currentStreak = countConsecutiveDays(from: today, activeDates: activeDates, calendar: calendar)
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  activeDates.contains(yesterday) {
            stats.currentStreak = countConsecutiveDays(from: yesterday, activeDates: activeDates, calendar: calendar)
        }

        if let cutoff = calendar.date(byAdding: .day, value: -heatMapDays, to: today) {
            stats.activeDays = dayPeaks.filter { $0.key >= cutoff && $0.key <= today }
        }

        for offset in (-sparklineDays)...0 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            stats.dailyPeaks.append((date: date, peak: dayPeaks[date] ?? 0))
        }

        return stats
    }

    private static func countConsecutiveDays(
        from startDay: Date,
        activeDates: Set<Date>,
        calendar: Calendar
    ) -> Int {
        var streak = 0
        var currentDay = startDay
        while activeDates.contains(currentDay) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: currentDay) else { break }
            currentDay = previous
        }
        return streak
    }
}
