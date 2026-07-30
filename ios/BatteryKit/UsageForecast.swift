import SwiftUI

/// Where the open session window is heading — the numbers *and* the words.
///
/// Every surface that talks about a projection (the dashboard's Forecast card,
/// the large Forecast widget, the Live Activity) builds one of these, so they can
/// never disagree about the pace, the outlook, or how it's phrased.
///
/// It prefers a payload's **precomputed** burn rate — surfaces still never run
/// the regression themselves (see `UsagePayload`). When there isn't one it falls
/// back to the window's own average, which it can derive from `utilization` and
/// `resetsAt` alone because the session window is a fixed five hours. That
/// fallback is why a projection is available on a cold launch, in a widget that
/// has never seen two samples, and on a Live Activity whose state was built on a
/// Mac — none of which need to send anything new for it to work.
struct UsageForecast {

    /// What this window is heading for, most urgent first.
    enum Outlook {
        /// Already spent — there is nothing left to project toward.
        case atLimit
        /// Projected to reach 100% before the window resets.
        case reachesLimit
        /// A measurable pace that still lands under the limit.
        case onPace
        /// No measurable pace in this window — idle, or too early to tell.
        case idle
        /// No session window is open, so there is nothing to project.
        case noWindow
    }

    /// Where the pace being projected from came from. Surfaces phrase the two
    /// differently because they are not the same quality of number.
    enum Pace {
        /// The regression over recent samples — the live rate right now.
        case measured
        /// Utilization spread over the part of the window that has elapsed.
        /// Needs no history at all, so it's available on the first sample after
        /// a cold launch, in the widget's own self-fetch, and on a phone that
        /// has never had two samples in the same window.
        case average
        /// Nothing to project from.
        case none
    }

    /// Below this a "rate" is regression noise rather than a pace. Same gate
    /// `UsagePayload.hasLiveProjection` uses.
    static let minimumRate = 0.05

    /// The session window's fixed length. This is what makes the average pace
    /// derivable from a single sample: the window opened `sessionWindow` before
    /// it resets, so `now` has a known position inside it.
    static let sessionWindow: TimeInterval = 5 * 3600

    /// How much of the window must have elapsed before its average means
    /// anything. Dividing by the first ninety seconds turns 2% used into
    /// "80%/hr", which would be a confident-looking lie.
    static let minimumElapsedForAverage: TimeInterval = 12 * 60

    let outlook: Outlook
    let utilization: Double
    /// The pace actually being projected from — measured when we have one,
    /// otherwise the window average. This is the number every surface shows.
    let burnRatePerHour: Double
    /// Where `burnRatePerHour` came from.
    let pace: Pace
    /// The regression's rate, whether or not it's the one being used.
    let measuredRatePerHour: Double
    let resetsAt: Date?
    /// When 100% is reached — only ever set when that lands inside this window.
    let projectedLimitAt: Date?
    /// Whether `projectedLimitAt` is pinned to a real measurement (so it counts
    /// down on its own) or re-derived on every render from the average (so it
    /// would spring back to full on each rebuild if rendered as a live timer).
    let limitIsAnchored: Bool
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
        let measured = max(0, burnRatePerHour)
        let secondsLeft = resetsAt.map { max(0, $0.timeIntervalSince(now)) } ?? 0
        let hoursLeft = secondsLeft / 3600
        let headroom = max(0, 100 - util)

        // The window we know about has already ended — a new one opens on the
        // next request, and nothing about the old one is worth projecting.
        let hasWindow = resetsAt != nil && secondsLeft > 0

        // The average pace: everything spent, spread over the elapsed part of
        // the window. Derived from `utilization` and `resetsAt` alone, both of
        // which every surface already has, so no extra field has to travel over
        // the wire or through the push relay for this to work everywhere.
        let elapsed = hasWindow ? max(0, Self.sessionWindow - secondsLeft) : 0
        let average: Double? = {
            guard hasWindow, util > 0, elapsed >= Self.minimumElapsedForAverage else { return nil }
            let rate = util / (elapsed / 3600)
            return rate > Self.minimumRate ? rate : nil
        }()

