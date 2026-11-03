import Foundation

/// Helpers for formatting durations and relative times.
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
    /// "98h 12m".
    /// Examples: "4d 2h", "1d", "23h 59m", "45m"
    static func longDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        guard totalSeconds >= 86400 else { return shortDuration(interval) }

        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
    }

    /// Format a date as a relative time string.
    /// Examples: "just now", "2m ago", "1h ago"
    static func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}
