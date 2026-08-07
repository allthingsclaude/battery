package com.allthingsclaude.battery.core

import java.time.Instant
import kotlin.math.abs

/**
 * Where snapshots live. The iOS original writes straight into the App Group via
 * `SharedStore`; here that's an interface so `core` stays free of Android.
 *
 * The app supplies a DataStore-backed implementation. Tests supply an in-memory
 * one, which is the other reason this indirection is worth its keep — the iOS
 * `SessionHistory` cannot be unit-tested without a real `UserDefaults` suite.
 */
interface SnapshotStore {
    fun load(): List<UsageSnapshot>
    fun save(snapshots: List<UsageSnapshot>)
    fun clear()
}

/** A trivial [SnapshotStore] for tests and previews. */
class InMemorySnapshotStore(initial: List<UsageSnapshot> = emptyList()) : SnapshotStore {
    private var snapshots: List<UsageSnapshot> = initial
    override fun load(): List<UsageSnapshot> = snapshots
    override fun save(snapshots: List<UsageSnapshot>) { this.snapshots = snapshots }
    override fun clear() { snapshots = emptyList() }
}

/**
 * The one place a usage sample gets recorded and turned into a burn rate.
 *
 * Port of `ios/BatteryKit/SessionHistory.swift`. On iOS three processes poll the
 * same account (foreground loop, background refresh, widget self-fetch) and each
 * used to keep its own idea of history, so a *measured* burn rate was the
 * exception and nearly every surface fell through to "—". Funnelling all of them
 * through one shared buffer fixed it.
 *
 * Android has the same hazard for the same reason even though widgets share the
 * app's process: the foreground service, the WorkManager keep-warm job and the
 * widget update path are three different entry points, and only a single store
 * behind all of them keeps the regression fed.
 */
class SessionHistory(private val store: SnapshotStore) {

    /** The pace, and when the limit arrives. */
    data class Projection(val ratePerHour: Double, val limitAt: Instant?) {
        companion object {
            val NONE = Projection(0.0, null)
        }
    }

    /**
     * Record a sample for the current window and return the projection it
     * implies. With no open window the buffer is dropped — samples from a closed
     * window can only poison the next one's regression.
     */
    fun record(utilization: Double, resetsAt: Instant?, now: Instant = Instant.now()): Projection {
        if (resetsAt == null) {
            store.clear()
            return Projection.NONE
        }

        val history = (currentWindow(resetsAt) + UsageSnapshot(now, utilization, resetsAt))
            .sortedBy { it.timestamp }
            .takeLast(CAPACITY)

        store.save(history)

        val projection = BurnRateCalculator.calculate(
            snapshots = history,
            currentUtilization = utilization,
            resetsAt = resetsAt,
            now = now,
        )
        // A limit landing after the reset isn't reached — the window rolls over
        // first.
        val limit = projection.projectedLimitTime?.takeIf { it.isBefore(resetsAt) }
        return Projection(projection.currentRate, limit)
    }

    /**
     * When session utilization last went **up** inside the current window, or
     * null if it never has.
     *
     * This is the "is the user actually working right now" signal, and it reads
     * the persisted buffer rather than fields on the caller for a reason that
     * cost a real bug: [UsageSnapshot]s are shared, but the object holding
     * in-memory `lastUtilization` was not. Every entry point builds its own
     * repository, so two consecutive polls had to land in the *same* instance
     * before a rise could be noticed — meaning the dashboard and the foreground
     * service each formed their own opinion, and a service restart went blind
     * for a full poll cycle at exactly the moment the card was meant to appear.
     *
     * Persisting it is safe despite the obvious worry (a stale "active" keeping
     * a service alive across a reboot) because every caller pairs this with a
     * recency test: a rise older than the activity window reads as idle no
     * matter how it was stored.
     */
    fun lastRiseAt(resetsAt: Instant?): Instant? {
        if (resetsAt == null) return null
        return currentWindow(resetsAt)
            .sortedBy { it.timestamp }
            .zipWithNext()
            .lastOrNull { (before, after) ->
                after.sessionUtilization > before.sessionUtilization + RISE_EPSILON
            }
            ?.second
            ?.timestamp
    }

    /**
     * Samples belonging to the window ending at [resetsAt].
     *
     * Same 1-second tolerance the calculator uses: a reset time round-trips
     * through JSON and can come back a hair off.
     */
    private fun currentWindow(resetsAt: Instant): List<UsageSnapshot> =
        store.load().filter {
            abs((it.sessionResetsAt.toEpochMilli() - resetsAt.toEpochMilli()) / 1000.0) < 1.0
        }

    /** Forget everything — a different account's usage must never feed this one. */
    fun reset() = store.clear()

    companion object {

        /**
         * How much utilization must climb between two samples to count as a
         * rise. Guards against a percentage that jitters in the last decimal
         * place reading as continuous activity forever.
         */
        const val RISE_EPSILON = 0.01

        /**
         * Roughly 30–90 minutes of samples at the poll cadence. The regression
         * wants recency, not depth — an older tail would drag the rate toward
         * the window average, which [UsageForecast] already covers on its own
         * terms.
         */
        const val CAPACITY = 30
    }
}
