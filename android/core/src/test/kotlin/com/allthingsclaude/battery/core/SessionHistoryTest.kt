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
