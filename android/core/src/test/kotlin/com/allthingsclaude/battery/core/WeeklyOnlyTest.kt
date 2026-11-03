package com.allthingsclaude.battery.core

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Accounts with no five-hour limit — verified Ultra, the plan sold as Max 20x
 * until 2026-10-30.
 *
 * The usage API answers for them with `"five_hour": null`, and the weekly window
 * becomes the primary one: the number every surface leads with, the window the
 * forecast projects and the card follows. These cases pin the payload helpers
 * that make that switch, and the forecast fed through them — same arithmetic as
 * a session, over a window 33.6 times longer, in words that say "week".
 */
class WeeklyOnlyTest {

    private val now: Instant = Instant.parse("2026-01-01T12:00:00Z")

    private fun weeklyOnly(
        weekly: Double,
        resetsInSeconds: Long? = 3 * 86_400L,
        burnRatePerHour: Double = 0.0,
        projectedLimitInSeconds: Long? = null,
        active: Boolean = false,
    ) = UsagePayload(
        sessionUtilization = 0.0,
        sessionResetsAt = null,
        weeklyUtilization = weekly,
        weeklyResetsAt = resetsInSeconds?.let { now.plusSeconds(it) },
        hasSessionLimit = false,
        burnRatePerHour = burnRatePerHour,
        projectedLimitAt = projectedLimitInSeconds?.let { now.plusSeconds(it) },
        isSessionActive = active,
        updatedAt = now,
    )

    // ── The primary window ──────────────────────────────────────────────────

    @Test
    fun `the weekly window is primary when there is no session limit`() {
        val payload = weeklyOnly(41.0)
        assertEquals(UsagePayload.FocusWindow.WEEKLY, payload.primaryWindow)
        assertEquals(41.0, payload.primaryUtilization)
        assertEquals(payload.weeklyResetsAt, payload.primaryResetsAt)
        assertEquals(UsageLevel.LOW, payload.primaryLevel)
        assertEquals(3 * 86_400L, payload.primarySecondsRemaining(now))
    }

    @Test
    fun `an account with a session limit is unchanged`() {
        // The default, and what every payload stored before this existed means.
        val payload = UsagePayload(
            sessionUtilization = 80.0,
            sessionResetsAt = now.plusSeconds(3600),
            weeklyUtilization = 41.0,
            weeklyResetsAt = now.plusSeconds(86_400),
            updatedAt = now,
        )
        assertTrue(payload.hasSessionLimit)
        assertEquals(UsagePayload.FocusWindow.SESSION, payload.primaryWindow)
        assertEquals(80.0, payload.primaryUtilization)
        assertEquals(payload.sessionResetsAt, payload.primaryResetsAt)
        assertEquals(UsageLevel.HIGH, payload.primaryLevel)
    }

    @Test
    fun `the pace mark measures the week`() {
        assertEquals(50, weeklyOnly(30.0, resetsInSeconds = 302_400).elapsedPercent(now))
        assertEquals(0, weeklyOnly(30.0, resetsInSeconds = 604_800).elapsedPercent(now))
        // Longer than the week we assume: say nothing rather than mark wrongly.
        assertNull(weeklyOnly(30.0, resetsInSeconds = 604_800 + 60).elapsedPercent(now))
    }

    // ── The forecast ────────────────────────────────────────────────────────

    @Test
    fun `the forecast describes the week`() {
        val forecast = UsageForecast(weeklyOnly(41.0), now = now)
        assertTrue(forecast.isWeekly)
        assertEquals(41.0, forecast.utilization)
        assertEquals(now.plusSeconds(3 * 86_400L), forecast.resetsAt)
    }

    @Test
    fun `a spent week counts down in days`() {
        // 3d 4h = 273600s. shortDuration would read "76h 0m".
        val forecast = UsageForecast(weeklyOnly(100.0, resetsInSeconds = 273_600), now = now)
        assertEquals(UsageForecast.Outlook.AT_LIMIT, forecast.outlook)
        assertEquals("Limit reached · resets in 3d 4h", forecast.headline)
        assertEquals("Nothing left until the weekly reset", forecast.detail)
        assertEquals(UsageForecast.LandingStat("To reset", "3d 4h", true), forecast.landingStat)
    }

