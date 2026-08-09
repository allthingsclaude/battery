package com.allthingsclaude.battery.core

import java.time.Instant

/**
 * The single, fully-baked snapshot the app writes and every read-only surface
 * (the Live Update, widgets) consumes.
 *
 * A port of `ios/BatteryKit/UsagePayload.swift`, and it carries the same design
 * rule across: **the app computes, the surfaces present.** Everything a widget or
 * the Now Bar card needs to render is precomputed here — including the burn rate
 * and the projected-limit time — so no surface ever touches the network, the
 * regression, or storage.
 *
 * Dates are [Instant] rather than epoch millis because this module is JVM-only
 * and nothing writes this type from off-platform. (The iOS `ContentState` has a
 * hand-written Codable pinning Unix epoch seconds precisely because a Cloudflare
 * Worker writes that JSON too — that constraint arrives here only if the deferred
 * FCM relay lands.)
 */
data class UsagePayload(
    // Session (5-hour) window
    val sessionUtilization: Double,
    val sessionResetsAt: Instant?,

    // Weekly (7-day) window
    val weeklyUtilization: Double,
    val weeklyResetsAt: Instant?,

    // The model-scoped 7-day window, null when the plan has none.
    val opusUtilization: Double? = null,
    /**
     * What that scoped window is scoped *to* — "Opus", "Fable", whatever the
     * API reports next. Read from `scope.model.display_name` rather than
     * hardcoded, because the app shipped a literal "Opus" heading and the live
     * answer is now "Fable". A label baked into a client is a guess with an
     * expiry date; the field name below is kept only to avoid rewriting a
     * stored-payload key for a rename.
     */
    val scopedLabel: String = "",

    /**
     * Pay-as-you-go credits, null when the account has none enabled.
     *
     * Carried on the payload rather than fetched per surface for the same
     * reason as everything else here: the app computes, the surfaces present.
     */
    val extraUsage: ExtraUsage? = null,

    // Precomputed burn-rate projection (see BurnRateCalculator — Phase 1)
    /** Percentage points per hour; 0 when unknown. */
    val burnRatePerHour: Double = 0.0,
    /** When 100% is reached; null when not projected. */
    val projectedLimitAt: Instant? = null,

    // Context
    /** A coding session is actively burning tokens right now. */
    val isSessionActive: Boolean = false,
    /** "Pro" / "Max" / "Max 5x" / "" when unknown. */
    val planTier: String = "",
    val accountName: String = "Account 1",
    val isConnected: Boolean = true,
    val updatedAt: Instant = Instant.now(),
) {
    val sessionLevel: UsageLevel get() = UsageLevel.from(sessionUtilization)
    val weeklyLevel: UsageLevel get() = UsageLevel.from(weeklyUtilization)

    /**
     * Heading for the model-scoped weekly row.
     *
     * Falls back to "Opus" only for payloads stored before the label existed —
     * those were written when the row could only ever have been Opus, so that is
     * what they meant. Anything fetched since carries the API's own answer.
     */
    val scopedTitle: String get() = scopedLabel.ifEmpty { "Opus" }

    /** Whichever window is closer to its ceiling — what a glanceable surface leads with. */
    val focusUtilization: Double get() = maxOf(sessionUtilization, weeklyUtilization)

    /**
     * How far the *clock* has run through the five-hour window, 0–100. Null when
     * no window is open, or when it cannot be computed honestly.
     *
     * This is the budget line to compare [sessionUtilization] against: usage
     * behind it means the window is being spent slower than the clock, ahead of
     * it means faster. No other figure the app shows says that — the burn rate
     * answers "how fast", the projection answers "where will it land", neither
     * answers "am I ahead or behind right now".
     *
     * The window length has to be assumed rather than read, because the API only
     * reports when the window *ends*. macOS assumes the same five hours in
     * `UsageViewModel.menuBarText` (`18000 - remaining`, with the same comment),
     * so at least the two agree.
     *
     * Returning null rather than clamping when `remaining` exceeds the window is
     * deliberate: that means the assumption is wrong for this account, or the
     * device clock disagrees with the server's, and in either case an invented
     * mark is worse than no mark.
     */
    fun elapsedPercent(now: Instant = Instant.now()): Int? {
        val resetsAt = sessionResetsAt ?: return null
        val remaining = resetsAt.epochSecond - now.epochSecond
        if (remaining < 0 || remaining > SESSION_WINDOW_SECONDS) return null
        val elapsed = SESSION_WINDOW_SECONDS - remaining
        return ((elapsed * 100.0) / SESSION_WINDOW_SECONDS).toInt().coerceIn(0, 100)
    }

    /**
     * Which window a tight surface should lead with. Ported from iOS, where the
     * comment reads "whichever window is closer to its ceiling — what a 'smart'
     * surface leads with".
     *
     * Ties go to the session: it is the faster-moving of the two and the one a
     * reader can still act on.
     */
    val focusWindow: FocusWindow
        get() = if (weeklyUtilization > sessionUtilization) FocusWindow.WEEKLY else FocusWindow.SESSION

    enum class FocusWindow { SESSION, WEEKLY }

    /**
     * A projection is only meaningful while it's still in the future and we have a
     * burn rate. Carried-forward payloads can hold a `projectedLimitAt` that has
     * since passed — surfacing it would render nonsense like "hits limit in 0s".
     */
    fun hasLiveProjection(now: Instant = Instant.now()): Boolean {
        val limit = projectedLimitAt ?: return false
        return burnRatePerHour > 0.05 && limit.isAfter(now)
    }

    fun liveProjectedLimitAt(now: Instant = Instant.now()): Instant? =
        if (hasLiveProjection(now)) projectedLimitAt else null

    fun sessionSecondsRemaining(now: Instant = Instant.now()): Long =
        sessionResetsAt?.let { maxOf(0L, it.epochSecond - now.epochSecond) } ?: 0L

    companion object {
        /**
         * The session window, in seconds. The API reports only when a window
         * ends, never how long it is, so anything asking "how far through are
         * we" has to assume — and macOS assumes the same 18000 in
         * `UsageViewModel.menuBarText`.
         */
        const val SESSION_WINDOW_SECONDS = 5L * 60 * 60

        /**
         * A neutral stand-in for surfaces that must render before any real data
         * exists — the widget picker's preview, Compose `@Preview`s, and the
         * Phase 0 Now Bar spike.
         *
         * This is not test scaffolding: iOS ships the identical constant
         * (`UsagePayload.placeholder`, `ios/BatteryKit/UsagePayload.swift:66`) and
         * wires it into `UsageProvider.placeholder()` and the `context.isPreview`
         * branch of `getSnapshot`. A widget that has never been given data still
         * has to draw something, and inventing numbers at each call site is how
         * the surfaces start disagreeing.
         *
         * `opusUtilization` stays null on purpose — most accounts have no Opus
         * bucket, and a preview shouldn't imply one.
         */
        /**
         * A payload that claims nothing.
         *
         * For the one moment a surface must render before any data exists: a
         * foreground service has a few seconds to call `startForeground` or the
         * system kills it, so it *must* post something on a fresh install whose
         * first poll has not returned. [PLACEHOLDER] is the wrong thing to post
         * there — it is demo data, and 87% with a live countdown and a "Max 5x"
         * badge is indistinguishable from a real reading on a lock screen. This
         * one is distinguishable: zeros, no window, no plan.
         */
        val EMPTY: UsagePayload
            get() = UsagePayload(
                sessionUtilization = 0.0,
                sessionResetsAt = null,
                weeklyUtilization = 0.0,
                weeklyResetsAt = null,
                opusUtilization = null,
                burnRatePerHour = 0.0,
                projectedLimitAt = null,
                isSessionActive = false,
                planTier = "",
                accountName = "",
                isConnected = false,
                updatedAt = Instant.now(),
            )

        val PLACEHOLDER: UsagePayload
            get() = UsagePayload(
                sessionUtilization = 87.0,
                sessionResetsAt = Instant.now().plusSeconds(2 * 3600 + 13 * 60),
                weeklyUtilization = 63.0,
                weeklyResetsAt = Instant.now().plusSeconds(3 * 86_400),
                opusUtilization = null,
                burnRatePerHour = 9.2,
                projectedLimitAt = Instant.now().plusSeconds(42 * 60),
                isSessionActive = true,
                planTier = "Max 5x",
                accountName = "Account 1",
                isConnected = true,
                updatedAt = Instant.now(),
            )
    }
}
