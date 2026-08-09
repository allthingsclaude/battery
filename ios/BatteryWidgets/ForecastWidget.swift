import WidgetKit
import SwiftUI

/// Large — the whole picture on the Home Screen: the session ring, where the
/// window is heading, and both 7-day limits underneath.
///
/// The other three widgets answer "where am I now". This one answers "where is
/// this going", which is the question worth a large tile. Everything it shows is
/// precomputed in the payload (see `UsagePayload`) and phrased by the shared
/// `UsageForecast`, so it can't disagree with the app or the Live Activity.
struct ForecastWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeForecastLarge", provider: UsageProvider()) { entry in
            widgetBody(entry) { LargeForecastView(payload: $0) }
        }
        .configurationDisplayName("Claude — Forecast")
        .description("Your session, where it's heading, and both 7-day limits.")
        .supportedFamilies([.systemLarge])
    }
}

struct LargeForecastView: View {
    let payload: UsagePayload

    var body: some View {
        let forecast = UsageForecast(payload: payload)

        VStack(alignment: .leading, spacing: 11) {
            header

            // Hero: the ring, and the sentence that explains where it's going.
            HStack(alignment: .center, spacing: 16) {
                UsageRing(utilization: payload.sessionUtilization, size: 88, lineWidth: 9,
                          gradientStroke: true)

                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        forecast.liveHeadline
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: forecast.symbol)
                            .font(.caption2).foregroundStyle(forecast.tint)
                    }
                    .lineLimit(2).minimumScaleFactor(0.8)

                    if let detail = forecast.detail {
                        Text(detail)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(2).minimumScaleFactor(0.85)
                    }

                    WidgetCountdown(reset: payload.sessionResetsAt)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Forecast track: solid = spent, translucent = projected by reset.
            VStack(spacing: 6) {
                ForecastBar(current: forecast.utilization, projected: forecast.projectedAtReset)
                ForecastBarCaptions(current: forecast.utilization,
                                    projected: forecast.projectedAtReset,
                                    showsProjection: forecast.outlook != .noWindow)
            }

            // Two stats, not three: time-to-limit already ticks in the headline
            // above and the landing point is already captioned under the bar,
            // so no figure appears twice on one surface.
            HStack(alignment: .top, spacing: 8) {
                ForecastStat(label: "Pace", value: forecast.rateText,
                             tint: forecast.burnRatePerHour > UsageForecast.minimumRate
                                 ? BatteryPalette.brandDark : .secondary)
                ForecastStat(label: "Headroom",
                             value: "\(UsageForecast.percent(forecast.headroom))%")
            }

            Divider().overlay(BatteryPalette.hairline)

            VStack(alignment: .leading, spacing: 9) {
                windowRow(title: "Weekly", util: payload.weeklyUtilization,
                          reset: payload.weeklyResetsAt)
                if let opus = payload.opusUtilization {
                    windowRow(title: "Opus", util: opus, reset: nil)
                }
                if let fable = payload.fableUtilization {
                    windowRow(title: "Fable", util: fable, reset: nil)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            SectionLabel(title: "Session · 5-hour", systemImage: "bolt.fill")
            if payload.isSessionActive {
                Circle().fill(BatteryPalette.brand).frame(width: 6, height: 6)
            }
            Spacer(minLength: 4)
            Text(payload.sessionLevel.label.uppercased())
                .font(.system(size: 9, weight: .bold)).tracking(0.5)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(payload.sessionLevel.color.opacity(0.16), in: Capsule())
                .foregroundStyle(payload.sessionLevel.color)
        }
    }

    private func windowRow(title: String, util: Double, reset: Date?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title: title)
                Spacer()
                Text("\(Int(util.rounded()))%")
                    .font(BatteryFont.numeric(14, weight: .strong, relativeTo: .subheadline))
                    .foregroundStyle(UsageLevel.from(utilization: util).color)
            }
            BatteryProgressBar(utilization: util, height: 6)
            if let reset {
                WidgetCountdown(reset: reset).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }
}
