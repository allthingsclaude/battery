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

    /**
     * High enough that the card stays up through a lull, because at this level
     * the number itself is the thing worth watching.
     *
     * There used to be a matching `START_THRESHOLD = 40.0` that SMART required
     * before it would show anything. It was removed: on a plan where a five-hour
     * window rarely passes 20%, a 40% gate never opens, so "smart" collapsed
     * into "activity detection or nothing" — and activity detection needs two
     * polls to see a rise. A percentage is the wrong shape for *presence*
     * anyway. It belongs to alerting, which is what [UsageLevel.isAlarming]
     * already does.
     */
    const val END_THRESHOLD = 25.0

    /**
     * Must stay idle this long before the card auto-dismisses.
     *
     * Thirty minutes, not ten. Ten minutes of not burning tokens is a code
     * review, a meeting, or lunch ordered — not the end of a work session. And
     * the cost of being wrong is asymmetric: when the card goes, so does the
     * foreground service, and nothing schedules its return, so the card cannot
     * come back until the app is opened again. Dismissing early doesn't hide a
     * card for ten minutes, it hides it for the rest of the day.
     */
    const val END_GRACE_SECONDS = 30 * 60L

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
         * and discards this state, a session that keeps dropping in and out of
         * view would re-alert on every restart.
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

    /** User preference for when the card should exist. */
    enum class Mode {
        /** Never show a card. */
        OFF,

        /**
         * While there is an open window you have actually used, until you have
         * been idle long enough that the session is plainly over.
         *
         * Deliberately **not** conditioned on a percentage. The earlier rule was
         * `isSessionActive || utilization >= 40%`, which reads as reasonable and
         * behaves badly: for anyone whose sessions live in single digits the
         * 40% arm never fires, so the card's entire existence rested on the
         * activity arm — and that arm needs two polls to see a rise, i.e. up to
         * six minutes of typing before anything appears. "Any usage at all in an
         * open window" fires on the *first* poll and costs nothing, because a
         * window you have not touched is already excluded.
         */
        SMART,

        /**
         * Any time a 5-hour window is open, at any percentage.
         *
         * An earlier revision omitted this on the grounds that a
         * permanently-promoted notification is the anti-pattern in Google's Live
         * Update guidelines. That was over-applying the rule. The guideline is
         * about *unbounded* cards; an open session window has a start and a hard
         * end, which is exactly the "ongoing, user-initiated, time-bounded
         * activity" the API is for. The card still disappears when the window
         * closes — this is not "always on", it is "for the whole activity".
         *
         * It also used to be the only way to get a card up promptly, because
         * SMART could not show anything until it had seen two polls. SMART now
         * shows on any usage in an open window, so the remaining difference is
         * narrow and honest: this mode never dismisses for idleness.
         */
        WHENEVER_OPEN,
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
        // SMART only. iOS guards this the same way — `if didReset && !alwaysOn`
        // in LiveActivityController.sync — because ShowReset ends with the card
        // being taken down, and nothing schedules its return. In WHENEVER_OPEN
        // that turns a rollover into "no card for the whole fresh five-hour
        // window", which is the exact opposite of what the mode promises. The
        // reasoning below still holds for SMART, where the rules that follow
        // would read a freshly-reset window as idle and dismiss it silently.
        val didReset = (state.previousUtilization ?: 0.0) > RESET_FROM && utilization < RESET_TO
        if (didReset && mode == Mode.SMART) {
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

        // The idle grace period belongs to SMART only. In WHENEVER_OPEN the
        // window is the card's lifetime, so going quiet for ten minutes is not a
        // reason to disappear — that is the entire point of the mode.
        if (pastReset || (idledLongEnough && mode == Mode.SMART)) {
            return Outcome(Decision.Hide, State(previousUtilization = utilization))
        }

        val shouldShow = when (mode) {
            Mode.OFF -> false   // unreachable; handled above
            Mode.WHENEVER_OPEN -> payload.sessionResetsAt != null
            // An open window plus any usage at all. The window check is what
            // keeps this from being "always": between sessions there is no
            // window, and a fresh one starts at zero.
            Mode.SMART -> payload.sessionResetsAt != null &&
                (payload.isSessionActive || utilization > 0.0)
        }
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
        // `>`, not `!=`. Inequality is direction-blind: CRITICAL -> HIGH
        // satisfied it just as readily as HIGH -> CRITICAL, so a card that had
        // alerted at 92% would alert again on a number that had *fallen* to 78 —
        // reachable because policyState survives an account switch, and account
        // B at 78% inherits account A's alertedLevel of CRITICAL. Enum
        // declaration order is the severity order, so ordinal is the comparison.
        val shouldAlert = state.isShowing && level.isAlarming &&
            level.ordinal > (state.alertedLevel?.ordinal ?: -1)
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
