import WidgetKit
import SwiftUI

// Home Screen widgets, all styled to match the desktop panel (terracotta ring,
// branded numerals and bars):
//   • Session  — small square, the 5-hour window
//   • Weekly   — small square, the 7-day window
//   • Overview — medium, both windows + Opus together
//   • Forecast — large, everything plus where the session is heading
//                (see ForecastWidget.swift)
//
// An account with no five-hour limit (verified Ultra) has no session to show,
// so each of these leads with the weekly window instead, and a quiet "No 5-hour
// limit" note fills any slot the session leaves behind. Never a 0% ring.

/// Small square — 5-hour session.
/// NOTE: a fresh `kind` (not the old "BatterySessionWidget", which iOS still
/// associates with the previous small+medium definition and its cached state).
struct SessionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeSessionSmall", provider: UsageProvider()) { entry in
            widgetBody(entry) { SmallGaugeView(payload: $0, window: .session) }
        }
        .configurationDisplayName("Claude — Session")
        .description("Your 5-hour session usage, or your weekly usage on plans without one.")
        .supportedFamilies([.systemSmall])
    }
}

/// Small square — 7-day weekly.
struct WeeklyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BatteryWeeklyWidget", provider: UsageProvider()) { entry in
            widgetBody(entry) { SmallGaugeView(payload: $0, window: .weekly) }
        }
        .configurationDisplayName("Claude — Weekly")
        .description("Your 7-day weekly usage.")
        .supportedFamilies([.systemSmall])
    }
}

/// Medium — session + weekly + Opus together.
struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BatteryOverviewWidget", provider: UsageProvider()) { entry in
            widgetBody(entry) { MediumOverviewView(payload: $0) }
        }
        .configurationDisplayName("Claude — Overview")
        .description("Your 5-hour session and 7-day weekly limits together.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Small square (Session or Weekly)

struct SmallGaugeView: View {
    let payload: UsagePayload
    let window: UsagePayload.FocusWindow

    /// The Session tile shows the weekly window for an account without a
    /// session limit — the same tile as Weekly, rather than a ring stuck at 0%.
    private var isWeekly: Bool { window == .weekly || !payload.hasSessionLimit }
    private var util: Double { isWeekly ? payload.weeklyUtilization : payload.sessionUtilization }
    private var reset: Date? { isWeekly ? payload.weeklyResetsAt : payload.sessionResetsAt }
    /// The activity dot belongs to whichever window activity is inferred from.
    private var showsActiveDot: Bool {
        payload.isSessionActive && (isWeekly ? .weekly : .session) == payload.primaryWindow
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                SectionLabel(title: isWeekly ? "Weekly" : "Session")
                if showsActiveDot {
                    Circle().fill(BatteryPalette.brand).frame(width: 7, height: 7)
                }
            }
            Spacer(minLength: 0)
            UsageRing(utilization: util, size: 92, lineWidth: 9, gradientStroke: true)
            Spacer(minLength: 0)
            WidgetCountdown(reset: reset)
                .lineLimit(1).minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(4)
    }
}

// MARK: - Medium overview

struct MediumOverviewView: View {
    let payload: UsagePayload

    var body: some View {
        HStack(spacing: 22) {
            // Left: the primary ring is the hero — label above, reset below, all
            // centered on the ring. The session's, or the week's without one.
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    SectionLabel(title: payload.hasSessionLimit ? "Session" : "Weekly")
                    if payload.isSessionActive {
                        Circle().fill(BatteryPalette.brand).frame(width: 6, height: 6)
                    }
                }
                UsageRing(utilization: payload.primaryUtilization, size: 96, lineWidth: 9,
                          gradientStroke: true)
                WidgetCountdown(reset: payload.primaryResetsAt)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 138)

            // Right: weekly, then Opus (both 7-day → weekly shows the reset date).
            // With the week already the hero, its slot goes to the note saying
            // why there's no session ring — otherwise the column could be empty.
            VStack(alignment: .leading, spacing: 14) {
                if payload.hasSessionLimit {
                    windowBlock(title: "Weekly", util: payload.weeklyUtilization,
                                reset: payload.weeklyResetsAt)
                } else {
                    NoSessionLimitNote()
                }
                if let opus = payload.opusUtilization {
                    windowBlock(title: "Opus", util: opus, reset: nil)
                }
                if let fable = payload.fableUtilization {
                    windowBlock(title: "Fable", util: fable, reset: nil)
                }
            }
            // Leading, so a column holding only the note lines up with the rows
            // it replaces instead of floating in the middle.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A labeled progress row with a percentage and an optional reset line.
    private func windowBlock(title: String, util: Double, reset: Date?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title: title)
                Spacer()
                Text("\(Int(util.rounded()))%")
                    .font(BatteryFont.numeric(15, weight: .strong, relativeTo: .subheadline))
                    .foregroundStyle(UsageLevel.from(utilization: util).color)
            }
            BatteryProgressBar(utilization: util, height: 7)
            if let reset {
                WidgetCountdown(reset: reset).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }
}
