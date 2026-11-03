import WidgetKit
import SwiftUI

/// Lock Screen / StandBy accessory widgets — always-available glances (distinct
/// from the Live Activity, which comes and goes). The system renders these
/// monochrome, so they lean on shape and the accent tint rather than color.
///
/// They show the primary window: the session, or the week for an account with
/// no five-hour limit.
struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BatteryLockScreenWidget", provider: UsageProvider()) { entry in
            if let payload = entry.payload {
                LockScreenWidgetView(payload: payload)
            } else {
                WidgetEmptyView()
            }
        }
        .configurationDisplayName("Claude Usage")
        .description("Your Claude usage on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockScreenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let payload: UsagePayload

    private var util: Double { payload.primaryUtilization }
    private var reset: Date? { payload.primaryResetsAt }
    private var isWeekly: Bool { !payload.hasSessionLimit }

    var body: some View {
        switch family {
        case .accessoryInline:
            // e.g. "[battery symbol] 42% · 2 hr, 13 min", or for an account
            // with no session limit "[battery symbol] 38% weekly · resets Thu"
            Label {
                inlineText
            } icon: {
                Image(systemName: payload.primaryLevel.sfSymbol)
            }
        case .accessoryRectangular:
            rectangular
        default:
            circular
        }
    }

    private var circular: some View {
        Gauge(value: min(100, util), in: 0...100) {
            Text("Claude")
        } currentValueLabel: {
            // Left as a system font on purpose: accessory gauges are rendered
            // by the system at sizes it chooses, and a custom face here fights
            // the Lock Screen's own metrics rather than matching them.
            Text("\(Int(util.rounded()))")
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: isWeekly ? "calendar" : "bolt.fill").font(.caption2)
                Text("\(isWeekly ? "Weekly" : "Session") \(Int(util.rounded()))%")
                    .font(BatteryFont.numeric(12, weight: .strong, relativeTo: .caption))
                if payload.isSessionActive {
                    Image(systemName: "circle.fill").font(.system(size: 5))
                }
            }
            .widgetAccentable()
            Gauge(value: min(100, util), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(.primary)
            secondaryLine.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // Both lines use system-updating date text: a Lock Screen accessory is only
    // re-rendered on a new timeline entry (~15 min), so a precomputed string
    // would sit frozen in between.

    private var inlineText: Text {
        let pct = Text("\(Int(util.rounded()))%" + (isWeekly ? " weekly" : ""))
        guard let reset else { return pct + Text(" used") }
        if isDaysOut(reset) {
            return pct + Text(" · resets ") + Text(reset, format: .dateTime.weekday(.abbreviated))
        }
        return pct + Text(" · ") + Text(reset, style: .relative)
    }

    /// A weekly reset is days away. `.relative` would spell that out as "4
    /// days, 6 hours" and overrun the slot, and it has nothing to tick at that
    /// distance anyway — so far-off resets are named by day and time instead.
    private func isDaysOut(_ date: Date) -> Bool { date.timeIntervalSinceNow > 86400 }

    /// "2 hr, 13 min" when the reset is close enough to count down, "Thu 3 PM"
    /// when it isn't.
    private func untilReset(_ date: Date) -> Text {
        isDaysOut(date)
            ? Text(date, format: .dateTime.weekday(.abbreviated).hour())
            : Text(date, style: .relative)
    }

    /// The projection when there is one, the reset countdown when there isn't.
    /// "Nearing limit" used to sit here and needed a measured burn rate the
    /// phone almost never had, so in practice this line was always the reset
    /// time — which the inline widget above already shows.
    private var secondaryLine: Text {
        let forecast = UsageForecast(payload: payload)
        switch forecast.outlook {
        case .reachesLimit:
            return (Text("100% in ") + (forecast.timeToLimitLive ?? Text("—")))
        case .atLimit:
            if let reset {
                return Text("At limit · ") + untilReset(reset)
            }
            return Text("Limit reached")
        case .onPace:
            return Text("→ \(UsageForecast.percent(forecast.projectedAtReset))% at reset")
        case .idle, .noWindow:
            if let reset, reset > Date() {
                return isDaysOut(reset)
                    ? Text("Resets ") + untilReset(reset)
                    : Text("Resets in ") + untilReset(reset)
            }
            // The weekly number is the headline already when there's no
            // session, so say why rather than repeat it.
            return isWeekly
                ? Text(NoSessionLimitNote.text)
                : Text("Weekly \(Int(payload.weeklyUtilization.rounded()))%")
        }
    }
}