    @Test
    fun `a measured weekly pace projects the limit in days`() {
        // 60% used at 1.0%/hr: 100% in 40h = 1d 16h, inside the 72h left.
        // Room: 40 points over 72h = 0.555…%/hr → "0.6%/hr".
        val forecast = UsageForecast(
            weeklyOnly(
                60.0,
                resetsInSeconds = 3 * 86_400L,
                burnRatePerHour = 1.0,
                projectedLimitInSeconds = 40 * 3600L,
            ),
            now = now,
        )
        assertEquals(UsageForecast.Outlook.REACHES_LIMIT, forecast.outlook)
        assertEquals(UsageForecast.Pace.MEASURED, forecast.pace)
        assertEquals("Hits 100% in 1d 16h", forecast.headline)
        assertEquals("Ease to 0.6%/hr to last the week", forecast.detail)
        assertEquals(UsageForecast.LandingStat("To limit", "1d 16h", true), forecast.landingStat)
    }

    @Test
    fun `the average pace is spread over the week, not five hours`() {
        // 3.5 days left of 7, so 84h elapsed: 30 / 84 = 0.357%/hr, landing at
        // 30 + 0.357 × 84 = 60% at reset. Against an assumed five-hour window
        // the elapsed time would clamp to zero and there would be
        // no average at all. Room: 70 / 84 = 0.83 → "0.8%/hr".
        val forecast = UsageForecast(weeklyOnly(30.0, resetsInSeconds = 302_400), now = now)
        assertEquals(UsageForecast.Pace.AVERAGE, forecast.pace)
        assertEquals(UsageForecast.Outlook.ON_PACE, forecast.outlook)
        assertEquals("On pace for 60% at reset", forecast.headline)
        assertEquals("Averaged over this week · Room for 0.8%/hr until reset", forecast.detail)
        assertEquals("Averaging", forecast.badgeLabel)
    }

    @Test
    fun `the minimum elapsed time scales with the window`() {
        // One hour into a week, 1% used. With the session's twelve-minute floor
        // this would average to 1%/hr and announce "Hits 100% in 4d 3h" — a
        // week's projection drawn from its first hour. Scaled to the same 4% of
        // the window (~6.7h), it waits.
        val forecast = UsageForecast(weeklyOnly(1.0, resetsInSeconds = 604_800 - 3600), now = now)
        assertEquals(UsageForecast.Pace.NONE, forecast.pace)
        assertEquals(UsageForecast.Outlook.IDLE, forecast.outlook)
        assertEquals("99% left this week", forecast.headline)
    }

    @Test
    fun `an unused week says so`() {
        val forecast = UsageForecast(weeklyOnly(0.0), now = now)
        assertEquals("Nothing used yet this week", forecast.headline)
    }

    @Test
    fun `no weekly window says weekly, not session`() {
        val forecast = UsageForecast(weeklyOnly(0.0, resetsInSeconds = null), now = now)
        assertEquals(UsageForecast.Outlook.NO_WINDOW, forecast.outlook)
        assertEquals("No weekly window open", forecast.headline)
        assertEquals("The weekly window opens with your next session", forecast.detail)
    }

    // ── Durations ───────────────────────────────────────────────────────────

    @Test
    fun `longDuration matches shortDuration below a day and reads in days above it`() {
        // Below a day it must be byte-identical, or every session string the
        // shared fixtures pin would drift.
        for (seconds in listOf(0.0, 0.5, 30.0, 47.0 * 60, 2.0 * 3600 + 13 * 60, 86_400.0 - 1)) {
            assertEquals(TimeFormatting.shortDuration(seconds), TimeFormatting.longDuration(seconds))
        }
        assertEquals("1d 16h", TimeFormatting.longDuration(40.0 * 3600))
        assertEquals("6d 23h", TimeFormatting.longDuration(7.0 * 86_400 - 1))
        // The cases the Swift suite pins (WeeklyOnlyPlanTests): hours truncate
        // like everywhere else, and a whole number of days has no "0h" tail.
        assertEquals("4d 2h", TimeFormatting.longDuration(4.0 * 86_400 + 2 * 3600 + 59 * 60))
        assertEquals("1d", TimeFormatting.longDuration(86_400.0))
        assertEquals("4d", TimeFormatting.longDuration(4.0 * 86_400 + 59 * 60))
        assertEquals("23h 59m", TimeFormatting.longDuration(23.0 * 3600 + 59 * 60))
        assertEquals("45m", TimeFormatting.longDuration(45.0 * 60))
        assertEquals("0s", TimeFormatting.longDuration(0.0))
    }
}
