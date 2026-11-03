package com.allthingsclaude.battery.core

import java.time.Duration
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The cases that matter are the ones where it must decline to answer.
 *
 * A wrong pick here does not show as a wrong tap — it shows as the right-looking
 * quota for the wrong account, which is the one thing a usage display must never
 * do. So "no opinion" has to be reachable and has to mean *change nothing*.
 */
class ActiveAccountTest {

    private val now: Instant = Instant.parse("2026-01-01T12:00:00Z")

    private fun minutesAgo(n: Long) = now.minus(Duration.ofMinutes(n))

    @Test
    fun `picks the most recently active account`() {
        val picked = ActiveAccount.pick(
            mapOf("work" to minutesAgo(20), "personal" to minutesAgo(3)),
            now,
        )
        assertEquals("personal", picked)
    }

    @Test
    fun `no opinion when everything is stale`() {
        // An idle evening must not drag the selection onto whichever account
        // happened to be used last week.
        assertNull(
            ActiveAccount.pick(
                mapOf("work" to minutesAgo(400), "personal" to minutesAgo(90)),
                now,
            )
        )
    }

    @Test
    fun `no opinion when there is nothing to go on`() {
        assertNull(ActiveAccount.pick(emptyMap(), now))
    }

    @Test
    fun `ignores stale accounts but still picks a fresh one`() {
        val picked = ActiveAccount.pick(
            mapOf("old" to minutesAgo(300), "fresh" to minutesAgo(2)),
            now,
        )
        assertEquals("fresh", picked)
    }

    @Test
    fun `a tie is stable rather than alternating`() {
        val same = minutesAgo(5)
        val first = ActiveAccount.pick(mapOf("b" to same, "a" to same), now)
        val second = ActiveAccount.pick(mapOf("a" to same, "b" to same), now)
        assertEquals(first, second)
        assertEquals("a", first)
    }

    @Test
    fun `the window is honoured exactly`() {
        // Precisely at the boundary counts as stale — the comparison is strictly
        // after the cutoff, so a value sitting on it cannot flicker in and out.
        assertNull(ActiveAccount.pick(mapOf("work" to minutesAgo(30)), now, Duration.ofMinutes(30)))
        assertEquals(
            "work",
            ActiveAccount.pick(mapOf("work" to minutesAgo(29)), now, Duration.ofMinutes(30)),
        )
    }
}
