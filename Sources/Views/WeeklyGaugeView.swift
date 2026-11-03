import SwiftUI

/// Displays the weekly usage with a compact horizontal bar.
struct WeeklyGaugeView: View {
    let title: String
    let utilization: Double
    let resetsAt: Date?
    let color: Color

    private var settings: AppSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    Text("\(settings.displayPercentage(for: utilization))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(color)
                        .monospacedDigit()
                    Text(settings.percentageSuffix)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ProgressBarView(value: utilization / 100.0, color: color)

            if let resetsAt = resetsAt {
                CountdownLabel(targetDate: resetsAt, style: .compact, mode: settings.showTimeSinceReset ? .elapsed : .remaining, window: .weekly)
            }
        }
    }
}