        // Measured always wins: it describes right now, the average describes
        // the whole window. The average only fills the silence.
        let pace: Pace
        let rate: Double
        if measured > Self.minimumRate {
            pace = .measured
            rate = measured
        } else if let average {
            pace = .average
            rate = average
        } else {
            pace = .none
            rate = 0
        }

        // A carried-forward payload can hold a limit time that has since passed,
        // or one beyond the reset — neither is something to project from.
        let anchoredLimit: Date? = {
            guard pace == .measured, let limit = projectedLimitAt,
                  limit > now, let reset = resetsAt, limit < reset else { return nil }
            return limit
        }()

        // Only the measured path arrives with a limit time precomputed. When the
        // average is doing the work, derive one the same way `BurnRateCalculator`
        // would — otherwise the one surface that most wants a projection ("when
        // do I run out?") is the one that never gets it.
        let limit: Date? = anchoredLimit ?? {
            guard pace == .average, rate > Self.minimumRate, headroom > 0 else { return nil }
            let arrival = now.addingTimeInterval(headroom / rate * 3600)
            // `<=`: a pace that spends the last point exactly at the reset has
            // still reached the limit, and calling that "on pace" would leave
            // a card reading "On pace for 100% at reset" with a calm badge.
            guard let reset = resetsAt, arrival <= reset else { return nil }
            return arrival
        }()

        self.utilization = util
        self.burnRatePerHour = rate
        self.pace = pace
        self.measuredRatePerHour = measured
        self.resetsAt = resetsAt
        self.projectedLimitAt = limit
        self.limitIsAnchored = anchoredLimit != nil
        self.projectedAtReset = min(100, util + rate * hoursLeft)
        self.headroom = headroom
        self.secondsToReset = secondsLeft
        // Under ~1 minute left the quotient explodes into a meaningless number
        // ("room for 3,400%/hr"), so we simply stop claiming one.
        self.sustainableRatePerHour = hoursLeft > 1.0 / 60 ? headroom / hoursLeft : nil
        self.isSessionActive = isSessionActive
        self.now = now

