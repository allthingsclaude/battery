package com.allthingsclaude.battery.core

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The shared snapshot buffer.
 *
 * Worth its own suite now that two different questions read it: the burn-rate
 * regression, and "is the user working right now". The second used to be
 * answered from in-memory fields on whichever object happened to be polling,
 * which is exactly the per-process history the iOS port set out to eliminate.
 */
class SessionHistoryTest {

    private val now: Instant = Instant.parse("2026-01-01T12:00:00Z")
    private val resetsAt: Instant = now.plusSeconds(3600)

    private fun history(vararg samples: Pair<Long, Double>): SessionHistory {
        val store = InMemorySnapshotStore(
            samples.map { (offset, utilization) ->
                UsageSnapshot(now.plusSeconds(offset), utilization, resetsAt)
            }
        )
        return SessionHistory(store)
    }

    // ── Activity inference ──────────────────────────────────────────────────

    @Test
    fun `a rising session reports its most recent rise`() {
        val h = history(-600L to 2.0, -300L to 4.0, 0L to 7.0)
        assertEquals(now, h.lastRiseAt(resetsAt))
    }

    @Test
    fun `a flat session has never risen`() {
        val h = history(-600L to 9.0, -300L to 9.0, 0L to 9.0)
        assertNull(h.lastRiseAt(resetsAt))
    }

    @Test
    fun `a session that rose and then went quiet keeps the older timestamp`() {
        // This is what makes the ten-minute activity window mean anything: the
        // answer has to age, not disappear the moment usage plateaus.
        val h = history(-900L to 4.0, -600L to 6.0, -300L to 6.0, 0L to 6.0)
        assertEquals(now.minusSeconds(600), h.lastRiseAt(resetsAt))
    }

    @Test
    fun `a single sample cannot establish a rise`() {
        assertNull(history(0L to 12.0).lastRiseAt(resetsAt))
    }

    @Test
    fun `decimal jitter is not activity`() {
        // A percentage wobbling in its last decimal place would otherwise read
        // as continuous work and hold a foreground service open indefinitely.
        val h = history(-600L to 9.0, -300L to 9.001, 0L to 9.002)
        assertNull(h.lastRiseAt(resetsAt))
    }

    @Test
    fun `samples from a previous window are ignored`() {
        val store = InMemorySnapshotStore(
            listOf(
                // Yesterday's window, climbing hard.
                UsageSnapshot(now.minusSeconds(300), 40.0, resetsAt.minusSeconds(86_400)),
                UsageSnapshot(now.minusSeconds(60), 80.0, resetsAt.minusSeconds(86_400)),
                // This one, flat.
                UsageSnapshot(now, 3.0, resetsAt),
            )
        )
        assertNull(SessionHistory(store).lastRiseAt(resetsAt))
    }

    @Test
    fun `no open window means no activity`() {
        assertNull(history(-300L to 4.0, 0L to 8.0).lastRiseAt(null))
    }

    @Test
    fun `unsorted storage still yields the latest rise`() {
        // The buffer is sorted on write, but nothing in the type system says a
        // store must hand it back in order.
        val store = InMemorySnapshotStore(
            listOf(
                UsageSnapshot(now, 7.0, resetsAt),
                UsageSnapshot(now.minusSeconds(600), 2.0, resetsAt),
                UsageSnapshot(now.minusSeconds(300), 4.0, resetsAt),
            )
        )
        assertEquals(now, SessionHistory(store).lastRiseAt(resetsAt))
    }

    // ── Recording ───────────────────────────────────────────────────────────

    @Test
    fun `a recorded sample is immediately visible as a rise`() {
        // The repository records and then asks, in that order, so the sample it
        // just wrote has to count.
        val store = InMemorySnapshotStore(
            listOf(UsageSnapshot(now.minusSeconds(300), 3.0, resetsAt))
        )
        val h = SessionHistory(store)
        h.record(5.0, resetsAt, now)
        assertEquals(now, h.lastRiseAt(resetsAt))
    }

    @Test
    fun `closing the window drops the buffer`() {
        val store = InMemorySnapshotStore(
            listOf(UsageSnapshot(now.minusSeconds(300), 3.0, resetsAt))
        )
        SessionHistory(store).record(0.0, resetsAt = null, now = now)
        assertTrue(store.load().isEmpty())
    }

    @Test
    fun `the buffer is bounded`() {
        val store = InMemorySnapshotStore()
        val h = SessionHistory(store)
        repeat(SessionHistory.CAPACITY + 10) { i ->
            h.record(i.toDouble(), resetsAt, now.plusSeconds(i * 60L))
        }
        assertEquals(SessionHistory.CAPACITY, store.load().size)
    }
}

/**
 * The pace mark — how far the clock has run through the session window.
 *
 * Its whole value is being comparable to `sessionUtilization`, so the cases that
 * matter are the ones where it could lie: no window, a window longer than the
 * five hours we assume, and a reset time already in the past.
 */
class ElapsedPercentTest {

    private val now: Instant = Instant.parse("2026-01-01T12:00:00Z")

