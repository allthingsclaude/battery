package com.allthingsclaude.battery.core

import java.time.Instant
import kotlin.math.roundToLong

/**
 * Duration / relative-time helpers. A verbatim port of
 * `ios/BatteryKit/TimeFormatting.swift`, which is itself a verbatim port of the
 * macOS app — so all three platforms format time identically ("2h 13m", "45m",
 * "just now").
 *
 * Intervals are [Double] seconds rather than `kotlin.time.Duration` to keep the
 * port 1:1 with Swift's `TimeInterval` and to keep the shared golden fixtures
 * expressible as plain JSON numbers.
 */
object TimeFormatting {

    /**
     * Format an interval as a short duration. Examples: "2h 13m", "45m", "30s".
     *
     * Note the truncation, which must not be "improved" into rounding: Swift
     * does `Int(interval)`, so 119.9s is "1m", not "2m". A surface that rounded
     * up would tick to the next minute a second before the other two platforms.
     */
    fun shortDuration(interval: Double): String {
        if (interval <= 0) return "0s"

        val totalSeconds = interval.toLong()
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60

        return when {
            hours > 0 -> "${hours}h ${minutes}m"
            minutes > 0 -> "${minutes}m"
            seconds > 0 -> "${seconds}s"
            // Reachable only for 0 < interval < 1, where every field truncates
            // to zero. Swift has the same branch and the same wording.
            else -> "< 1m"
        }
    }

    /**
     * Time left until a window resets, or null when there is nothing to say.
     *
     * [shortDuration] is the wrong formatter to call directly here and must not
     * be changed to fix it — it is a cross-platform golden, pinned by
     * `fixtures/time-formatting.json` at `{"seconds": 86400, "expect": "24h 0m"}`.
     * It has hour, minute and second branches and no day branch, which is
     * correct for a five-hour session and absurd for a seven-day one: a weekly
     * window six days out renders "153h 0m", and nobody reads that as "about a
     * week". Every Apple surface branches before reaching it (`CountdownLabel`,
     * `BatteryDesign`, `WidgetCountdown`); Android had the formatter but never
     * ported the caller-side gate.
     *
     * Days are shown as `6d 9h` rather than iOS's absolute date. Deliberate:
     * a date needs a zone and a locale-appropriate format, which would make this
     * impure and unpinnable by the shared fixtures. The defect being fixed is
     * unreadability, and `6d 9h` is readable.
     *
     * Null below zero, because an expired window has no countdown — the caller
     * should drop the caption rather than render `shortDuration`'s "0s" clamp,
     * which reads as "resets right now" forever.
     */
    fun untilReset(interval: Double): String? {
        if (interval <= 0) return null
        val totalSeconds = interval.toLong()
        if (totalSeconds < DAY_SECONDS) return shortDuration(interval)
        val days = totalSeconds / DAY_SECONDS
        val hours = (totalSeconds % DAY_SECONDS) / 3600
        return "${days}d ${hours}h"
    }

    private const val DAY_SECONDS = 24 * 60 * 60L

    /** Format a past instant as relative time. Examples: "just now", "2m ago". */
    fun relativeTime(date: Instant, now: Instant = Instant.now()): String {
        val interval = (now.toEpochMilli() - date.toEpochMilli()) / 1000.0
        return when {
            interval < 60 -> "just now"
            interval < 3600 -> "${(interval / 60).toLong()}m ago"
            interval < 86_400 -> "${(interval / 3600).toLong()}h ago"
            else -> "${(interval / 86_400).toLong()}d ago"
        }
    }

    /** Whole percent, matching Swift's `Int(value.rounded())` (half away from zero). */
    fun percent(value: Double): String = value.roundToLong().toString()

    /**
     * "9.2%/hr" — one decimal, because whole numbers hide a doubling of pace at
     * the low end where it matters most.
     */
    fun rate(value: Double): String = String.format(java.util.Locale.US, "%.1f%%/hr", value)
}