        if !hasWindow {
            self.outlook = .noWindow
        } else if headroom <= 0 {
            self.outlook = .atLimit
        } else if limit != nil {
            self.outlook = .reachesLimit
        } else if pace == .none {
            self.outlook = .idle
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
    ///
    /// Every branch that *can* be a projection is one. The old fallback here
    /// read "58% left in this window", which is the ring's number restated —
    /// and because the phone rarely had a measured rate, it was what the Lock
    /// Screen showed nearly all the time. It now only appears when a window is
    /// genuinely too fresh or too empty to project from.
    var headline: String {
        switch outlook {
        case .atLimit:
            return "Limit reached · resets in \(TimeFormatting.shortDuration(secondsToReset))"
        case .reachesLimit:
            return "Hits 100% in \(TimeFormatting.shortDuration(secondsToLimit ?? 0))"
        case .onPace:
            return "On pace for \(Self.percent(projectedAtReset))% at reset"
        case .idle:
            if utilization <= 0 { return "Nothing used yet this window" }
            return isSessionActive
                ? "\(Self.percent(headroom))% left · measuring pace"
                : "\(Self.percent(headroom))% left in this window"
        case .noWindow:
            return "No session window open"
        }
    }

    /// A second line for surfaces with room for one (the dashboard, the large
    /// widget). Deliberately says something the headline and the stats don't:
    /// what pace actually *fits* in the time left, and — when the projection is
    /// riding on the window average rather than a live measurement — where the
    /// number came from, so "on pace" can't be misread as "right now".
    var detail: String? {
        // "Room for 0.0%/hr" is not advice, so a spent window says the one thing
        // that is still actionable: the wait is finite.
        if outlook == .atLimit { return "Nothing left until this window resets" }
        let provenance = pace == .average ? "Averaged over this window" : nil
        guard let sustainable = sustainableRatePerHour else {
            return outlook == .noWindow ? "A new window opens with your next session" : provenance
        }
        let room: String
        switch outlook {
        case .reachesLimit:  room = "Ease to \(Self.rate(sustainable)) to last the window"
        case .onPace, .idle: room = "Room for \(Self.rate(sustainable)) until reset"
        case .atLimit:       return "Nothing left until this window resets"
        case .noWindow:      return "A new window opens with your next session"
        }
        return provenance.map { "\($0) · \(room)" } ?? room
    }

    /// Short status for a badge — the outlook in two words or fewer.
    var badgeLabel: String {
        switch outlook {
        case .atLimit:      return "At limit"
        case .reachesLimit: return "At risk"
        case .onPace:       return pace == .average ? "Averaging" : "On pace"
        case .idle:         return isSessionActive ? "Measuring" : "Idle"
        case .noWindow:     return "No window"
        }
    }

    var symbol: String {
        switch outlook {
        case .atLimit:      return "exclamationmark.octagon.fill"
        case .reachesLimit: return "exclamationmark.triangle.fill"
        // A flame is a claim about right now, so it's reserved for a measured
        // pace; a window average gets the trend line instead.
        case .onPace:       return pace == .average ? "chart.line.uptrend.xyaxis" : "flame.fill"
        case .idle:         return isSessionActive ? "speedometer" : "checkmark.circle"
        case .noWindow:     return "moon.zzz"
        }
    }

    var tint: Color {
        switch outlook {
        case .atLimit:      return BatteryPalette.brandDeep
        case .reachesLimit: return BatteryPalette.brandDeep
        case .onPace:       return BatteryPalette.brandDark
        case .idle:         return BatteryPalette.brand
        case .noWindow:     return .secondary
        }
    }

    /// The pace being projected from, or an em dash when there isn't one.
    var rateText: String {
        burnRatePerHour > Self.minimumRate ? Self.rate(burnRatePerHour) : "—"
    }

    /// Time until the limit, or an em dash when it isn't projected to arrive.
    var timeToLimitText: String {
        guard let seconds = secondsToLimit else { return "—" }
        return TimeFormatting.shortDuration(seconds)
    }

    /// Time until the limit, rendered so it stays truthful between refreshes: a
    /// self-updating countdown when the limit is anchored to a measurement, a
    /// static duration when it's re-derived from the average on every render
    /// (a live timer on that would visibly spring back to full each rebuild).
    var timeToLimitLive: Text? {
        guard let limit = projectedLimitAt else { return nil }
        // `.timer` ("49:58") rather than `.relative` ("49 min, 58 sec") — the
        // relative phrasing spells out two units and is far too wide inline.
        return limitIsAnchored
            ? Text(limit, style: .timer)
            : Text(TimeFormatting.shortDuration(secondsToLimit ?? 0))
    }

    /// Headline as `Text`, with the time-based part rendered as a system-updating
    /// countdown where that's honest. Widgets re-render only on a new timeline
    /// entry (~15 min), so a baked-in "47m" would sit frozen and quietly lie.
    var liveHeadline: Text {
        if outlook == .reachesLimit, let countdown = timeToLimitLive {
            return Text("Hits 100% in ") + countdown
        }
        return Text(headline)
    }

    /// The "where does this land" stat for wide surfaces. Time-to-limit when
    /// 100% actually arrives inside this window; otherwise the landing point,
    /// because "To limit —" was the cell the app showed most often and it told
    /// the reader nothing.
    var landingStat: (label: String, value: String, isUrgent: Bool) {
        switch outlook {
        case .reachesLimit:
            return ("To limit", timeToLimitText, true)
        case .atLimit:
            return ("To reset", TimeFormatting.shortDuration(secondsToReset), true)
        case .noWindow:
            return ("At reset", "—", false)
        case .onPace, .idle:
            return ("At reset", "\(Self.percent(projectedAtReset))%", false)
        }
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
