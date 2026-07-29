import SwiftUI

/// Where the open session window is heading — the numbers *and* the words.
///
/// Every surface that talks about a projection (the dashboard's Forecast card,
/// the large Forecast widget, the Live Activity) builds one of these, so they can
/// never disagree about the pace, the outlook, or how it's phrased. It derives
/// from a payload's **precomputed** burn rate — surfaces still never run the
/// regression themselves (see `UsagePayload`).
struct UsageForecast {

    /// What this window is heading for, most urgent first.
    enum Outlook {
        /// Projected to reach 100% before the window resets.
        case reachesLimit
        /// A measurable pace that still lands under the limit.
        case onPace
        /// No measurable pace in this window — idle, or too early to tell.
        case idle
        /// No session window is open, so there is nothing to project.
        case noWindow
    }

    /// Below this a "rate" is regression noise rather than a pace. Same gate
    /// `UsagePayload.hasLiveProjection` uses.
    static let minimumRate = 0.05

    let outlook: Outlook
    let utilization: Double
    let burnRatePerHour: Double
    let resetsAt: Date?
    /// When 100% is reached — only ever set when that lands inside this window.
    let projectedLimitAt: Date?
    /// Where the window lands by reset time, clamped to 0–100.
    let projectedAtReset: Double
    /// Percentage points still unspent.
    let headroom: Double
    /// Seconds until the window resets (0 when no window is open).
    let secondsToReset: TimeInterval
    /// The pace that would spend exactly the remaining headroom by reset — how
    /// fast you can burn and still make it to the end of the window. nil when
    /// there's no window, or so little of it left that the number stops meaning
    /// anything (it tends to infinity as the reset approaches).
    let sustainableRatePerHour: Double?
    let isSessionActive: Bool
    /// The instant this forecast describes. Every derived duration is measured
    /// from here, so a view that rebuilds on a clock can pass its own tick and
    /// get a self-consistent card rather than a mix of two moments.
    let now: Date

    // MARK: - Construction

    init(
        utilization: Double,
        resetsAt: Date?,
        burnRatePerHour: Double,
        projectedLimitAt: Date?,
        isSessionActive: Bool,
        now: Date = Date()
    ) {
        let util = min(100, max(0, utilization))
        let rate = max(0, burnRatePerHour)
        let secondsLeft = resetsAt.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        let hoursLeft = secondsLeft / 3600

        // A carried-forward payload can hold a limit time that has since passed,
        // or one beyond the reset — neither is something to project from.
        let limit: Date? = {
            guard rate > Self.minimumRate, let limit = projectedLimitAt,
                  limit > now, let reset = resetsAt, limit < reset else { return nil }
            return limit
        }()

        self.utilization = util
        self.burnRatePerHour = rate
        self.resetsAt = resetsAt
        self.projectedLimitAt = limit
        self.projectedAtReset = min(100, util + rate * hoursLeft)
        self.headroom = max(0, 100 - util)
        self.secondsToReset = secondsLeft
        // Under ~1 minute left the quotient explodes into a meaningless number
        // ("room for 3,400%/hr"), so we simply stop claiming one.
        self.sustainableRatePerHour = hoursLeft > 1.0 / 60 ? max(0, 100 - util) / hoursLeft : nil
        self.isSessionActive = isSessionActive
        self.now = now

        if resetsAt == nil {
            self.outlook = .noWindow
        } else if rate <= Self.minimumRate {
            self.outlook = .idle
        } else if limit != nil {
            self.outlook = .reachesLimit
        } else {
            self.outlook = .onPace
        }
    }

    init(payload: UsagePayload, now: Date = Date()) {
        self.init(
            utilization: payload.sessionUtilization,
            resetsAt: payload.sessionResetsAt,
            burnRatePerHour: payload.burnRatePerHour,
            projectedLimitAt: payload.projectedLimitAt,
            isSessionActive: payload.isSessionActive,
            now: now
        )
    }

