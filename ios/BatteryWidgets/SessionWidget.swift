import WidgetKit
import SwiftUI

// Three Home Screen widgets, all styled to match the desktop panel (terracotta
// ring, SF Rounded numerals, branded bars):
//   • Session  — small square, the 5-hour window
//   • Weekly   — small square, the 7-day window
//   • Overview — medium, both windows + Opus together

/// Small square — 5-hour session.
/// NOTE: a fresh `kind` (not the old "BatterySessionWidget", which iOS still
/// associates with the previous small+medium definition and its cached state).
struct SessionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeSessionSmall", provider: UsageProvider()) { entry in
            widgetBody(entry) { SmallGaugeView(payload: $0, window: .session) }
        }
        .configurationDisplayName("Claude — Session")
        .description("Your 5-hour session usage.")
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

/// Shared wrapper: honest empty state when there's no data + the surface background.
@ViewBuilder
private func widgetBody<Content: View>(
    _ entry: UsageEntry,
    @ViewBuilder content: (UsagePayload) -> Content
) -> some View {
    Group {
        if let payload = entry.payload {
            content(payload)
        } else {
            WidgetEmptyView()
        }
    }
    .widgetBackground(BatteryPalette.surface)
}

// MARK: - Small square (Session or Weekly)

struct SmallGaugeView: View {
    let payload: UsagePayload
    let window: UsagePayload.FocusWindow

    private var isWeekly: Bool { window == .weekly }
    private var util: Double { isWeekly ? payload.weeklyUtilization : payload.sessionUtilization }
    private var reset: Date? { isWeekly ? payload.weeklyResetsAt : payload.sessionResetsAt }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                SectionLabel(title: isWeekly ? "Weekly" : "Session")
                if !isWeekly && payload.isSessionActive {
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
            // Left: the session ring is the hero — label above, 5-hour reset below,
            // all centered on the ring.
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    SectionLabel(title: "Session")
                    if payload.isSessionActive {
                        Circle().fill(BatteryPalette.brand).frame(width: 6, height: 6)
                    }
                }
                UsageRing(utilization: payload.sessionUtilization, size: 96, lineWidth: 9,
                          gradientStroke: true)
                WidgetCountdown(reset: payload.sessionResetsAt)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 138)

            // Right: weekly, then Opus (both 7-day → weekly shows the reset date).
            VStack(alignment: .leading, spacing: 14) {
                windowBlock(title: "Weekly", util: payload.weeklyUtilization,
                            reset: payload.weeklyResetsAt)
                if let opus = payload.opusUtilization {
                    windowBlock(title: "Opus", util: opus, reset: nil)
                }
            }
            .frame(maxWidth: .infinity)
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