    private fun payload(remainingSeconds: Long?) = UsagePayload(
        sessionUtilization = 20.0,
        sessionResetsAt = remainingSeconds?.let { now.plusSeconds(it) },
        weeklyUtilization = 30.0,
        weeklyResetsAt = now.plusSeconds(86_400),
        updatedAt = now,
    )

    @Test
    fun `a fresh window has barely elapsed`() {
        assertEquals(0, payload(UsagePayload.SESSION_WINDOW_SECONDS).elapsedPercent(now))
    }

    @Test
    fun `halfway through reads fifty`() {
        assertEquals(50, payload(UsagePayload.SESSION_WINDOW_SECONDS / 2).elapsedPercent(now))
    }

    @Test
    fun `the last minutes read near a hundred`() {
        assertEquals(98, payload(5 * 60).elapsedPercent(now))
    }

    @Test
    fun `a window that just expired reads a hundred`() {
        assertEquals(100, payload(0).elapsedPercent(now))
    }

    @Test
    fun `no open window has no mark`() {
        assertNull(payload(null).elapsedPercent(now))
    }

    @Test
    fun `a reset already in the past has no mark`() {
        // Not clamped to 100: a negative remaining means the payload is stale or
        // the clocks disagree, and a mark pinned to the end would assert
        // something about a window we are no longer watching.
        assertNull(payload(-60).elapsedPercent(now))
    }

    @Test
    fun `a window longer than the one we assume has no mark`() {
        // The API never states the window length. If it is ever not five hours,
        // every mark this produces is wrong by an unknown amount — so say
        // nothing rather than draw a confident line in the wrong place.
        assertNull(payload(UsagePayload.SESSION_WINDOW_SECONDS + 60).elapsedPercent(now))
    }

    @Test
    fun `it never leaves the bar`() {
        for (remaining in 0..UsagePayload.SESSION_WINDOW_SECONDS step 137) {
            val mark = payload(remaining).elapsedPercent(now)
            assertNotNull(mark)
            assertTrue(mark in 0..100, "elapsed $mark% is off the bar")
        }
    }
}

/**
 * `untilReset` — the caller-side gate Android never ported from the Apple apps.
 */
class UntilResetTest {

    @Test
    fun `a session window uses the shared short form`() {
        assertEquals("2h 13m", TimeFormatting.untilReset(2.0 * 3600 + 13 * 60))
        assertEquals("47m", TimeFormatting.untilReset(47.0 * 60))
    }

    @Test
    fun `a weekly window reads in days, not in three-digit hours`() {
        // The defect: shortDuration has no day branch, so a weekly reset six
        // days out rendered "153h 0m" — a number nobody parses as "about a
        // week", and one iOS never shows.
        assertEquals("6d 9h", TimeFormatting.untilReset(6.0 * 86_400 + 9 * 3600))
        assertEquals("7d 0h", TimeFormatting.untilReset(7.0 * 86_400))
    }

    @Test
    fun `the boundary belongs to the day form`() {
        // shortDuration(86400) is pinned to "24h 0m" by the shared fixtures and
        // must keep returning that; the gate is what changes, not the formatter.
        assertEquals("1d 0h", TimeFormatting.untilReset(86_400.0))
        assertEquals("23h 59m", TimeFormatting.untilReset(86_400.0 - 60))
        assertEquals("24h 0m", TimeFormatting.shortDuration(86_400.0))
    }

    @Test
    fun `an expired window has no countdown`() {
        // Not "0s". shortDuration clamps non-positive intervals, so a stored
        // payload whose window has passed rendered "resets in 0s" indefinitely
        // off purely local state — on any system-driven widget rebuild.
        assertNull(TimeFormatting.untilReset(0.0))
        assertNull(TimeFormatting.untilReset(-1.0))
        assertNull(TimeFormatting.untilReset(-99_999.0))
    }
}

/**
 * The two things a live response taught us that the client had wrong.
 *
 * Both bodies below are trimmed from an actual `/api/oauth/usage` and
 * `/api/oauth/profile` response, so these are regression tests against reality
 * rather than against an assumed schema.
 */
class ApiShapeTest {

    @Test
    fun `the model-scoped weekly comes from limits, and names its model`() {
        // seven_day_opus is null while limits[] carries a weekly_scoped entry
        // scoped to Fable. Reading only the flat key shows an empty Opus row
        // forever and never mentions the model that is actually limited.
        val body = """
            {"five_hour":{"utilization":3.0,"resets_at":null},
             "seven_day":{"utilization":34.0,"resets_at":null},
             "seven_day_opus":null,
             "limits":[
               {"kind":"session","group":"session","percent":3,"scope":null},
               {"kind":"weekly_all","group":"weekly","percent":34,"scope":null},
               {"kind":"weekly_scoped","group":"weekly","percent":7,
                "scope":{"model":{"id":null,"display_name":"Fable"}}}]}
        """.trimIndent()

        val scoped = UsageApi.parseUsage(body).scopedWeekly
        assertNotNull(scoped)
        assertEquals("Fable", scoped.label)
        assertEquals(7.0, scoped.utilization)
    }

