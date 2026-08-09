package com.allthingsclaude.battery.core

import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

/**
 * The card lifecycle, exercised as pure logic.
 *
 * None of this is testable in the iOS original — `LiveActivityController`
 * interleaves the decision with ActivityKit calls and `@MainActor` state — so
 * every case here is coverage the Swift side does not have.
 */
class SessionPolicyTest {

    private val now: Instant = Instant.parse("2026-01-01T12:00:00Z")

    private fun payload(
        utilization: Double,
        active: Boolean = false,
        resetsAt: Instant? = now.plusSeconds(3600),
    ) = UsagePayload(
        sessionUtilization = utilization,
        sessionResetsAt = resetsAt,
        weeklyUtilization = 10.0,
        weeklyResetsAt = now.plusSeconds(86_400),
        isSessionActive = active,
        updatedAt = now,
    )

    // ── Starting ────────────────────────────────────────────────────────────

    @Test
    fun `an untouched window shows nothing`() {
        // Zero usage is what separates SMART from "always on": a window opens
        // when the previous one expires, whether or not anyone is working.
        val outcome = SessionPolicy.evaluate(SessionPolicy.State(), payload(0.0), now = now)
        assertIs<SessionPolicy.Decision.Hide>(outcome.decision)
    }

    @Test
    fun `an active session shows even when low`() {
        val outcome =
            SessionPolicy.evaluate(SessionPolicy.State(), payload(5.0, active = true), now = now)
        assertIs<SessionPolicy.Decision.Show>(outcome.decision)
    }

    @Test
    fun `SMART shows at percentages a heavy plan never reaches`() {
        // Regression. SMART used to require `isSessionActive || utilization >=
        // 40%`. On an account whose five-hour windows live in single digits the
        // second arm never fires, so the card existed only when activity
        // detection happened to be warm — and that needs two polls to see a
        // rise. The reported symptom was "smart just isn't a thing on my plan".
        for (utilization in listOf(0.5, 3.0, 9.0, 20.0, 39.0)) {
            assertIs<SessionPolicy.Decision.Show>(
                SessionPolicy.evaluate(SessionPolicy.State(), payload(utilization), now = now).decision,
                "$utilization% in an open window should show",
            )
        }
    }

    @Test
    fun `SMART shows on the first poll, before activity can be inferred`() {
        // isSessionActive is false here because it takes two samples to derive.
        // The old rule made that the *only* way in below 40%, which is where the
        // six-minute delay came from.
        val outcome =
            SessionPolicy.evaluate(SessionPolicy.State(), payload(2.0, active = false), now = now)
        assertIs<SessionPolicy.Decision.Show>(outcome.decision)
    }

    @Test
    fun `OFF hides regardless of how hot the session is`() {
        val outcome = SessionPolicy.evaluate(
            SessionPolicy.State(),
            payload(99.0, active = true),
            mode = SessionPolicy.Mode.OFF,
            now = now,
        )
        assertIs<SessionPolicy.Decision.Hide>(outcome.decision)
    }

    // ── Escalation ──────────────────────────────────────────────────────────

    @Test
    fun `a card appearing already in HIGH does not alert`() {
        // Appearing and escalating are different events. iOS seeds alertedLevel
        // silently when it starts an activity and only alerts on updates, so
        // opening the app at 80% is quiet there. Alerting here would also mean
        // re-alerting every time the service restarts, since Hide discards this
        // state and a session that keeps dropping in and out of view restarts
        // often.
        val first = SessionPolicy.evaluate(
            SessionPolicy.State(),
            payload(76.0, active = true),
            now = now,
        )
        assertNull((first.decision as SessionPolicy.Decision.Show).alertLevel)
        assertEquals(UsageLevel.HIGH, first.state.alertedLevel, "seeded, so it won't fire later")
    }

