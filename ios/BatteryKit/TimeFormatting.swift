import Foundation

/// Duration / relative-time helpers. Ported verbatim from the macOS app so the
/// iOS surfaces format time exactly the same way ("2h 13m", "45m", "just now").
enum TimeFormatting {

    /// Format a time interval as a short duration string.
    /// Examples: "2h 13m", "45m", "30s", "< 1m"
    static func shortDuration(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "0s" }

        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else if seconds > 0 {
            return "\(seconds)s"
        } else {
            return "< 1m"
        }
    }

    /// Like `shortDuration`, but rolls hours over into days once the span
    /// reaches a day — for the weekly window, which would otherwise read
    /// "98h 12m". Ported from the macOS app alongside `shortDuration`, so the
    /// two read identically for an account with no 5-hour limit, where every
    /// countdown is a weekly one.
    /// Examples: "4d 2h", "1d", "23h 59m", "45m"
    static func longDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        guard totalSeconds >= 86400 else { return shortDuration(interval) }

        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }

    /// Format a date as a relative time string. Examples: "just now", "2m ago".
    static func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h ago"
        } else {
            return "\(Int(interval / 86400))d ago"
        }
    }
}
