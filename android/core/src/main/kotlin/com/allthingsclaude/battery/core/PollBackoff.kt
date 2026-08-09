package com.allthingsclaude.battery.core

import kotlin.math.min
import kotlin.math.pow

/**
 * How long to wait after a failed poll.
 *
 * A port of the exponential backoff in `Sources/Services/UsagePollingService.swift`,
 * which exists because the macOS app hit exactly this problem and solved it:
 * `baseBackoffInterval * 2^(n-1)`, capped at ten minutes, with the consecutive
 * counter reset on any success.
 *
 * Two things it adds over the original:
 *
 *  - **`Retry-After` is honoured.** macOS reads the header (`AnthropicAPI.swift`
 *    parses it into `APIError.rateLimited`) and then computes its interval
 *    purely from the counter, ignoring what the server asked for. Taking the
 *    larger of the two respects an explicit instruction without ever waiting
 *    less than the backoff would.
 *  - **It's testable.** The macOS version is private state on an ObservableObject
 *    driven by a live timer, so none of its arithmetic is covered.
 */
class PollBackoff {

    private var consecutiveFailures = 0

    /** Every success clears the escalation. */
    fun recordSuccess() {
        consecutiveFailures = 0
    }

    /**
     * Record a failure and return how long to wait.
     *
     * @param retryAfterSeconds the server's own instruction, when it sent one.
     */
    fun recordFailure(retryAfterSeconds: Long? = null): Long {
        consecutiveFailures++
        val exponential = BASE_SECONDS * 2.0.pow(consecutiveFailures - 1)
        val backoff = min(exponential, MAX_SECONDS.toDouble()).toLong()
        // Never wait *less* than our own backoff just because the server asked
        // for a short retry — a 429 answered too eagerly earns another 429.
        return maxOf(backoff, retryAfterSeconds ?: 0L)
    }

    /** For diagnostics and tests. */
    val failureCount: Int get() = consecutiveFailures

    companion object {
        const val BASE_SECONDS = 60L
        const val MAX_SECONDS = 600L
    }
}
