package com.allthingsclaude.battery.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The macOS original (`Sources/Services/UsagePollingService.swift`) has none of
 * this — its backoff is private state on an ObservableObject driven by a live
 * timer, so the arithmetic that matters is untested there.
 */
class PollBackoffTest {

    @Test
    fun `backoff doubles and then caps`() {
        val b = PollBackoff()
        assertEquals(60L, b.recordFailure())    // 60 * 2^0
        assertEquals(120L, b.recordFailure())   // 60 * 2^1
        assertEquals(240L, b.recordFailure())
        assertEquals(480L, b.recordFailure())
        // 960 would exceed the cap.
        assertEquals(600L, b.recordFailure())
        assertEquals(600L, b.recordFailure())
    }

    @Test
    fun `success clears the escalation`() {
        val b = PollBackoff()
        repeat(5) { b.recordFailure() }
        assertEquals(600L, b.recordFailure())

        b.recordSuccess()
        assertEquals(0, b.failureCount)
        // Back to the base interval, not still capped.
        assertEquals(60L, b.recordFailure())
    }

    @Test
    fun `a longer Retry-After wins`() {
        // The server asked for more than our first step; honour it.
        val b = PollBackoff()
        assertEquals(300L, b.recordFailure(retryAfterSeconds = 300))
    }

    @Test
    fun `a shorter Retry-After does not shrink the backoff`() {
        // Answering a 429 sooner than our own backoff is how you earn another
        // 429. macOS ignores the header entirely; this takes the larger.
        val b = PollBackoff()
        repeat(3) { b.recordFailure() }          // now at 240s
        assertEquals(480L, b.recordFailure(retryAfterSeconds = 5))
    }

    @Test
    fun `the first failure never waits less than a minute`() {
        // The poll cadence itself is three minutes, so a backoff shorter than
        // this would mean a failure retried faster than a success.
        val b = PollBackoff()
        assertTrue(b.recordFailure(retryAfterSeconds = 0) >= PollBackoff.BASE_SECONDS)
    }
}
