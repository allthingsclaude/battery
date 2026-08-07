package com.allthingsclaude.battery.core

import java.time.Instant
import kotlin.math.abs

/**
 * A point-in-time usage sample. On macOS these are persisted to SQLite; on the
 * phone a small ring buffer of them exists purely to feed the regression, so no
 * database is needed. Field set is the subset [BurnRateCalculator] reads.
 *
 * Port of `ios/BatteryKit/UsageSnapshot.swift`.
 */
data class UsageSnapshot(
    val timestamp: Instant,
    val sessionUtilization: Double,
    val sessionResetsAt: Instant,
)

/** A burn-rate projection derived from recent snapshots. */
data class BurnRateProjection(
    /** Percentage points per hour. */
    val currentRate: Double,
    /** When 100% is hit; null if flat or already maxed. */
    val projectedLimitTime: Instant?,
    /** Projected utilization at reset time. */
    val projectedAtReset: Double,
    val trend: Trend,
    val hasEnoughData: Boolean,
) {
    enum class Trend { INCREASING, STABLE, DECREASING }

    companion object {
        fun insufficientData(utilization: Double) = BurnRateProjection(
            currentRate = 0.0,
            projectedLimitTime = null,
            projectedAtReset = utilization,
            trend = Trend.STABLE,
            hasEnoughData = false,
        )
    }
}

/**
 * Linear-regression burn rate. Ported from `ios/BatteryKit/BurnRateCalculator.swift`,
 * which is itself a port of the macOS original — the arithmetic is identical on
 * all three platforms and `core/src/test/resources/fixtures/` exists to keep it
 * that way.
 */
object BurnRateCalculator {

    const val MINIMUM_SNAPSHOTS = 3

    /** Seconds. Below this the samples are too bunched for a slope to mean anything. */
    const val MINIMUM_TIME_SPAN = 120.0

    /**
     * Tolerance when matching a snapshot's window to the current one. A reset
     * time round-trips through JSON and can come back a hair off, so an exact
     * comparison would silently discard the entire history.
     */
    private const val RESET_MATCH_TOLERANCE_SECONDS = 1.0

    fun calculate(
        snapshots: List<UsageSnapshot>,
        currentUtilization: Double,
        resetsAt: Instant,
        now: Instant = Instant.now(),
    ): BurnRateProjection {
        // Only samples belonging to the current session window: a reset changes
        // `sessionResetsAt`, and mixing windows would regress across the
        // discontinuity and report a wildly negative or positive pace.
        val currentSession = snapshots.filter {
            abs(secondsBetween(it.sessionResetsAt, resetsAt)) < RESET_MATCH_TOLERANCE_SECONDS
        }

        if (currentSession.size < MINIMUM_SNAPSHOTS) {
            return BurnRateProjection.insufficientData(currentUtilization)
        }

        val sorted = currentSession.sortedBy { it.timestamp }
        val timeSpan = secondsBetween(sorted.last().timestamp, sorted.first().timestamp)
        if (timeSpan < MINIMUM_TIME_SPAN) {
            return BurnRateProjection.insufficientData(currentUtilization)
        }

        val origin = sorted.first().timestamp.toEpochMilli() / 1000.0
        val n = sorted.size.toDouble()
        var sumX = 0.0; var sumY = 0.0; var sumXY = 0.0; var sumX2 = 0.0
        for (s in sorted) {
            val x = (s.timestamp.toEpochMilli() / 1000.0 - origin) / 3600.0 // hours
            val y = s.sessionUtilization
            sumX += x; sumY += y; sumXY += x * y; sumX2 += x * x
        }

        val denominator = n * sumX2 - sumX * sumX
        if (abs(denominator) <= 1e-10) {
            return BurnRateProjection.insufficientData(currentUtilization)
        }

        // Within a session, utilization only rises — clamp regression noise (and
        // a genuine post-reset drop that slipped the window filter) to zero
        // rather than reporting a negative pace nothing downstream can use.
        val slope = maxOf(0.0, (n * sumXY - sumX * sumY) / denominator)
        val trend = if (slope > 1.0) BurnRateProjection.Trend.INCREASING else BurnRateProjection.Trend.STABLE

        var projectedLimitTime: Instant? = null
        if (slope > 0.01 && currentUtilization < 100) {
            val hoursToLimit = (100.0 - currentUtilization) / slope
            projectedLimitTime = now.plusMillis((hoursToLimit * 3600 * 1000).toLong())
        }

        val hoursToReset = maxOf(0.0, secondsBetween(resetsAt, now) / 3600.0)
        val projectedAtReset = (currentUtilization + slope * hoursToReset).coerceIn(0.0, 100.0)

        return BurnRateProjection(
            currentRate = slope,
            projectedLimitTime = projectedLimitTime,
            projectedAtReset = projectedAtReset,
            trend = trend,
            hasEnoughData = true,
        )
    }

    private fun secondsBetween(a: Instant, b: Instant): Double =
        (a.toEpochMilli() - b.toEpochMilli()) / 1000.0
}
