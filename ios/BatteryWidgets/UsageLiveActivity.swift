#if os(iOS)
import ActivityKit
import WidgetKit
import SwiftUI

/// The Lock Screen Live Activity + Dynamic Island for an in-progress session.
/// Started, updated, escalated, and ended by `LiveActivityController` in the app;
/// this file is purely how it looks. It reuses the shared `UsageRing` and the
/// terracotta ramp so it's unmistakably the same product as the menu bar app, and
/// the reset time drives a live countdown that ticks without any push.
@available(iOS 16.2, *)
struct UsageLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: UsageActivityAttributes.self) { context in
            LockScreenActivityView(context: context)
                .activityBackgroundTint(Color(hex: 0x1A1815).opacity(0.94))
                .activitySystemActionForegroundColor(BatteryPalette.brand)
        } dynamicIsland: { context in
            let state = context.state
            let level = state.level
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 10) {
                        UsageRing(utilization: state.sessionUtilization, size: 40, lineWidth: 5,
                                  showsLabel: false, gradientStroke: true, glow: false)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Session").font(.caption2).foregroundStyle(.secondary)
                            Text("\(Int(state.sessionUtilization.rounded()))%")
                                .font(BatteryFont.numeric(20, weight: .strong, relativeTo: .title3))
                                .foregroundStyle(level.color)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Resets").font(.caption2).foregroundStyle(.secondary)
                        if let reset = state.sessionResetsAt {
                            // System-updating text: a Live Activity only re-renders
                            // when the app pushes, so a static string would freeze.
                            Text(reset, style: .relative)
                                .font(BatteryFont.numeric(17, weight: .strong, relativeTo: .headline))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("—").font(.headline)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedFooter(state: state)
                }
            } compactLeading: {
                UsageRing(utilization: state.sessionUtilization, size: 20, lineWidth: 3,
                          showsLabel: false, gradientStroke: true, glow: false)
            } compactTrailing: {
                Text("\(Int(state.sessionUtilization.rounded()))%")
                    .font(BatteryFont.numeric(17, weight: .strong, relativeTo: .body))
                    .foregroundStyle(level.color)
            } minimal: {
                UsageRing(utilization: state.sessionUtilization, size: 20, lineWidth: 3,
                          showsLabel: false, gradientStroke: true, glow: false)
            }
            .keylineTint(level.color)
        }
    }
}

// MARK: - Lock Screen / banner presentation

@available(iOS 16.2, *)
struct LockScreenActivityView: View {
    let context: ActivityViewContext<UsageActivityAttributes>

    private var state: UsageActivityAttributes.ContentState { context.state }
    private var level: UsageLevel { state.level }

    var body: some View {
        if state.didReset { resetCard } else { liveCard }
    }

    private var liveCard: some View {
        HStack(spacing: 16) {
            UsageRing(utilization: state.sessionUtilization, size: 58, lineWidth: 7,
                      gradientStroke: true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Claude")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(level.label.uppercased())
                        .font(.system(size: 9, weight: .bold)).tracking(0.5)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(level.color.opacity(0.28), in: Capsule())
                        .foregroundStyle(level.color)
                }
                Label(footerText, systemImage: state.burnRatePerHour > 0.05 ? "flame.fill" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                Text(weeklyLine)
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 1) {
                // `.relative` reserves a wide slot; trailing-align the glyphs within
                // it so "Updated …" lines up with the countdown below.
                (Text("Updated ") + Text(state.updatedAt, style: .relative))
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).multilineTextAlignment(.trailing)
                if let reset = state.sessionResetsAt {
                    // System-updating so the Lock Screen countdown keeps ticking
                    // between app pushes (a static string would sit frozen).
                    Text(reset, style: .relative)
                        .font(BatteryFont.numeric(20, weight: .strong, relativeTo: .title3))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .multilineTextAlignment(.trailing)
                    Text("until reset").font(.caption2).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .padding(16)
    }

    private var resetCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.largeTitle).foregroundStyle(BatteryPalette.brandGradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session reset").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text("Back to \(Int(state.sessionUtilization.rounded()))% — a fresh 5-hour window.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
        .padding(16)
    }

    private var footerText: String {
        if state.burnRatePerHour > 0.05, let limit = state.projectedLimitAt, limit > Date() {
            return "Hits limit in " + TimeFormatting.shortDuration(limit.timeIntervalSinceNow) + " at this pace"
        }
        if state.burnRatePerHour > 0.05 {
            return String(format: "Burning %.1f%%/hr", state.burnRatePerHour)
        }
        return "Holding steady"
    }

    /// "Weekly 8%" — plus " · Max 5x" only when the plan is actually known.
    private var weeklyLine: String {
        let weekly = "Weekly \(Int(state.weeklyUtilization.rounded()))%"
        let plan = context.attributes.planTier
        return plan.isEmpty ? weekly : "\(weekly) · \(plan)"
    }
}

// MARK: - Dynamic Island expanded footer

@available(iOS 16.2, *)
struct ExpandedFooter: View {
    let state: UsageActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.burnRatePerHour > 0.05 ? "flame.fill" : "checkmark.circle")
                .font(.caption2).foregroundStyle(BatteryPalette.brand)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("Weekly \(Int(state.weeklyUtilization.rounded()))%")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var text: String {
        if state.burnRatePerHour > 0.05, let limit = state.projectedLimitAt, limit > Date() {
            return "≈100% in " + TimeFormatting.shortDuration(limit.timeIntervalSinceNow)
        }
        if state.burnRatePerHour > 0.05 {
            return String(format: "Burning %.1f%%/hr", state.burnRatePerHour)
        }
        return "Comfortably within limit"
    }
}
#endif
