package com.allthingsclaude.battery.core

import java.time.Instant

/**
 * Decides whether the lock-screen card should exist, and whether crossing into a
 * new severity level warrants alerting.
 *
 * This is the port of `ios/BatteryApp/LiveActivityController.swift`'s state
 * machine, with one structural change that matters: **it is pure.** The iOS
 * version interleaves the decision with ActivityKit calls and `@MainActor`
 * state, so none of it can be tested; here the decision is a function of
 * (previous state, payload, now) and the Android service just executes the
 * verdict.
 *
 * The thresholds mirror the macOS `NotificationService` so all three platforms
 * agree on what "worth surfacing" means.
 *
 * On Android the card's existence and the poll cadence are the *same* decision,
 * because the foreground service's notification **is** the card:
 *
 *     card exists  ⟺  service running  ⟺  fast polling
 */
object SessionPolicy {

    /** Begin watching a climbing session at or above this. */
    const val START_THRESHOLD = 40.0

    /** Low enough to stop watching. */
    const val END_THRESHOLD = 25.0

    /** Must stay idle and low this long before the card auto-dismisses. */
    const val END_GRACE_SECONDS = 10 * 60L

    /** A drop from above this to below [RESET_TO] means the window rolled over. */
    const val RESET_FROM = 30.0
    const val RESET_TO = 10.0

    /** Rolling state between polls. Immutable so a caller can't half-update it. */
    data class State(
        val previousUtilization: Double? = null,
        val alertedLevel: UsageLevel? = null,
        val idleSince: Instant? = null,
        /**
         * Whether a card is already on screen. Needed because *appearing* and
         * *escalating* are different events: iOS seeds `alertedLevel` silently
         * when it starts an activity and only alerts on subsequent updates
         * (`LiveActivityController.swift`, the `else` branch of the start/update
         * split). Without this, opening the app at 80% makes a noise on Android
         * and stays silent on iOS — and worse, since `Hide` stops the service
         * and discards this state, a session oscillating around the 40% start
         * threshold would re-alert on every restart.
         */
        val isShowing: Boolean = false,
    )

    /** What the service should do with this payload. */
    sealed class Decision {
        /** Card should be up. [alertLevel] is non-null exactly once per crossing. */
        data class Show(val alertLevel: UsageLevel?) : Decision()
        /** The 5-hour window rolled over — show a brief reset card, then dismiss. */
        object ShowReset : Decision()
        /** No card. */
        object Hide : Decision()
    }

    data class Outcome(val decision: Decision, val state: State)

    /** User preference. "Always on" is deliberately absent — see below. */
    enum class Mode {
        /** Never show a card. */
        OFF,

        /**
         * Only while a session is worth watching. This is the only mode that
         * ships.
         *
         * iOS also offers "Always On", and it is **deliberately not ported**: a
         * permanently-promoted ongoing notification is the exact anti-pattern in
         * Google's Live Update guidelines, and losing promotion is
         * unrecoverable except via a settings deep link. Smart *is* the
         * compliant behaviour.
         */
        SMART,
    }

    /**
     * Reconcile one payload against the previous state.
     *
     * @param now injected so the grace period is testable without sleeping.
     */
    fun evaluate(
        state: State,
        payload: UsagePayload,
        mode: Mode = Mode.SMART,
        now: Instant = Instant.now(),
    ): Outcome {
        val utilization = payload.sessionUtilization

        if (mode == Mode.OFF) {
            return Outcome(Decision.Hide, State(previousUtilization = utilization))
        }

        // A sharp collapse means the window rolled over. Checked before anything
        // else: the new window's utilization is low, so every other rule below
        // would read it as "idle" and dismiss silently, losing the one moment
        // the user most wants to see.
        val didReset = (state.previousUtilization ?: 0.0) > RESET_FROM && utilization < RESET_TO
        if (didReset) {
            return Outcome(Decision.ShowReset, State(previousUtilization = utilization))
        }

        // Past the window's own reset time — nothing left to watch.
        val pastReset = payload.sessionResetsAt?.isBefore(now) ?: false

        // Idle and low for long enough to stop watching. `idleSince` is carried
        // rather than recomputed so a brief flicker of activity genuinely resets
        // the clock.
        val isIdleLow = !payload.isSessionActive && utilization < END_THRESHOLD
        val idleSince = if (isIdleLow) (state.idleSince ?: now) else null
        val idledLongEnough = idleSince
            ?.let { now.epochSecond - it.epochSecond >= END_GRACE_SECONDS }
            ?: false

        if (pastReset || idledLongEnough) {
            return Outcome(Decision.Hide, State(previousUtilization = utilization))
        }

        val shouldShow = payload.isSessionActive || utilization >= START_THRESHOLD
        if (!shouldShow) {
            return Outcome(
                Decision.Hide,
                State(
                    previousUtilization = utilization,
                    alertedLevel = state.alertedLevel,
                    idleSince = idleSince,
                    isShowing = false,
                ),
            )
        }

        // Escalation: alert once per level, and only on the way up. Re-alerting
        // on every poll at 91% would train the user to swipe the card away —
        // which the Android layer then honours permanently for that window (see
        // CardDismissal), so the cost of being noisy here is losing the surface
        // entirely.
        val level = UsageLevel.from(utilization)
        // Only ever alert on an *escalation*, never on first appearance.
        val shouldAlert = state.isShowing && level.isAlarming && level != state.alertedLevel
        val alertedLevel = when {
            // Seeded on first appearance too, so the card that shows up at 91%
            // doesn't then alert on its second poll.
            shouldAlert || (!state.isShowing && level.isAlarming) -> level
            // Dropping out of alarming territory rearms the alert, so a session
            // that recovers and climbs again warns a second time.
            !level.isAlarming -> null
            else -> state.alertedLevel
        }

        return Outcome(
            Decision.Show(alertLevel = if (shouldAlert) level else null),
            State(
                previousUtilization = utilization,
                alertedLevel = alertedLevel,
                idleSince = idleSince,
                isShowing = true,
            ),
        )
    }

    /**
     * How long to wait before the next poll.
     *
     * Not 60 seconds: at a heavy 20%/hr burn that is 0.33 percentage points of
     * drift — sampling noise. And on Android the poll is what justifies a
     * foreground service staying alive, so over-sampling has a cost that a Mac
     * polling from mains power doesn't have.
     */
    fun pollIntervalSeconds(decision: Decision): Long = when (decision) {
        is Decision.Show -> AppConfig.ACTIVE_POLL_SECONDS
        else -> AppConfig.IDLE_POLL_SECONDS
    }
}
