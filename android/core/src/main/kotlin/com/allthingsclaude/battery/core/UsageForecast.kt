package com.allthingsclaude.battery.core

import java.time.Instant

/**
 * Where the open session window is heading — the numbers *and* the words.
 *
 * A port of `ios/BatteryKit/UsageForecast.swift`. Every surface that talks about
 * a projection builds one of these, so they can never disagree about the pace,
 * the outlook, or how it's phrased. On Android that already includes the Live
 * Update's `contentText`, which is why this is Phase 1 work rather than
 * something the dashboard grows later.
 *
 * It prefers a payload's **precomputed** burn rate — surfaces never run the
 * regression themselves. When there isn't one it falls back to the window's own
 * average, derivable from `utilization` and `resetsAt` alone because the session
 * window is a fixed five hours. That fallback is why a projection exists on a
 * cold launch and in a widget that has never seen two samples.
 *
 * Deliberately free of any UI type: Swift's version carries `Color` and SF
 * Symbol names, which don't cross platforms. [tintColor] returns an ARGB [Int]
 * and [symbol] a platform-neutral enum the Android layer maps to a drawable.
 */
class UsageForecast(
    utilization: Double,
    val resetsAt: Instant?,
    burnRatePerHour: Double,
    projectedLimitAt: Instant?,
    val isSessionActive: Boolean,
    /**
     * The instant this forecast describes. Every derived duration is measured
     * from here, so a view that rebuilds on a clock can pass its own tick and
     * get a self-consistent card rather than a mix of two moments.
     */
    val now: Instant = Instant.now(),
) {

    /** What this window is heading for, most urgent first. */
    enum class Outlook {
        /** Already spent — nothing left to project toward. */
        AT_LIMIT,
        /** Projected to reach 100% before the window resets. */
        REACHES_LIMIT,
        /** A measurable pace that still lands under the limit. */
        ON_PACE,
        /** No measurable pace — idle, or too early to tell. */
        IDLE,
        /** No session window is open. */
        NO_WINDOW,
    }

    /**
     * Where the pace being projected from came from. Surfaces phrase the two
     * differently because they are not the same quality of number.
     */
    enum class Pace {
        /** The regression over recent samples — the live rate right now. */
        MEASURED,
        /** Utilization spread over the elapsed part of the window. */
        AVERAGE,
        /** Nothing to project from. */
        NONE,
    }

    /** Platform-neutral icon hint; the UI layer picks the drawable. */
    enum class Symbol { AT_LIMIT, AT_RISK, BURNING, TRENDING, MEASURING, CALM, NO_WINDOW }

    val utilization: Double
    /** The pace actually being projected from. This is the number every surface shows. */
    val burnRatePerHour: Double
    val pace: Pace
    /** The regression's rate, whether or not it's the one being used. */
    val measuredRatePerHour: Double
    /** When 100% is reached — only ever set when that lands inside this window. */
    val projectedLimitAt: Instant?
    /**
     * Whether [projectedLimitAt] is pinned to a real measurement (so it counts
     * down on its own) or re-derived on every render from the average (so it
     * would spring back to full on each rebuild if rendered as a live timer).
     */
    val limitIsAnchored: Boolean
    /** Where the window lands by reset time, clamped to 0–100. */
    val projectedAtReset: Double
    /** Percentage points still unspent. */
    val headroom: Double
    /** Seconds until the window resets (0 when no window is open). */
    val secondsToReset: Double
    /**
     * The pace that would spend exactly the remaining headroom by reset. Null
     * when there's no window, or so little of it left that the number stops
     * meaning anything (it tends to infinity as the reset approaches).
     */
    val sustainableRatePerHour: Double?
    val outlook: Outlook

    init {
        val util = utilization.coerceIn(0.0, 100.0)
        val measured = maxOf(0.0, burnRatePerHour)
        val secondsLeft = resetsAt?.let { maxOf(0.0, secondsBetween(it, now)) } ?: 0.0
        val hoursLeft = secondsLeft / 3600
        val room = maxOf(0.0, 100 - util)

        // The window we know about has already ended — a new one opens on the
        // next request, and nothing about the old one is worth projecting.
        val hasWindow = resetsAt != null && secondsLeft > 0

        // The average pace: everything spent, spread over the elapsed part of
        // the window. Derived from `utilization` and `resetsAt` alone, both of
        // which every surface already has, so no extra field has to travel over
        // the wire for this to work everywhere.
        val elapsed = if (hasWindow) maxOf(0.0, SESSION_WINDOW - secondsLeft) else 0.0
        val average: Double? = run {
            if (!hasWindow || util <= 0 || elapsed < MINIMUM_ELAPSED_FOR_AVERAGE) return@run null
            val r = util / (elapsed / 3600)
            if (r > MINIMUM_RATE) r else null
        }

        // Measured always wins: it describes right now, the average describes
        // the whole window. The average only fills the silence.
        val resolvedPace: Pace
        val resolvedRate: Double
        when {
            measured > MINIMUM_RATE -> { resolvedPace = Pace.MEASURED; resolvedRate = measured }
            average != null -> { resolvedPace = Pace.AVERAGE; resolvedRate = average }
            else -> { resolvedPace = Pace.NONE; resolvedRate = 0.0 }
        }

        // A carried-forward payload can hold a limit time that has since passed,
        // or one beyond the reset — neither is something to project from.
        val anchoredLimit: Instant? = run {
            if (resolvedPace != Pace.MEASURED || projectedLimitAt == null) return@run null
            if (!projectedLimitAt.isAfter(now)) return@run null
            if (resetsAt == null || !projectedLimitAt.isBefore(resetsAt)) return@run null
            projectedLimitAt
        }

        // Only the measured path arrives with a limit time precomputed. When the
        // average is doing the work, derive one the same way BurnRateCalculator
        // would — otherwise the surface that most wants a projection ("when do I
        // run out?") is the one that never gets it.
        val limit: Instant? = anchoredLimit ?: run {
            if (resolvedPace != Pace.AVERAGE || resolvedRate <= MINIMUM_RATE || room <= 0) return@run null
            val arrival = now.plusMillis((room / resolvedRate * 3600 * 1000).toLong())
            // `<=`: a pace that spends the last point exactly at the reset has
            // still reached the limit, and calling that "on pace" would leave a
            // card reading "On pace for 100% at reset" with a calm badge.
            if (resetsAt == null || arrival.isAfter(resetsAt)) return@run null
            arrival
        }

        this.utilization = util
        this.burnRatePerHour = resolvedRate
        this.pace = resolvedPace
        this.measuredRatePerHour = measured
        this.projectedLimitAt = limit
        this.limitIsAnchored = anchoredLimit != null
        this.projectedAtReset = minOf(100.0, util + resolvedRate * hoursLeft)
        this.headroom = room
        this.secondsToReset = secondsLeft
        // Under ~1 minute left the quotient explodes into a meaningless number
        // ("room for 3,400%/hr"), so we simply stop claiming one.
        this.sustainableRatePerHour = if (hoursLeft > 1.0 / 60) room / hoursLeft else null

        this.outlook = when {
            !hasWindow -> Outlook.NO_WINDOW
            room <= 0 -> Outlook.AT_LIMIT
            limit != null -> Outlook.REACHES_LIMIT
            resolvedPace == Pace.NONE -> Outlook.IDLE
            else -> Outlook.ON_PACE
        }
    }

    constructor(payload: UsagePayload, now: Instant = Instant.now()) : this(
        utilization = payload.sessionUtilization,
        resetsAt = payload.sessionResetsAt,
        burnRatePerHour = payload.burnRatePerHour,
        projectedLimitAt = payload.projectedLimitAt,
        isSessionActive = payload.isSessionActive,
        now = now,
    )

    /** Seconds until the projected limit, when one is projected. */
    val secondsToLimit: Double?
        get() = projectedLimitAt?.let { maxOf(0.0, secondsBetween(it, now)) }

    val projectedLevel: UsageLevel get() = UsageLevel.from(projectedAtReset)

    // MARK: - Language
    //
    // One phrasing per outlook, written once. Deliberately concrete: every line
    // carries a number the reader can act on, because "Holding steady" told them
    // nothing they couldn't already see from the bar.

    /** The one-line insight for tight surfaces (the Live Update's contentText). */
    val headline: String
        get() = when (outlook) {
            Outlook.AT_LIMIT ->
                "Limit reached · resets in ${TimeFormatting.shortDuration(secondsToReset)}"
            Outlook.REACHES_LIMIT ->
                "Hits 100% in ${TimeFormatting.shortDuration(secondsToLimit ?: 0.0)}"
            Outlook.ON_PACE ->
                "On pace for ${TimeFormatting.percent(projectedAtReset)}% at reset"
            Outlook.IDLE -> when {
                utilization <= 0 -> "Nothing used yet this window"
                isSessionActive -> "${TimeFormatting.percent(headroom)}% left · measuring pace"
                else -> "${TimeFormatting.percent(headroom)}% left in this window"
            }
            Outlook.NO_WINDOW -> "No session window open"
        }

    /**
     * A second line for surfaces with room for one. Deliberately says something
     * the headline and the stats don't: what pace actually *fits* in the time
     * left, and — when the projection rides on the window average rather than a
     * live measurement — where the number came from, so "on pace" can't be
     * misread as "right now".
     */
    val detail: String?
        get() {
            // "Room for 0.0%/hr" is not advice, so a spent window says the one
            // thing that is still actionable: the wait is finite.
            if (outlook == Outlook.AT_LIMIT) return "Nothing left until this window resets"
            val provenance = if (pace == Pace.AVERAGE) "Averaged over this window" else null
            val sustainable = sustainableRatePerHour
                ?: return if (outlook == Outlook.NO_WINDOW) {
                    "A new window opens with your next session"
                } else {
                    provenance
                }
            val room = when (outlook) {
                Outlook.REACHES_LIMIT ->
                    "Ease to ${TimeFormatting.rate(sustainable)} to last the window"
                Outlook.ON_PACE, Outlook.IDLE ->
                    "Room for ${TimeFormatting.rate(sustainable)} until reset"
                Outlook.AT_LIMIT -> return "Nothing left until this window resets"
                Outlook.NO_WINDOW -> return "A new window opens with your next session"
            }
            return provenance?.let { "$it · $room" } ?: room
        }

    /** Short status for a badge — the outlook in two words or fewer. */
    val badgeLabel: String
        get() = when (outlook) {
            Outlook.AT_LIMIT -> "At limit"
            Outlook.REACHES_LIMIT -> "At risk"
            Outlook.ON_PACE -> if (pace == Pace.AVERAGE) "Averaging" else "On pace"
            Outlook.IDLE -> if (isSessionActive) "Measuring" else "Idle"
            Outlook.NO_WINDOW -> "No window"
        }

    val symbol: Symbol
        get() = when (outlook) {
            Outlook.AT_LIMIT -> Symbol.AT_LIMIT
            Outlook.REACHES_LIMIT -> Symbol.AT_RISK
            // A flame is a claim about right now, so it's reserved for a
            // measured pace; a window average gets the trend line instead.
            Outlook.ON_PACE -> if (pace == Pace.AVERAGE) Symbol.TRENDING else Symbol.BURNING
            Outlook.IDLE -> if (isSessionActive) Symbol.MEASURING else Symbol.CALM
            Outlook.NO_WINDOW -> Symbol.NO_WINDOW
        }

    /** ARGB. Swift returns a `Color`; the palette values are identical. */
    val tintColor: Int
        get() = when (outlook) {
            Outlook.AT_LIMIT, Outlook.REACHES_LIMIT -> BatteryPalette.BRAND_DEEP
            Outlook.ON_PACE -> BatteryPalette.BRAND_DARK
            Outlook.IDLE -> BatteryPalette.BRAND
            // Swift returns `.secondary` here, a system grey, deliberately
            // distinct from IDLE's brand tint — "no window open" is not a calm
            // reading of the meter, it's the absence of one.
            Outlook.NO_WINDOW -> BatteryPalette.SECONDARY
        }

    /** The pace being projected from, or an em dash when there isn't one. */
    val rateText: String
        get() = if (burnRatePerHour > MINIMUM_RATE) TimeFormatting.rate(burnRatePerHour) else "—"

    /** Time until the limit, or an em dash when it isn't projected to arrive. */
    val timeToLimitText: String
        get() = secondsToLimit?.let { TimeFormatting.shortDuration(it) } ?: "—"

    /**
     * The "where does this land" stat for wide surfaces. Time-to-limit when 100%
     * actually arrives inside this window; otherwise the landing point, because
     * "To limit —" was the cell the app showed most often and it told the reader
     * nothing.
     */
    data class LandingStat(val label: String, val value: String, val isUrgent: Boolean)

    val landingStat: LandingStat
        get() = when (outlook) {
            Outlook.REACHES_LIMIT -> LandingStat("To limit", timeToLimitText, true)
            Outlook.AT_LIMIT ->
                LandingStat("To reset", TimeFormatting.shortDuration(secondsToReset), true)
            Outlook.NO_WINDOW -> LandingStat("At reset", "—", false)
            Outlook.ON_PACE, Outlook.IDLE ->
                LandingStat("At reset", "${TimeFormatting.percent(projectedAtReset)}%", false)
        }

    companion object {
        /**
         * Below this a "rate" is regression noise rather than a pace. Same gate
         * `UsagePayload.hasLiveProjection` uses.
         */
        const val MINIMUM_RATE = 0.05

        /**
         * The session window's fixed length. This is what makes the average pace
         * derivable from a single sample: the window opened `SESSION_WINDOW`
         * before it resets, so `now` has a known position inside it.
         */
        const val SESSION_WINDOW = 5 * 3600.0

        /**
         * How much of the window must have elapsed before its average means
         * anything. Dividing by the first ninety seconds turns 2% used into
         * "80%/hr", which would be a confident-looking lie.
         */
        const val MINIMUM_ELAPSED_FOR_AVERAGE = 12 * 60.0

        private fun secondsBetween(a: Instant, b: Instant): Double =
            (a.toEpochMilli() - b.toEpochMilli()) / 1000.0
    }
}