    @Test
    fun `crossing into a new level while showing alerts exactly once`() {
        var state = SessionPolicy.State()

        // Climb from MODERATE, so the card is already up when HIGH is crossed.
        state = SessionPolicy.evaluate(state, payload(60.0, active = true), now = now).state

        val crossing = SessionPolicy.evaluate(state, payload(76.0, active = true), now = now)
        assertEquals(UsageLevel.HIGH, (crossing.decision as SessionPolicy.Decision.Show).alertLevel)
        state = crossing.state

        // Same level again — no second banner. Re-alerting every poll at 76% is
        // how you train someone to swipe the card away, and a dismissed Live
        // Update must never be reposted.
        val same = SessionPolicy.evaluate(state, payload(80.0, active = true), now = now)
        assertNull((same.decision as SessionPolicy.Decision.Show).alertLevel)
        state = same.state

        // Escalating to CRITICAL is a new level, so it alerts again.
        val escalated = SessionPolicy.evaluate(state, payload(91.0, active = true), now = now)
        assertEquals(
            UsageLevel.CRITICAL,
            (escalated.decision as SessionPolicy.Decision.Show).alertLevel,
        )
    }

    @Test
    fun `dropping out of alarming territory rearms the alert`() {
        var state = SessionPolicy.State()
        state = SessionPolicy.evaluate(state, payload(50.0, active = true), now = now).state
        state = SessionPolicy.evaluate(state, payload(80.0, active = true), now = now).state

        // Back down to MODERATE — a new window, or a correction.
        state = SessionPolicy.evaluate(state, payload(60.0, active = true), now = now).state
        assertNull(state.alertedLevel, "alert should be rearmed")

        val again = SessionPolicy.evaluate(state, payload(80.0, active = true), now = now)
        assertEquals(UsageLevel.HIGH, (again.decision as SessionPolicy.Decision.Show).alertLevel)
    }

    // ── Ending ──────────────────────────────────────────────────────────────

    @Test
    fun `a window rollover shows the reset card`() {
        val state = SessionPolicy.State(previousUtilization = 87.0)
        val outcome = SessionPolicy.evaluate(state, payload(4.0), now = now)
        assertIs<SessionPolicy.Decision.ShowReset>(outcome.decision)
    }

    @Test
    fun `the rollover check runs before the idle check`() {
        // Regression guard for the ordering bug this is written to prevent: a
        // fresh window is low AND inactive, so every "idle" rule below would
        // classify the rollover as an ordinary dismissal — silently swallowing
        // the one moment the user most wants to see.
        val state = SessionPolicy.State(
            previousUtilization = 90.0,
            idleSince = now.minusSeconds(SessionPolicy.END_GRACE_SECONDS + 60),
        )
        val outcome = SessionPolicy.evaluate(state, payload(2.0, active = false), now = now)
        assertIs<SessionPolicy.Decision.ShowReset>(outcome.decision)
    }

    @Test
    fun `idle and low hides only after the grace period`() {
        val idleStart = now
        var state = SessionPolicy.State(previousUtilization = 20.0)

        // First idle poll starts the clock, and the card stays up: 20% of a
        // used window is worth showing even with nothing burning right now.
        val first = SessionPolicy.evaluate(state, payload(20.0), now = idleStart)
        assertIs<SessionPolicy.Decision.Show>(first.decision)
        assertEquals(idleStart, first.state.idleSince)
        state = first.state

        // Still up one second before the grace expires.
        val early = SessionPolicy.evaluate(
            state,
            payload(20.0),
            now = idleStart.plusSeconds(SessionPolicy.END_GRACE_SECONDS - 1),
        )
        assertIs<SessionPolicy.Decision.Show>(early.decision)
        assertEquals(idleStart, early.state.idleSince, "the clock must not restart")

        // And gone once it does.
        val late = SessionPolicy.evaluate(
            state,
            payload(20.0),
            now = idleStart.plusSeconds(SessionPolicy.END_GRACE_SECONDS),
        )
        assertIs<SessionPolicy.Decision.Hide>(late.decision)
    }

