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

    // Opus 7-day window (null when the plan has no Opus access)
    val opusUtilization: Double? = null,

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

    /** Whichever window is closer to its ceiling — what a glanceable surface leads with. */
    val focusUtilization: Double get() = maxOf(sessionUtilization, weeklyUtilization)

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
