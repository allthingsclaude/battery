package com.allthingsclaude.battery.core

import java.time.Duration
import java.time.Instant

/**
 * Which account is actually being used right now.
 *
 * The signal is real rather than inferred from habit: a rise in session
 * utilization means that account spent tokens, and the sample buffer already
 * records when each rise happened. That makes this a recency-of-evidence rule,
 * not a guess about what the user probably wants.
 *
 * It still has to be treated as a guess in the UI. The failure mode here is not
 * a wrong tap that can be undone — it is a **wrong number believed**: quota read
 * off the wrong account and acted on. So [pick] is deliberately conservative,
 * and the surface that uses it has to name the account it chose and why.
 */
object ActiveAccount {

    /**
     * The most recently active account, or null to leave the selection alone.
     *
     * Null is returned whenever nothing has moved [within] the recency window —
     * an idle evening must not drag the selection to whichever account happened
     * to be used last week. Null means "no opinion", which callers must treat as
     * "change nothing" rather than as an error.
     *
     * Ties go to the lexicographically smaller id, purely so the answer is
     * stable: two accounts whose last rise landed in the same millisecond would
     * otherwise flip the selection back and forth between polls.
     */
    fun pick(
        lastRises: Map<String, Instant>,
        now: Instant,
        within: Duration = Duration.ofMinutes(30),
    ): String? {
        val cutoff = now.minus(within)
        return lastRises
            .filterValues { it.isAfter(cutoff) }
            .entries
            .sortedWith(compareByDescending<Map.Entry<String, Instant>> { it.value }.thenBy { it.key })
            .firstOrNull()
            ?.key
    }
}