    @Test
    fun `a flicker of activity resets the idle clock`() {
        var state = SessionPolicy.State(previousUtilization = 50.0, idleSince = now)

        // Active again → the clock must clear, not merely pause.
        state = SessionPolicy.evaluate(
            state,
            payload(50.0, active = true),
            now = now.plusSeconds(60),
        ).state
        assertNull(state.idleSince)
    }

    @Test
    fun `a hot session past its reset time hides`() {
        val outcome = SessionPolicy.evaluate(
            SessionPolicy.State(previousUtilization = 80.0),
            payload(80.0, active = true, resetsAt = now.minusSeconds(1)),
            now = now,
        )
        assertIs<SessionPolicy.Decision.Hide>(outcome.decision)
    }

    @Test
    fun `no window at all does not count as past its reset`() {
        // resetsAt == null is "no session open", not "expired". Both hide, so
        // the decision alone can't tell them apart — the state can. The
        // past-reset branch returns a bare State and drops alertedLevel; the
        // not-worth-showing branch carries it. Asserting on the state is what
        // makes this a test of the reason rather than of the outcome.
        val outcome = SessionPolicy.evaluate(
            SessionPolicy.State(alertedLevel = UsageLevel.HIGH, isShowing = true),
            payload(50.0, active = true, resetsAt = null),
            now = now,
        )
        assertIs<SessionPolicy.Decision.Hide>(outcome.decision)
        assertEquals(UsageLevel.HIGH, outcome.state.alertedLevel)
    }

    @Test
    fun `a rollover does not take down a WHENEVER_OPEN card`() {
        // The mode's contract is that it never dismisses while a window is open,
        // and ShowReset ends in dismissal with nothing scheduled to bring the
        // card back — so a rollover used to cost the whole fresh five hours.
        // None of the other WHENEVER_OPEN tests sets previousUtilization above
        // RESET_FROM, which is why this went unnoticed.
        val outcome = SessionPolicy.evaluate(
            SessionPolicy.State(previousUtilization = 87.0, isShowing = true),
            payload(2.0),
            mode = SessionPolicy.Mode.WHENEVER_OPEN,
            now = now,
        )
        assertIs<SessionPolicy.Decision.Show>(outcome.decision)
    }

    @Test
    fun `a rollover still shows the reset card in SMART`() {
        val outcome = SessionPolicy.evaluate(
            SessionPolicy.State(previousUtilization = 87.0, isShowing = true),
            payload(2.0),
            mode = SessionPolicy.Mode.SMART,
            now = now,
        )
        assertIs<SessionPolicy.Decision.ShowReset>(outcome.decision)
    }

    @Test
    fun `falling to a lower alarming level does not alert`() {
        // `!=` was direction-blind. The reachable case is an account switch:
        // policyState is a field on the service and nothing resets it, so
        // account B at 78% inherits account A's alertedLevel of CRITICAL and
        // would make a noise about a number that just fell fourteen points.
        val outcome = SessionPolicy.evaluate(
            SessionPolicy.State(
                previousUtilization = 92.0,
                alertedLevel = UsageLevel.CRITICAL,
                isShowing = true,
            ),
            payload(78.0, active = true),
            now = now,
        )
        val decision = assertIs<SessionPolicy.Decision.Show>(outcome.decision)
        assertNull(decision.alertLevel, "a drop from CRITICAL to HIGH must be silent")
    }

    @Test
    fun `climbing to a higher level still alerts`() {
        val outcome = SessionPolicy.evaluate(
            SessionPolicy.State(
                previousUtilization = 80.0,
                alertedLevel = UsageLevel.HIGH,
                isShowing = true,
            ),
            payload(95.0, active = true),
            now = now,
        )
        val decision = assertIs<SessionPolicy.Decision.Show>(outcome.decision)
        assertEquals(UsageLevel.CRITICAL, decision.alertLevel)
    }

    // ── Cadence ─────────────────────────────────────────────────────────────

