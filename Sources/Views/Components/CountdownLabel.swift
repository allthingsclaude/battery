import SwiftUI

/// Displays a live countdown to a target date, updating every second.
/// Supports showing time remaining until reset or time elapsed since last reset.
struct CountdownLabel: View {
    let targetDate: Date
    var style: CountdownStyle = .full
    var mode: CountdownMode = .remaining
    /// Length of the window being counted down. Pass it when known; otherwise
    /// it is guessed from how far away the reset is, which can't tell a weekly
    /// window in its last day from a five-hour one.
    var window: UsageWindow?

    enum CountdownStyle {
        case full     // "2h 13m remaining" / "1h 30m into window"
        case compact  // "Resets in 2h 13m" / "Started 1h 30m ago"
    }

    enum CountdownMode {
        case remaining  // Time until reset
        case elapsed    // Time since last reset
    }

    /// Duration of the window. 5h for session, 7d for weekly.
    private var windowDuration: TimeInterval {
        if let window { return window.duration }
        let remaining = targetDate.timeIntervalSinceNow
        // If remaining > 1 day, it's a weekly window (7 days)
        if remaining > 86400 { return 604800 }
        // Otherwise 5-hour session window
        return 18000
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = targetDate.timeIntervalSince(context.date)
            if remaining > 0 {
                if mode == .elapsed {
                    elapsedView(remaining: remaining)
                } else {
                    remainingView(remaining: remaining)
                }
            } else {
                Text("Resetting...")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private func remainingView(remaining: TimeInterval) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if style == .compact && remaining > 86400 {
                // Weekly reset > 24h away: show absolute date
                Text("Resets on \(Self.resetDateFormatter.string(from: targetDate))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                if style == .compact {
                    Text("Resets in")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(TimeFormatting.longDuration(remaining))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if style == .full {
                    Text("remaining")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private static let resetDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d 'at' h:mm a"
        return f
    }()

    private func elapsedView(remaining: TimeInterval) -> some View {
        let elapsed = max(0, windowDuration - remaining)
        return HStack(spacing: 2) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if style == .compact {
                Text("Started")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(TimeFormatting.longDuration(elapsed))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if style == .full {
                Text("into window")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
