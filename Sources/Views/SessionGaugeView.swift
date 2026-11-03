import SwiftUI

/// Displays the primary window's usage with a circular gauge and countdown —
/// the 5-hour session, or the weekly window for an account without one.
struct SessionGaugeView: View {
    let title: String
    let utilization: Double
    let resetsAt: Date?
    let color: Color
    var window: UsageWindow = .session

    private var settings: AppSettings { .shared }

    /// A weekly-only account puts its weekly window here, and it follows the
    /// days preference just like the weekly bar does.
    private var showsDays: Bool { window == .weekly && settings.showWeeklyAsDays }

    var body: some View {
        HStack(spacing: 16) {
            // Circular gauge
            GaugeRingView(
                value: Double(settings.displayPercentage(for: utilization)) / 100.0,
                color: color,
                size: 56,
                segments: showsDays ? AppSettings.daysPerWeek : 1,
                label: showsDays ? settings.weeklyDisplayValue(for: utilization) : nil
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(window == .weekly
                         ? settings.weeklyDisplayValue(for: utilization)
                         : "\(settings.displayPercentage(for: utilization))%")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(color)
                        .monospacedDigit()
                    Text(window == .weekly ? settings.weeklySuffix : settings.percentageSuffix)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let resetsAt = resetsAt {
                    CountdownLabel(targetDate: resetsAt, mode: settings.showTimeSinceReset ? .elapsed : .remaining, window: window)
                }
            }

            Spacer()
        }
    }
}
