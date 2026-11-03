import SwiftUI

/// Displays burn rate projections when sufficient data is available.
struct ProjectionView: View {
    let projection: BurnRateProjection?
    /// When the projected window resets.
    let resetsAt: Date?
    /// The window projected: the session, or the weekly window for an account
    /// with no session limit.
    var window: UsageWindow = .session

    var body: some View {
        if let projection = projection, projection.hasEnoughData {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Projections")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    trendBadge(projection.trend)
                }

                if let limitTime = projection.projectedLimitTime {
                    let remaining = limitTime.timeIntervalSinceNow
                    let limitAfterReset = resetsAt.map { limitTime > $0 } ?? false
                    // Only show if it could land within one window's length
                    if remaining > 0 && remaining < window.duration {
                        HStack(spacing: 4) {
                            if limitAfterReset {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(safeColor)
                                Text("Limit in \(TimeFormatting.longDuration(remaining)) (after reset)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(remaining < 1800 ? warningCriticalColor : warningColor)
                                Text("Limit in \(TimeFormatting.longDuration(remaining))")
                                    .font(.caption)
                                    .foregroundStyle(remaining < 1800 ? warningCriticalColor : .primary)
                            }
                        }
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Projected \(Int(projection.projectedAtReset))% at reset")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(rateText(projection.currentRate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func trendBadge(_ trend: BurnRateProjection.Trend) -> some View {
        HStack(spacing: 2) {
            Image(systemName: trendSymbol(trend))
                .font(.system(size: 8))
            Text(trend.rawValue.capitalized)
                .font(.system(size: 9))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(trendColor(trend).opacity(0.15))
        .foregroundStyle(trendColor(trend))
        .clipShape(Capsule())
    }

    private func trendSymbol(_ trend: BurnRateProjection.Trend) -> String {
        switch trend {
        case .increasing: return "arrow.up.right"
        case .stable: return "arrow.right"
        case .decreasing: return "arrow.down.right"
        }
    }

    private var theme: ColorTheme { AppSettings.shared.activeTheme }

    private var safeColor: Color {
        theme == .default ? ColorTheme.brandLight : .green
    }

    private var warningColor: Color {
        theme == .default ? ColorTheme.brand : .orange
    }

    private var warningCriticalColor: Color {
        theme == .default ? ColorTheme.brandDark : .red
    }

    private func trendColor(_ trend: BurnRateProjection.Trend) -> Color {
        switch theme {
        case .default:
            switch trend {
            case .increasing: return ColorTheme.brandDark
            case .stable: return ColorTheme.brand
            case .decreasing: return ColorTheme.brandLight
            }
        case .classic:
            switch trend {
            case .increasing: return .orange
            case .stable: return .blue
            case .decreasing: return .green
            }
        }
    }

    private func rateText(_ rate: Double) -> String {
        let absRate = abs(rate)
        if absRate < 0.1 {
            return "Burn rate: minimal"
        }
        // A weekly pace reads naturally per day: "9.6%/day" rather than
        // "0.4%/hr".
        if window == .weekly {
            return String(format: "Burn rate: %.1f%%/day", absRate * 24)
        }
        return String(format: "Burn rate: %.1f%%/hr", absRate)
    }
}