    /// Seconds until the projected limit, when one is projected.
    var secondsToLimit: TimeInterval? {
        projectedLimitAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    var projectedLevel: UsageLevel { .from(utilization: projectedAtReset) }

    // MARK: - Language
    //
    // One phrasing per outlook, written once. Deliberately concrete: every line
    // carries a number the reader can act on, because "Holding steady" told them
    // nothing they couldn't already see from the ring.

    /// The one-line insight for tight surfaces (Live Activity, Dynamic Island).
    var headline: String {
        switch outlook {
        case .reachesLimit:
            return "Hits 100% in \(TimeFormatting.shortDuration(secondsToLimit ?? 0))"
        case .onPace:
            return "On pace for \(Self.percent(projectedAtReset))% at reset"
        case .idle:
            return isSessionActive
                ? "\(Self.percent(headroom))% left · measuring pace"
                : "\(Self.percent(headroom))% left in this window"
        case .noWindow:
            return "No session window open"
        }
    }

    /// A second line for surfaces with room for one (the dashboard, the large
    /// widget). Deliberately says something the headline and the stats don't:
    /// what pace actually *fits* in the time left. nil when there's nothing
    /// honest to add.
    var detail: String? {
        guard let sustainable = sustainableRatePerHour else {
            return outlook == .noWindow ? "A new window opens with your next session" : nil
        }
        switch outlook {
        case .reachesLimit: return "Ease to \(Self.rate(sustainable)) to last the window"
        case .onPace, .idle: return "Room for \(Self.rate(sustainable)) until reset"
        case .noWindow:     return "A new window opens with your next session"
        }
    }

    /// Short status for a badge — the outlook in two words or fewer.
    var badgeLabel: String {
        switch outlook {
        case .reachesLimit: return "At risk"
        case .onPace:       return "On pace"
        case .idle:         return isSessionActive ? "Measuring" : "Idle"
        case .noWindow:     return "No window"
        }
    }

    var symbol: String {
        switch outlook {
        case .reachesLimit: return "exclamationmark.triangle.fill"
        case .onPace:       return "flame.fill"
        case .idle:         return isSessionActive ? "speedometer" : "checkmark.circle"
        case .noWindow:     return "moon.zzz"
        }
    }

    var tint: Color {
        switch outlook {
        case .reachesLimit: return BatteryPalette.brandDeep
        case .onPace:       return BatteryPalette.brandDark
        case .idle:         return BatteryPalette.brand
        case .noWindow:     return .secondary
        }
    }

    /// The measured pace, or an em dash when there isn't one to report.
    var rateText: String {
        burnRatePerHour > Self.minimumRate ? Self.rate(burnRatePerHour) : "—"
    }

    /// Time until the limit, or an em dash when it isn't projected to arrive.
    var timeToLimitText: String {
        guard let seconds = secondsToLimit else { return "—" }
        return TimeFormatting.shortDuration(seconds)
    }

    /// Headline as `Text`, with the time-based part rendered as a system-updating
    /// countdown. Widgets re-render only on a new timeline entry (~15 min), so a
    /// baked-in "47m" would sit frozen and quietly lie; this keeps ticking.
    ///
    /// `.timer` ("49:58") rather than `.relative` ("49 min, 58 sec") — the
    /// relative phrasing spells out two units and is far too wide for a headline.
    var liveHeadline: Text {
        if outlook == .reachesLimit, let limit = projectedLimitAt {
            return Text("Hits 100% in ") + Text(limit, style: .timer)
        }
        return Text(headline)
    }

    // MARK: - Formatting

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))" }

    /// "9.2%/hr" — one decimal, because whole numbers hide a doubling of pace at
    /// the low end where it matters most.
    static func rate(_ value: Double) -> String { String(format: "%.1f%%/hr", value) }
}

// MARK: - Forecast bar

/// A progress bar that also shows where the window is *heading*: the solid
/// gradient is what's been used, the translucent extension is the projection at
/// reset, and the tick marks the projected landing point.
struct ForecastBar: View {
    let current: Double         // 0–100
    let projected: Double       // 0–100, >= current
    var height: CGFloat = 10

    private var currentFraction: CGFloat { CGFloat(min(100, max(0, current)) / 100) }
    private var projectedFraction: CGFloat { CGFloat(min(100, max(current, projected)) / 100) }
    private var level: UsageLevel { .from(utilization: current) }
    private var projectedLevel: UsageLevel { .from(utilization: projected) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)

                // Projected extension — same family, low opacity, so it reads as
                // "not yet spent" rather than as another metric.
                Capsule()
                    .fill(projectedLevel.color.opacity(0.28))
                    .frame(width: geo.size.width * projectedFraction)

                Capsule()
                    .fill(level.gradient)
                    .frame(width: geo.size.width * currentFraction)

                // Landing tick, only once the projection is visibly ahead of now.
                if projectedFraction - currentFraction > 0.02 {
                    Capsule()
                        .fill(projectedLevel.color)
                        .frame(width: 2, height: height + 4)
                        .offset(x: max(0, geo.size.width * projectedFraction - 2))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: currentFraction)
            .animation(.easeInOut(duration: 0.4), value: projectedFraction)
        }
        .frame(height: height)
    }
}

/// "Now 42%" / "At reset 78%" captions, sized to sit under a `ForecastBar`.
struct ForecastBarCaptions: View {
    let current: Double
    let projected: Double
    var showsProjection: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            caption(label: "Now", value: current, tint: UsageLevel.from(utilization: current).color)
            Spacer(minLength: 8)
            if showsProjection {
                caption(label: "At reset", value: projected,
                        tint: UsageLevel.from(utilization: projected).color)
            }
        }
    }

    private func caption(label: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased())
                .font(BatteryFont.label(9)).tracking(0.6)
                .foregroundStyle(.tertiary)
            Text("\(UsageForecast.percent(value))%")
                .font(BatteryFont.numeric(11, weight: .strong, relativeTo: .caption2))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Stat strip

/// A compact label-over-value column, used in threes under a forecast bar.
struct ForecastStat: View {
    let label: String
    let value: Text
    var tint: Color = .primary

    init(label: String, value: String, tint: Color = .primary) {
        self.init(label: label, value: Text(value), tint: tint)
    }

    /// `Text` overload so a widget can pass a system-updating date
    /// (`Text(_, style: .relative)`) and have the figure keep ticking between
    /// timeline entries instead of freezing for up to 15 minutes.
    init(label: String, value: Text, tint: Color = .primary) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(BatteryFont.label(9)).tracking(0.6)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            value
                .font(BatteryFont.numeric(13, weight: .strong, relativeTo: .caption))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
