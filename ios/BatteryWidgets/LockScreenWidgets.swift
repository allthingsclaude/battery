import WidgetKit
import SwiftUI

/// Lock Screen / StandBy accessory widgets — always-available glances (distinct
/// from the Live Activity, which comes and goes). The system renders these
/// monochrome, so they lean on shape and the accent tint rather than color.
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
        .description("Session usage on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct LockScreenWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let payload: UsagePayload

    var body: some View {
        switch family {
        case .accessoryInline:
            // e.g. "[battery symbol] 42% · 2 hr, 13 min"
            Label {
                inlineText
            } icon: {
                Image(systemName: payload.sessionLevel.sfSymbol)
            }
        case .accessoryRectangular:
            rectangular
        default:
            circular
        }
    }

    private var circular: some View {
        Gauge(value: min(100, payload.sessionUtilization), in: 0...100) {
            Text("Claude")
        } currentValueLabel: {
            // Left as a system font on purpose: accessory gauges are rendered
            // by the system at sizes it chooses, and a custom face here fights
            // the Lock Screen's own metrics rather than matching them.
            Text("\(Int(payload.sessionUtilization.rounded()))")
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.caption2)
                Text("Session \(Int(payload.sessionUtilization.rounded()))%")
                    .font(BatteryFont.numeric(12, weight: .strong, relativeTo: .caption))
                if payload.isSessionActive {
                    Image(systemName: "circle.fill").font(.system(size: 5))
                }
            }
            .widgetAccentable()
            Gauge(value: min(100, payload.sessionUtilization), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(.primary)
            secondaryLine.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // Both lines use system-updating date text: a Lock Screen accessory is only
    // re-rendered on a new timeline entry (~15 min), so a precomputed string
    // would sit frozen in between.

    private var inlineText: Text {
        let pct = Text("\(Int(payload.sessionUtilization.rounded()))%")
        if let reset = payload.sessionResetsAt {
            return pct + Text(" · ") + Text(reset, style: .relative)
        }
        return pct + Text(" used")
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
            if let reset = payload.sessionResetsAt {
                return Text("At limit · ") + Text(reset, style: .relative)
            }
            return Text("Limit reached")
        case .onPace:
            return Text("→ \(UsageForecast.percent(forecast.projectedAtReset))% at reset")
        case .idle, .noWindow:
            if let reset = payload.sessionResetsAt, reset > Date() {
                return Text("Resets in ") + Text(reset, style: .relative)
            }
            return Text("Weekly \(Int(payload.weeklyUtilization.rounded()))%")
        }
    }
}
