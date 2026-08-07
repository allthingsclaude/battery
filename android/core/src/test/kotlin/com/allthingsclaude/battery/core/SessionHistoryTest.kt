package com.allthingsclaude.battery.core

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
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