    @Test
    fun `an older response still works through the flat key`() {
        val body = """
            {"five_hour":{"utilization":3.0,"resets_at":null},
             "seven_day":{"utilization":34.0,"resets_at":null},
             "seven_day_opus":{"utilization":21.0,"resets_at":null}}
        """.trimIndent()

        val scoped = UsageApi.parseUsage(body).scopedWeekly
        assertNotNull(scoped)
        assertEquals("Opus", scoped.label)
        assertEquals(21.0, scoped.utilization)
    }

    @Test
    fun `a scoped entry with no model name is ignored`() {
        // A bare percentage under no heading says nothing about what is limited.
        val body = """
            {"seven_day":{"utilization":34.0,"resets_at":null},
             "limits":[{"kind":"weekly_scoped","group":"weekly","percent":7,"scope":null}]}
        """.trimIndent()
        assertNull(UsageApi.parseUsage(body).scopedWeekly)
    }

    @Test
    fun `the plan tier is read from the profile, and 20x is not plain Max`() {
        // The live value. A contains("max") check ranks it as "Max", which is a
        // different and cheaper plan — the narrower tiers must be tested first.
        val body = """
            {"account":{"email":"a@b.c","full_name":"Ivan"},
             "organization":{"rate_limit_tier":"default_claude_max_20x"}}
        """.trimIndent()
        val profile = ProfileApi.parse(body)
        assertNotNull(profile)
        assertEquals("default_claude_max_20x", profile.rateLimitTier)
        assertEquals("Max 20x", profile.planLabel)
    }

    @Test
    fun `every tier maps to something a reader recognises`() {
        fun label(tier: String) = ProfileApi.Profile(null, "x", tier).planLabel
        assertEquals("Max 20x", label("default_claude_max_20x"))
        assertEquals("Max 5x", label("default_claude_max_5x"))
        assertEquals("Max", label("claude_max"))
        assertEquals("Pro", label("default_claude_pro"))
        assertEquals("", label("something_unreleased"))
        assertEquals("", ProfileApi.Profile(null, "x", null).planLabel)
    }

    @Test
    fun `a profile without an organization still yields a label`() {
        // The plan is a nicety; the account name is not. Losing one must not
        // cost the other.
        val profile = ProfileApi.parse("""{"account":{"email":"a@b.c"}}""")
        assertNotNull(profile)
        assertEquals("a@b.c", profile.label)
        assertEquals("", profile.planLabel)
    }
}

/**
 * Pay-as-you-go credits.
 *
 * The scale is the whole risk here: the API sends minor units, so reading them
 * as major renders a hundred-fold overcharge.
 */
class ExtraUsageTest {

    private val live = """
        {"seven_day":{"utilization":34.0,"resets_at":null},
         "extra_usage":{"is_enabled":true,"monthly_limit":4000,"used_credits":2080.0,
                        "utilization":52.0,"currency":"USD","decimal_places":2}}
    """.trimIndent()

    @Test
    fun `minor units become money`() {
        val e = UsageApi.parseUsage(live).extraUsage
        assertNotNull(e)
        assertEquals(20.80, e.used!!, 0.001)
        assertEquals(40.00, e.limit!!, 0.001)
        assertEquals(19.20, e.remaining!!, 0.001)
        assertEquals("$20.80", e.format(e.used))
        assertEquals("$40.00", e.format(e.limit))
    }

    @Test
    fun `a currency without a symbol falls back to its code`() {
        val e = ExtraUsage(true, 2080.0, 4000.0, 52.0, "CHF", 2)
        assertEquals("20.80 CHF", e.format(e.used))
    }

    @Test
    fun `decimal places drive the scale, they are not assumed`() {
        // A zero-decimal currency (JPY) would otherwise be divided by 100.
        val e = ExtraUsage(true, 2080.0, 4000.0, 52.0, "JPY", 0)
        assertEquals(2080.0, e.used!!, 0.001)
        assertEquals("2080 JPY", e.format(e.used))
    }

    @Test
    fun `spent past the limit never shows negative remaining`() {
        val e = ExtraUsage(true, 5000.0, 4000.0, 125.0, "USD", 2)
        assertEquals(0.0, e.remaining!!, 0.001)
    }

    @Test
    fun `nothing is presentable without a limit to measure against`() {
        assertEquals(false, ExtraUsage(true, 2080.0, null, 52.0, "USD", 2).isPresentable)
        assertEquals(false, ExtraUsage(true, 2080.0, 0.0, 52.0, "USD", 2).isPresentable)
        assertEquals(false, ExtraUsage(false, 2080.0, 4000.0, 52.0, "USD", 2).isPresentable)
        assertEquals(true, ExtraUsage(true, 2080.0, 4000.0, 52.0, "USD", 2).isPresentable)
    }

    @Test
    fun `an account with no credits has no block at all`() {
        val body = """{"seven_day":{"utilization":34.0,"resets_at":null}}"""
        assertNull(UsageApi.parseUsage(body).extraUsage)
    }
}
