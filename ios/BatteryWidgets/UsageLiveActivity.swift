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
                                .font(BatteryFont.numeric(17, weight: .strong, relativeTo: .headline))
                                .foregroundStyle(level.color)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Resets").font(.caption2).foregroundStyle(.secondary)
                        if let reset = state.sessionResetsAt {
                            // Compact for the same reason as the card above.
                            Text(TimeFormatting.shortDuration(max(0, reset.timeIntervalSinceNow)))
                                .font(BatteryFont.numeric(15, weight: .strong, relativeTo: .subheadline))
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
                    .font(BatteryFont.numeric(14, weight: .strong, relativeTo: .footnote))
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
    private var forecast: UsageForecast { .init(state: state) }

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
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(level.color.opacity(0.28), in: Capsule())
                        .foregroundStyle(level.color)
                }
                // The projection, not a mood and not the ring's own number
                // restated. This line reached the reader as "58% left in this
                // window" for most of a session's life, because the phone so
                // rarely had a measured burn rate to project from; it now falls
                // back to the window's average pace (see `UsageForecast`) so
                // there is a projection here whenever one can be made at all.
                //
                // `liveHeadline` rather than `headline`: when 100% is actually
                // coming, the countdown ticks between pushes instead of sitting
                // frozen at whatever it said when the card was last updated.
                Label {
                    forecast.liveHeadline
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1).minimumScaleFactor(0.8)
                } icon: {
                    Image(systemName: forecast.symbol)
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                Text(weeklyLine)
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 1) {
                // `.relative` reserves a wide slot; trailing-align the glyphs within
                // it so "Updated …" lines up with the countdown below.
                // Stays `.relative` — this is the one line that must keep
                // ticking, since it's what discloses a stale card. It reserves a
                // wide slot for the longest phrasing it might reach, so let it
                // scale rather than clip to "Updated…".
                (Text("Updated ") + Text(state.updatedAt, style: .relative))
                    .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.trailing)
                if let reset = state.sessionResetsAt {
                    // Compact ("2h 13m") rather than `Text(_, style: .relative)`.
                    // `.relative` renders "2 hr, 13 min", which in a monospaced
                    // face is far too wide for this column — it truncated either
                    // itself or the app name beside it, whichever lost the
                    // layout fight.
                    //
                    // The tradeoff is that a static string can't tick on its
                    // own. That mattered when the phone refreshed only on the
                    // system's schedule; now the relay pushes at least every
                    // five minutes, and the live "Updated …" line directly above
                    // discloses any lag, so the card can't quietly mislead.
                    Text(TimeFormatting.shortDuration(max(0, reset.timeIntervalSinceNow)))
                        .font(BatteryFont.numeric(17, weight: .strong, relativeTo: .headline))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
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

    private var forecast: UsageForecast { .init(state: state) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: forecast.symbol)
                .font(.caption2).foregroundStyle(BatteryPalette.brand)
            forecast.liveHeadline
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 6)
            Text("Weekly \(Int(state.weeklyUtilization.rounded()))%")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize()
        }
    }
}

// MARK: - Forecast from activity state

@available(iOS 16.2, *)
extension UsageForecast {
    /// The Live Activity carries the same precomputed projection fields as the
    /// payload — including when the push relay builds the state on a Mac — so the
    /// card can speak in exactly the same terms as the app.
    init(state: UsageActivityAttributes.ContentState, now: Date = Date()) {
        self.init(
            utilization: state.sessionUtilization,
            resetsAt: state.sessionResetsAt,
            burnRatePerHour: state.burnRatePerHour,
            projectedLimitAt: state.projectedLimitAt,
            isSessionActive: state.isSessionActive,
            now: now
        )
    }
}
#endif