    @Test
    fun `a visible card polls faster than a hidden one`() {
        val fast = SessionPolicy.pollIntervalSeconds(SessionPolicy.Decision.Show(null))
        val slow = SessionPolicy.pollIntervalSeconds(SessionPolicy.Decision.Hide)
        assertEquals(AppConfig.ACTIVE_POLL_SECONDS, fast)
        assertEquals(AppConfig.IDLE_POLL_SECONDS, slow)
        assert(fast < slow)
    }

    // ── WHENEVER_OPEN ───────────────────────────────────────────────────────

    @Test
    fun `WHENEVER_OPEN shows at any percentage while a window is open`() {
        // Includes 0.0, which is the one case SMART deliberately excludes: a
        // window that has just opened and has not been touched. That single
        // value is now most of what separates the two modes on the show side —
        // the rest of the difference is that this one never idles out.
        for (utilization in listOf(0.0, 1.0, 6.0, 39.0)) {
            val outcome = SessionPolicy.evaluate(
                SessionPolicy.State(),
                payload(utilization, active = false),
                mode = SessionPolicy.Mode.WHENEVER_OPEN,
                now = now,
            )
            assertIs<SessionPolicy.Decision.Show>(outcome.decision, "at $utilization%")
        }
    }

    @Test
    fun `WHENEVER_OPEN still hides when no window is open`() {
        // "Whenever open", not "always". No window means no bounded activity,
        // which is what would make the card the anti-pattern the guidelines
        // actually warn about.
        val outcome = SessionPolicy.evaluate(
            SessionPolicy.State(),
            payload(0.0, active = false, resetsAt = null),
            mode = SessionPolicy.Mode.WHENEVER_OPEN,
            now = now,
        )
        assertIs<SessionPolicy.Decision.Hide>(outcome.decision)
    }

    @Test
    fun `WHENEVER_OPEN ignores the idle grace period`() {
        // Ten minutes of not typing is not a reason to lose the card in this
        // mode — SMART is the one that dismisses on idle.
        val state = SessionPolicy.State(
            previousUtilization = 20.0,
            idleSince = now.minusSeconds(SessionPolicy.END_GRACE_SECONDS + 60),
        )
        assertIs<SessionPolicy.Decision.Show>(
            SessionPolicy.evaluate(
                state, payload(20.0, active = false),
                mode = SessionPolicy.Mode.WHENEVER_OPEN, now = now,
            ).decision
        )
        // …but SMART still does.
        assertIs<SessionPolicy.Decision.Hide>(
            SessionPolicy.evaluate(
                state, payload(20.0, active = false),
                mode = SessionPolicy.Mode.SMART, now = now,
            ).decision
        )
    }

    @Test
    fun `WHENEVER_OPEN still hides once the window has expired`() {
        val outcome = SessionPolicy.evaluate(
            SessionPolicy.State(previousUtilization = 50.0),
            payload(50.0, active = true, resetsAt = now.minusSeconds(1)),
            mode = SessionPolicy.Mode.WHENEVER_OPEN,
            now = now,
        )
        assertIs<SessionPolicy.Decision.Hide>(outcome.decision)
    }

    // ── Focus window ────────────────────────────────────────────────────────

    @Test
    fun `focus window leads with whichever is closer to its ceiling`() {
        // Drives the Now Bar pill's second line and the status-bar chip, which
        // One UI feeds from one string — so picking the wrong one wastes the
        // only glanceable surface the app has.
        fun focus(session: Double, weekly: Double) = UsagePayload(
            sessionUtilization = session,
            sessionResetsAt = now.plusSeconds(3600),
            weeklyUtilization = weekly,
            weeklyResetsAt = now.plusSeconds(86_400),
            updatedAt = now,
        ).focusWindow

        assertEquals(UsagePayload.FocusWindow.WEEKLY, focus(session = 9.0, weekly = 28.0))
        assertEquals(UsagePayload.FocusWindow.SESSION, focus(session = 80.0, weekly = 28.0))
        // A tie goes to the session: it moves faster and is the one you can act on.
        assertEquals(UsagePayload.FocusWindow.SESSION, focus(session = 50.0, weekly = 50.0))
    }
}
